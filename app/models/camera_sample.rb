# Une mesure de l'émetteur caméra d'une personne qui publie, relevée par son
# navigateur (rooms/camera_health.jsx, getStats sur le RTCRtpSender) toutes
# les 10 s et remontée par POST /api/camera_samples.
#
# Pourquoi côté navigateur : la couche simulcast réellement émise, la raison
# de sa limite (`qualityLimitationReason` : bandwidth, cpu, other, none) et
# l'encodeur (`encoderImplementation`) n'existent que là. Lors d'un direct, une
# caméra n'a émis que la couche basse (320x180) tout le direct sans que le
# serveur puisse dire pourquoi.
#
# `top_*` = la couche la plus haute qui émet vraiment des images ; nil si
# aucune n'en émet. `paused_layers` = couches mises en pause par dynacast
# (personne ne les regarde) : une couche haute en pause n'est pas une
# dégradation. `event` : `sample` (relevé périodique) ou l'issue du repli
# sans simulcast, journalisé une fois par publication (`simulcast_fallback`,
# `simulcast_fallback_failed`), avec la mesure qui l'a déclenché.
#
# Identité = celle que le serveur reconnaît (RoomParticipant), jamais une
# valeur du client. Journal technique, purgé au bout de RETENTION
# (RetentionPurgeJob) ; MIN_INTERVAL borne le volume par personne.
class CameraSample < ApplicationRecord
  EVENTS = %w[sample simulcast_fallback simulcast_fallback_failed].freeze
  FALLBACK_EVENTS = (EVENTS - [ "sample" ]).freeze
  # Petit côté de l'image : une caméra de téléphone en portrait, 720 sur 1280,
  # est en 720p comme une webcam en 1280x720.
  TARGET_SHORT_SIDE = 720
  # Une dégradation n'alerte qu'au-delà de cette durée, mesurée entre la
  # première et la dernière mesure dégradée consécutives (borne basse : la
  # dégradation a pu commencer avant la première).
  ALERT_AFTER = 15.seconds
  # Sans mesure depuis, la personne ne publie plus sa caméra (coupée, partie).
  STALE_AFTER = 25.seconds
  LOOKBACK = 1.minute
  # Replis montrés en régie : ceux du direct en cours (même borne que la
  # fenêtre d'enregistrement, TrackRecordingSession::DEFAULT_WINDOW_MAX_HOURS).
  FALLBACK_HORIZON = 4.hours
  # Relevé toutes les 10 s côté navigateur ; au-delà d'une mesure par
  # MIN_INTERVAL, le serveur refuse (volume borné par personne).
  MIN_INTERVAL = 5.seconds
  RETENTION = 30.days
  MAX_LAYERS = 4
  MAX_DIMENSION = 8192
  MAX_FPS = 240
  # Une couche : { rid, active, width, height, fps, reason } (camera_stats.mjs).
  LAYER_KEYS = %w[rid active width height fps reason].freeze
  MAX_RID_LENGTH = 8
  MAX_REASON_LENGTH = 32
  # Tronqué à cette longueur par le client (camera_stats.mjs).
  MAX_ENCODER_LENGTH = 128

  belongs_to :webinar, inverse_of: :camera_samples

  validates :participant_identity, presence: true, length: { maximum: 255 }
  validates :event, inclusion: { in: EVENTS }
  validates :publication_sid, length: { maximum: 64 }
  validates :quality_limitation_reason, length: { maximum: MAX_REASON_LENGTH }
  validates :encoder_implementation, length: { maximum: MAX_ENCODER_LENGTH }
  validates :top_width, :top_height, :capture_width, :capture_height,
            numericality: { only_integer: true, in: 0..MAX_DIMENSION }, allow_nil: true
  validates :frames_per_second, numericality: { in: 0..MAX_FPS }, allow_nil: true
  validates :paused_layers, numericality: { only_integer: true, in: 0..MAX_LAYERS }
  validate :layers_bounded

  scope :expired, ->(now = Time.current) { where(created_at: ...now - RETENTION) }

  # Une mesure de cette personne vient d'arriver : la suivante est refusée.
  def self.too_soon?(webinar, identity, now: Time.current)
    where(webinar: webinar, participant_identity: identity, created_at: (now - MIN_INTERVAL)..).exists?
  end

  # État des caméras pour la régie (/regie/status, `camera_health`).
  # @return [Hash] { alerts: [...], fallbacks: [...], measured: [...] }
  #   alerts : une entrée par caméra émise sous 720p depuis plus de
  #   ALERT_AFTER, avec la dernière mesure ; fallbacks : replis sans
  #   simulcast du direct, dans l'ordre ; measured : identités mesurées
  #   depuis STALE_AFTER (une caméra publiée hors de cette liste n'est pas
  #   surveillée : page ouverte avant la mesure, navigateur muet).
  def self.health_for(webinar, now: Time.current)
    {
      alerts: alerts_for(webinar, now),
      fallbacks: fallbacks_for(webinar, now),
      measured: where(webinar: webinar, created_at: (now - STALE_AFTER)..).distinct.order(:participant_identity)
                  .pluck(:participant_identity)
    }
  end

  def self.alerts_for(webinar, now)
    where(webinar: webinar, created_at: (now - LOOKBACK)..).order(:created_at, :id)
      .group_by(&:participant_identity)
      .filter_map { |_identity, samples| degradation_alert(samples, now) }
  end

  def self.degradation_alert(samples, now)
    latest = samples.last
    return if latest.created_at < now - STALE_AFTER

    streak = samples.reverse.take_while(&:degraded?)
    return if streak.empty? || latest.created_at - streak.last.created_at < ALERT_AFTER

    latest.alert_payload(since: streak.last.created_at)
  end

  def self.fallbacks_for(webinar, now)
    where(webinar: webinar, event: FALLBACK_EVENTS, created_at: (now - FALLBACK_HORIZON)..).order(:created_at, :id)
      .map { |sample| { identity: sample.participant_identity, outcome: sample.event,
                        encoder: sample.encoder_implementation, at: sample.created_at.iso8601 } }
  end
  private_class_method :alerts_for, :degradation_alert, :fallbacks_for

  # Émise sous la cible sans que dynacast l'explique. Une seule couche en
  # pause suffit à écarter la mesure : personne ne regarde la couche haute, on
  # ne sait pas si l'encodeur la tiendrait. Pendant l'enregistrement, l'egress
  # de piste demande la couche haute : elle n'est pas en pause.
  def degraded?
    paused_layers.zero? && (top_short_side.nil? || top_short_side < TARGET_SHORT_SIDE)
  end

  def alert_payload(since:)
    {
      identity: participant_identity, width: top_width, height: top_height, fps: frames_per_second,
      reason: quality_limitation_reason, encoder: encoder_implementation,
      capture_width: capture_width, capture_height: capture_height, since: since.iso8601
    }
  end

  private

  def top_short_side
    [ top_width, top_height ].min if top_width && top_height
  end

  def layers_bounded
    errors.add(:layers, :invalid) unless layers.is_a?(Array) && layers.size <= MAX_LAYERS && layers.all? { |layer| valid_layer?(layer) }
  end

  def valid_layer?(layer)
    return false unless layer.is_a?(Hash)

    layer = layer.stringify_keys
    (layer.keys - LAYER_KEYS).empty? && [ true, false ].include?(layer["active"]) &&
      optional_string?(layer["rid"], MAX_RID_LENGTH) && optional_string?(layer["reason"], MAX_REASON_LENGTH) &&
      optional_number?(layer["width"], MAX_DIMENSION, Integer) && optional_number?(layer["height"], MAX_DIMENSION, Integer) &&
      optional_number?(layer["fps"], MAX_FPS, Numeric)
  end

  def optional_string?(value, max_length)
    value.nil? || (value.is_a?(String) && value.length <= max_length)
  end

  def optional_number?(value, max, kind)
    value.nil? || (value.is_a?(kind) && value.between?(0, max))
  end
end
