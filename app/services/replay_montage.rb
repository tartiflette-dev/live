# frozen_string_literal: true

# Montage du replay piloté par la parole : la personne qui parle en grand,
# les autres en vignettes sur le côté, l'écran partagé en grand quand il y
# en a un (MontagePlan), rendu en 720p H.264 CRF 23 depuis les pistes
# séparées. Devient la copie de diffusion du replay
# (`Replay#derived_path`) ; les bruts ne sont jamais modifiés.
#
# Rendu HORS de l'application (mémoire du conteneur, Puma, I/O disque) par
# un moteur externe, non distribué avec l'application, lancé hors direct sur
# l'hôte des enregistrements (docs/replays.md, « Rendus hors de
# l'application »). Contrat par fichiers, relatifs à RECORDINGS_ROOT :
#   _montages/demandes/<replay id>.json   demande, écrite ici (`request!`) ;
#   _replays/<slug>/montage-<composite id>.mp4         montage, n'apparaît que vérifié ;
#   _replays/<slug>/montage-<composite id>.mp4.json    marqueur du moteur
#                                         (`done` ou `failed`, `request_id`).
# ReplayMontageSweepJob adopte un montage fini (`adopt!`) puis retire sa demande.
#
# Horloge : t = 0 au `started_at` de la vidéo de référence, fin à son
# `ended_at` — l'horloge des sous-titres et des statistiques (Replay), celle
# du serveur. Les pistes séparées y sont placées par `media_started_at`. Le
# fichier composite, lui, commence quand le navigateur de l'egress a rejoint
# la salle (plus de 10 s plus tard, mesuré sur un direct réel) et son horloge
# dérive (de l'ordre de -100 ppm) : le moteur mesure les deux par corrélation
# de son son avec les micros séparés (`probes`).
#
# Son = celui du composite : il contient toutes les voix, y compris celles
# des personnes sans piste séparée, tel qu'on l'a entendu en direct. Un mix
# des micros séparés en perdrait.
class ReplayMontage
  QUEUE_DIR = "_montages/demandes"
  OUTPUT_PREFIX = "montage-"
  FORMAT_VERSION = 1
  # Fenêtres de corrélation du son (`probes`) : PROBE_SECONDS au plus, et au
  # moins MIN_PROBE_SPEECH de parole de la personne du micro.
  PROBE_SECONDS = 240
  PROBE_STEP = 30
  PROBE_PARTS = 4
  PROBES_PER_PART = 2
  MIN_PROBE_SPEECH = 30
  VIDEO_SOURCES = { "camera" => :camera, "screen_share" => :screen }.freeze
  # Le moteur de rendu passe au moins chaque nuit : au-delà, une demande en
  # file est en retard.
  OVERDUE_AFTER = 30.hours

  attr_reader :replay

  def initialize(replay)
    @replay = replay
  end

  def composite
    replay.recording
  end

  def webinar
    replay.webinar
  end

  def plan
    @plan ||= MontagePlan.new(origin: composite.started_at, finish: composite.ended_at,
                              segments: segments, sources: video_tracks.map { |track| source_for(track) },
                              spotlights: spotlights)
  end

  # Document de rendu, en secondes depuis `window.begin` (0 par défaut).
  # Une fenêtre sert aux extraits de contrôle (`replays:montage_extrait`).
  # @param window [Range, nil] bornes en secondes de la vidéo
  # @return [Hash]
  def document(window: nil)
    from = window&.begin.to_f
    to = window&.end || plan_duration
    shots = plan.shots.filter_map { |shot| clip(shot, from, to) }
    used = shots.flat_map { |shot| [ shot[:main], *shot[:thumbnails] ] }.compact.uniq
    {
      version: FORMAT_VERSION,
      webinar: webinar.slug,
      replay_id: replay.id,
      output: window ? excerpt_relative(from, to) : output_relative,
      duration: (to - from).round(3),
      composite: { path: composite.path, end: (plan_duration - from).round(3) },
      sources: video_tracks.select { |track| used.include?(key(track)) }
                           .map { |track| { key: key(track), path: track.path, offset: (offset(track) - from).round(3) } },
      probes: probes.map { |probe| probe.merge(offset: (probe[:offset] - from).round(3), from: probe[:from] - from, to: probe[:to] - from) },
      shots: shots,
      notes: notes
    }
  end

  # Dépose la demande de montage (remplacement atomique). Une demande au
  # même contenu déjà en file est gardée ; sinon elle reçoit un nouvel
  # identifiant, et le moteur externe la rend à son passage suivant.
  # @return [Boolean] true si une nouvelle demande a été écrite
  def request!(now: Time.current)
    raise ArgumentError, "vidéo de référence illisible" unless composite.downloadable?

    content = document
    digest = Digest::SHA256.hexdigest(JSON.generate(content))
    return false if current?(digest)

    write_json(request_path, content.merge(request_id: SecureRandom.uuid, digest: digest, requested_at: now.utc.iso8601))
    true
  end

  # :none (rien de demandé), :pending (en file), :done (rendu, pas encore
  # adopté), :failed (le moteur a refusé ou échoué, `failure` dit pourquoi),
  # :adopted (copie de diffusion du replay).
  def status
    return :adopted if request.empty? && replay.derived_path == output_relative && output.file?
    return :none if request.empty?

    case marker_for_request["status"]
    when "done" then output.file? && output.size == marker["output_size"] ? :done : :failed
    when "failed" then :failed
    else :pending
    end
  end

  def failure
    marker_for_request["reason"] if status == :failed
  end

  def requested_at
    Time.zone.parse(request["requested_at"].to_s) if request["requested_at"]
  end

  # Demande toujours pas rendue après OVERDUE_AFTER : à vérifier côté
  # moteur de rendu (sur l'hôte des enregistrements).
  def overdue?(now = Time.current)
    status == :pending && requested_at.present? && requested_at < now - OVERDUE_AFTER
  end

  # Méthode de calage du son du montage rendu (marqueur du moteur) :
  # "mesuré", "médiane" ou "estimé" ; nil tant qu'aucun montage n'est rendu.
  def audio_method
    marker.dig("audio", "method") if %i[done adopted].include?(status)
  end

  # Montage fini et vérifié → copie de diffusion du replay, demande retirée.
  # @return [Boolean]
  def adopt!
    return false unless status == :done

    replay.update!(derived_path: output_relative)
    File.delete(request_path)
    @request = nil
    true
  end

  # Purge de rétention : montage, marqueur et demande. Rend le nombre de
  # fichiers supprimés.
  def purge!
    [ output, marker_path, request_path ].count do |path|
      File.delete(path) if path.file?
    rescue Errno::ENOENT
      false
    end
  end

  def output_relative
    "#{Replay::DERIVED_SUBDIR}/#{webinar.slug}/#{OUTPUT_PREFIX}#{composite.id}.mp4"
  end

  def self.request_path_for(replay_id)
    Recording.recordings_root.join(QUEUE_DIR, "#{Integer(replay_id)}.json")
  end

  private

  # Même contenu déjà en file (et pas en échec), ou déjà rendu et adopté.
  def current?(digest)
    return marker["digest"] == digest && status == :adopted if request.empty?

    request["digest"] == digest && status != :failed
  end

  def plan_duration
    (composite.ended_at - composite.started_at).to_f
  end

  def segments
    webinar.transcript_segments.where(started_at: ..composite.ended_at, ended_at: composite.started_at..)
           .pluck(:participant_identity, :started_at, :ended_at, :text)
           .map { |identity, from, to, text| MontagePlan::Segment.new(identity: identity, started_at: from, ended_at: to, text: text) }
  end

  # Changements posés pendant la vidéo : un état antérieur peut venir d'une
  # autre séance (salle recréée sans métadonnées).
  def spotlights
    webinar.spotlight_changes.where(changed_at: composite.started_at..composite.ended_at).chronological
           .map { |change| MontagePlan::Spotlight.new(at: change.changed_at, identity: change.identity) }
  end

  def video_tracks
    @video_tracks ||= tracks_overlapping(VIDEO_SOURCES.keys)
  end

  def tracks_overlapping(sources)
    webinar.recordings.tracks.done.where(track_source: sources)
           .where(started_at: ...composite.ended_at, ended_at: composite.started_at..)
           .reorder(:started_at, :id).select(&:downloadable?)
  end

  def source_for(track)
    start = composite.started_at + offset(track)
    MontagePlan::Source.new(key: key(track), identity: track.participant_identity,
                            kind: VIDEO_SOURCES.fetch(track.track_source), started_at: start, ended_at: track.ended_at)
  end

  def key(track)
    "v#{track.id}"
  end

  # Instant (s depuis le début de la vidéo) du temps 0 du fichier de la
  # piste : `media_started_at`, corrigé pour la vidéo du délai d'activation
  # (même calage que ParticipantMux) ; à défaut l'heure de la demande
  # d'egress, approximative (`notes`).
  def offset(track)
    start = track.media_started_at
    start -= ParticipantMux::VIDEO_ACTIVATION_LAG if start && track.track_source != "microphone"
    ((start || track.started_at) - composite.started_at).to_f
  end

  def notes
    video_tracks.reject(&:media_started_at).map do |track|
      "#{track.participant_identity} (piste #{track.id}) : calage approximatif, instant de début de fichier inconnu"
    end
  end

  # Fenêtres de corrélation du son, réparties sur PROBE_PARTS tranches de la
  # vidéo (le moteur en tire la dérive) : dans chaque tranche, les
  # PROBES_PER_PART micros calés (media_started_at) dont la personne y parle
  # le plus, sur sa fenêtre la plus dense. Deux par tranche : un micro peut
  # être muet dans son fichier (cas observé : celui de l'animation, une
  # partie du direct) ; le moteur écarte une mesure sans pic net.
  def probes
    mics = tracks_overlapping([ "microphone" ]).select(&:media_started_at)
    part = plan_duration / PROBE_PARTS
    length = [ PROBE_SECONDS, part ].min
    Array.new(PROBE_PARTS) do |index|
      mics.filter_map { |mic| probe_for(mic, index * part, (index + 1) * part, length) }
          .max_by(PROBES_PER_PART) { |probe| probe[:spoken] }
    end.flatten.map { |probe| probe.except(:spoken) }
  end

  def probe_for(mic, part_from, part_to, length)
    runs = plan.speech.fetch(mic.participant_identity, [])
    first = [ offset(mic), part_from ].max
    last = [ (mic.ended_at - composite.started_at).to_f, part_to ].min - length
    return if last < first

    start = first.step(last, PROBE_STEP).max_by { |from| spoken(runs, from, from + length) }
    speech = spoken(runs, start, start + length)
    return if speech < MIN_PROBE_SPEECH

    { path: mic.path, offset: offset(mic).round(3), from: start.round(3), to: (start + length).round(3), spoken: speech }
  end

  def spoken(runs, from, to)
    runs.sum { |run_from, run_to| [ [ to, run_to ].min - [ from, run_from ].max, 0 ].max }
  end

  def clip(shot, from, to)
    start = [ shot.from, from ].max
    finish = [ shot.to, to ].min
    return if finish <= start

    { from: (start - from).round(3), to: (finish - from).round(3), layout: shot.layout.to_s,
      main: shot.main, thumbnails: shot.thumbnails }
  end

  def excerpt_relative(from, to)
    "#{Replay::DERIVED_SUBDIR}/#{webinar.slug}/extrait-#{composite.id}-#{from.round}-#{to.round}.mp4"
  end

  def root
    Recording.recordings_root
  end

  def output
    root.join(output_relative)
  end

  def marker_path
    output.sub_ext(".mp4.json")
  end

  def request_path
    self.class.request_path_for(replay.id)
  end

  def request
    @request ||= read_json(request_path)
  end

  def marker
    @marker ||= read_json(marker_path)
  end

  # Le marqueur ne vaut que pour la demande en file.
  def marker_for_request
    request["request_id"].present? && marker["request_id"] == request["request_id"] ? marker : {}
  end

  def read_json(path)
    return {} unless path.file?

    JSON.parse(path.read)
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def write_json(path, data)
    FileUtils.mkdir_p(path.dirname)
    tmp = path.dirname.join(".#{path.basename}.#{SecureRandom.hex(4)}.tmp")
    tmp.write("#{JSON.generate(data)}\n")
    File.rename(tmp, path)
    @request = nil
  end
end
