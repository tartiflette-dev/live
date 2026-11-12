# frozen_string_literal: true

# Plan de montage du replay piloté par la PAROLE : qui est à l'image, et
# comment, à chaque instant de la vidéo.
#
# Règles, dans l'ordre :
#   1. Un écran partagé se voit en grand ; les visages passent en vignettes
#      sur le côté, la personne qui a la parole en premier.
#   2. Une mise en avant explicite de l'animation (SpotlightChange, journal
#      de RoomSpotlight) l'emporte sur la parole.
#   3. Sinon, la personne mise en avant est celle qui PARLE : celle qui a un
#      segment de transcription à cet instant, jamais celle qui fait du
#      bruit (le clavier ne produit pas de segment). Deux voix à la fois : la
#      plus récente prend l'image. Personne ne parle : l'image reste sur la
#      dernière personne qui a parlé.
#   4. Les autres sont en vignettes sur le côté.
#   5. Personne à mettre en avant sans piste caméra séparée (pas d'accord à
#      l'image, egress manquant), ou personne encore : la vue d'ensemble de
#      LiveKit (composite), qui montre tout le monde.
#
# Lissage : un segment de moins de MIN_SPEECH (interjection, bruit) ne compte
# pas, deux segments d'une même personne à moins de SPEECH_GAP n'en font
# qu'un, et un plan de moins de MIN_SHOT est absorbé par le précédent (pas de
# bascule à chaque « oui »). Le bruit Whisper (« Merci d'avoir regardé »,
# « Sous-titrage… ») est écarté avant tout (TranscriptNoise).
#
# Pur calcul, sans base ni vidéo : horaires en entrée, plans en secondes
# depuis `origin` en sortie. ReplayMontage le nourrit et le traduit pour le
# moteur de rendu externe (docs/replays.md, « Rendus hors de l'application »).
class MontagePlan
  MIN_SPEECH = 1.0
  SPEECH_GAP = 1.5
  MIN_SHOT = 2.5
  MAX_THUMBNAILS = 4

  Segment = Data.define(:identity, :started_at, :ended_at, :text)
  # Vidéo séparée d'une personne : `kind` :camera ou :screen ; `key` la
  # désigne dans le rendu.
  Source = Data.define(:key, :identity, :kind, :started_at, :ended_at)
  Spotlight = Data.define(:at, :identity)
  # `layout` :composite (vue d'ensemble seule), :speaker (caméra en grand) ou
  # :screen (écran en grand) ; `main` et `thumbnails` = clés de Source.
  Shot = Data.define(:from, :to, :layout, :main, :thumbnails) do
    def duration = to - from
  end

  # @param origin [Time] instant 0 de la vidéo
  # @param finish [Time] fin de la vidéo
  # @param segments [Array<Segment>] transcription, toutes personnes
  # @param sources [Array<Source>] pistes caméra et écran
  # @param spotlights [Array<Spotlight>] changements de mise en avant
  def initialize(origin:, finish:, segments:, sources:, spotlights: [])
    @origin = origin
    @duration = (finish - origin).to_f
    @segments = segments
    @sources = sources.select { |source| overlap(seconds(source.started_at), seconds(source.ended_at), 0, @duration).positive? }
    @spotlights = spotlights.sort_by(&:at)
  end

  # @return [Array<Shot>] plans contigus de 0 à la durée
  def shots
    return [] unless @duration.positive?

    smooth(states).flat_map { |from, to, state| shots_within(from, to, *state) }
  end

  # Prises de parole retenues, par identité, en secondes : [[début, fin], …].
  def speech
    @speech ||= @segments.reject { |segment| TranscriptNoise.noise?(segment.text) }
                         .map { |segment| [ segment.identity, seconds(segment.started_at), seconds(segment.ended_at) ] }
                         .select { |_, from, to| to - from >= MIN_SPEECH }
                         .group_by(&:first)
                         .transform_values { |rows| merge_runs(rows.map { |_, from, to| [ from, to ] }) }
  end

  private

  # Tranches élémentaires [début, fin, [écran, personne, caméra]] : l'état ne
  # change qu'à une borne (parole, mise en avant, piste qui commence ou finit).
  def states
    focus = nil
    bounds.each_cons(2).map do |from, to|
      middle = (from + to) / 2
      focus = spotlight_at(middle) || speaker_at(middle) || focus
      [ from, to, [ screen_at(middle)&.key, focus, focus && camera_at(focus, middle)&.key ] ]
    end
  end

  def bounds
    points = [ 0.0, @duration ]
    speech.each_value { |runs| runs.each { |from, to| points.push(from, to) } }
    @spotlights.each { |change| points << seconds(change.at) }
    @sources.each { |source| points.push(seconds(source.started_at), seconds(source.ended_at)) }
    points.map { |point| point.clamp(0.0, @duration) }.uniq.sort
  end

  # Tranches de même état fusionnées, puis tout plan de moins de MIN_SHOT
  # absorbé par le précédent (le suivant pour le tout premier).
  def smooth(slices)
    runs = merge_equal(slices)
    loop do
      index = runs.index { |from, to, _| to - from < MIN_SHOT }
      break if index.nil? || runs.size == 1

      if index.zero?
        runs[1] = [ runs[0][0], runs[1][1], runs[1][2] ]
      else
        runs[index - 1] = [ runs[index - 1][0], runs[index][1], runs[index - 1][2] ]
      end
      runs.delete_at(index)
      runs = merge_equal(runs)
    end
    runs
  end

  def merge_equal(slices)
    slices.each_with_object([]) do |(from, to, state), merged|
      if merged.any? && merged.last[2] == state
        merged.last[1] = to
      else
        merged << [ from, to, state ]
      end
    end
  end

  # Plans d'un même cadrage principal (après lissage), recoupés à chaque
  # arrivée ou départ d'une caméra : les vignettes suivent qui est là. Le
  # grand cadre ne bascule pas, donc pas de durée minimale ici.
  def shots_within(from, to, screen_key, _focus, camera_key)
    edges = [ from, *camera_bounds.select { |point| point > from && point < to }, to ]
    slices = edges.each_cons(2).map { |start, finish| [ start, finish, thumbnails_at((start + finish) / 2, screen_key, camera_key) ] }
    merge_equal(slices).map { |start, finish, thumbnails| shot(start, finish, screen_key, camera_key, thumbnails) }
  end

  def shot(from, to, screen_key, camera_key, thumbnails)
    if screen_key
      Shot.new(from: from, to: to, layout: :screen, main: screen_key, thumbnails: thumbnails)
    elsif camera_key
      Shot.new(from: from, to: to, layout: :speaker, main: camera_key, thumbnails: thumbnails)
    else
      Shot.new(from: from, to: to, layout: :composite, main: nil, thumbnails: [])
    end
  end

  # Écran en grand : la caméra de qui parle d'abord, puis les autres ;
  # caméra en grand : les autres ; vue d'ensemble : aucune vignette.
  def thumbnails_at(at, screen_key, camera_key)
    return [] unless screen_key || camera_key

    others = thumbnail_keys(at, except: camera_key)
    (screen_key ? [ camera_key ].compact + others : others).first(MAX_THUMBNAILS)
  end

  def camera_bounds
    @camera_bounds ||= cameras.flat_map { |source| [ seconds(source.started_at), seconds(source.ended_at) ] }.uniq.sort
  end

  # Caméras présentes à `at`, une par personne, dans l'ordre d'arrivée des
  # personnes (une vignette ne change pas de place d'un plan à l'autre).
  def thumbnail_keys(at, except:)
    identities = cameras.map(&:identity).uniq
    identities.filter_map { |identity| camera_at(identity, at)&.key }.reject { |key| key == except }
  end

  def cameras
    @cameras ||= @sources.select { |source| source.kind == :camera }.sort_by(&:started_at)
  end

  def camera_at(identity, at)
    cameras.select { |source| source.identity == identity && covers?(source, at) }.max_by(&:started_at)
  end

  def screen_at(at)
    @sources.select { |source| source.kind == :screen && covers?(source, at) }.max_by(&:started_at)
  end

  # Dernière mise en avant explicite posée avant `at` ; nil si elle a été
  # retirée ou s'il n'y en a pas.
  def spotlight_at(at)
    @spotlights.reverse.find { |change| seconds(change.at) <= at }&.identity
  end

  # Parmi les personnes qui parlent à `at`, celle dont la prise de parole a
  # commencé le plus récemment.
  def speaker_at(at)
    speaking = speech.filter_map do |identity, runs|
      run = runs.find { |from, to| from <= at && at < to }
      [ identity, run[0] ] if run
    end
    speaking.max_by(&:last)&.first
  end

  def covers?(source, at)
    seconds(source.started_at) <= at && at < seconds(source.ended_at)
  end

  def merge_runs(runs)
    runs.sort.each_with_object([]) do |(from, to), merged|
      if merged.any? && from - merged.last[1] < SPEECH_GAP
        merged.last[1] = [ merged.last[1], to ].max
      else
        merged << [ from, to ]
      end
    end
  end

  def overlap(from, to, other_from, other_to)
    [ to, other_to ].min - [ from, other_from ].max
  end

  def seconds(time)
    (time - @origin).to_f
  end
end
