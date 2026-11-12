# Séance de visionnage d'un replay : un onglet (`session_key`, tiré par le
# lecteur à l'ouverture de la page), une personne — inscription OU compte,
# jamais les deux (contrainte en base).
#
# Alimentée par les battements du lecteur (`beat!`, ~15 s, et à chaque
# pause, saut ou fermeture) : chacun déclare le passage lu depuis le
# précédent, `[from, to]` en secondes de la vidéo. Le serveur n'en crédite
# que ce que l'horloge permet : un passage plus long que le temps écoulé
# depuis le battement précédent (×2 pour la lecture accélérée, plus une
# marge) n'est pas compté. `intervals` = passages vus, fusionnés ;
# `watched_seconds` = temps de lecture cumulé.
#
# Débit borné : un battement trop rapproché du précédent est ignoré
# (aucune écriture), une personne ouvre au plus MAX_SESSIONS_PER_DAY séances
# par replay et par jour, et `intervals` garde au plus MAX_INTERVALS passages.
# Écriture sous verrou de la ligne (`with_lock`) : SQLite prend son verrou
# d'écriture (BEGIN IMMEDIATE) à la première requête de la transaction, deux
# battements concurrents d'une même séance ne se perdent pas.
class ReplayView < ApplicationRecord
  MIN_BEAT_INTERVAL = 2.seconds
  PLAYBACK_RATE_MAX = 2.0
  CLOCK_SLACK_SECONDS = 3.0
  # Premier battement d'une séance : rien d'antérieur pour borner le passage.
  FIRST_BEAT_MAX_SPAN = 40.0
  MAX_SESSIONS_PER_DAY = 50
  MAX_INTERVALS = 200
  # Deux passages séparés de moins d'une seconde n'en font qu'un.
  MERGE_GAP_SECONDS = 1.0
  SESSION_KEY_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  # Battement refusé : séance d'une autre personne, ou plafond de séances.
  class Refused < StandardError; end

  belongs_to :replay, inverse_of: :views
  belongs_to :registration, optional: true
  belongs_to :user, optional: true

  validates :session_key, format: { with: SESSION_KEY_FORMAT }

  scope :for_viewer, ->(viewer) { where(viewer_attributes(viewer)) }

  # Enregistre un battement de `viewer` (Registration ou User).
  # @return [ReplayView]
  # @raise [Refused]
  def self.beat!(replay:, viewer:, session_key:, from:, to:, playing:, now: Time.current)
    view = open_session(replay, viewer, session_key, now)
    view.record_beat(from: from, to: to, playing: playing, now: now)
    view
  end

  def self.open_session(replay, viewer, session_key, now)
    view = replay.views.find_by(session_key: session_key)
    unless view
      raise Refused, "sessions_cap" if replay.views.for_viewer(viewer).where(started_at: (now - 1.day)..).count >= MAX_SESSIONS_PER_DAY

      view = replay.views.create_or_find_by!(session_key: session_key) do |created|
        created.assign_attributes(viewer_attributes(viewer).merge(started_at: now, last_seen_at: now))
      end
    end
    raise Refused, "foreign_session" unless view.viewer == viewer

    view
  end
  private_class_method :open_session

  # Colonnes qui désignent `viewer` (Registration ou User).
  def self.viewer_attributes(viewer)
    viewer.is_a?(User) ? { user: viewer } : { registration: viewer }
  end

  # Passages triés, chevauchements (et trous de moins d'une seconde)
  # fusionnés. Sert aux séances et au cumul par personne (ReplayStats).
  # @param list [Array<Array(Float, Float)>]
  # @return [Array<Array(Float, Float)>]
  def self.merge_intervals(list)
    list.sort_by(&:first).each_with_object([]) do |(start, finish), merged|
      if merged.any? && start <= merged.last[1] + MERGE_GAP_SECONDS
        merged.last[1] = [ merged.last[1], finish ].max
      else
        merged << [ start, finish ]
      end
    end
  end

  def viewer
    user || registration
  end

  def record_beat(from:, to:, playing:, now:)
    with_lock do
      next if beats_count.positive? && now - last_seen_at < MIN_BEAT_INTERVAL

      attributes = { last_position: clamp(to), playing: playing, last_seen_at: now, beats_count: beats_count + 1 }
      if (span = credited_span(from, to, now))
        attributes.merge!(intervals: merge_interval(span), watched_seconds: watched_seconds + span[1] - span[0])
      end
      update!(attributes)
    end
  end

  private

  # Passage crédité, borné à la vidéo ; nil s'il est vide ou plus long que
  # ce que l'horloge permet depuis le battement précédent.
  def credited_span(from, to, now)
    start = clamp(from)
    finish = clamp(to)
    return nil unless finish > start

    allowed = beats_count.zero? ? FIRST_BEAT_MAX_SPAN : (now - last_seen_at) * PLAYBACK_RATE_MAX + CLOCK_SLACK_SECONDS
    [ start, finish ] if finish - start <= allowed
  end

  def clamp(position)
    position.to_f.clamp(0.0, replay.duration)
  end

  # Passages fusionnés, triés ; au-delà de MAX_INTERVALS passages distincts,
  # le nouveau n'est pas gardé (son temps reste compté).
  def merge_interval(span)
    merged = self.class.merge_intervals(intervals + [ span ])
    merged.size > MAX_INTERVALS ? intervals : merged
  end
end
