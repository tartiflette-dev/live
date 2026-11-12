# Un fait de présence dans un webinaire, pour la page « Présence »
# (PresenceTimeline) : qui s'est connecté quand, et qui a essayé sans entrer.
#
# Sortes :
#   • joined / left   — arrivée et départ dans la salle (webhooks LiveKit
#                       participant_joined / participant_left) ;
#   • aborted         — connexion interrompue avant d'aboutir
#                       (participant_connection_aborted) ;
#   • refused         — arrivée refusée par la garde du webhook (droit retiré) ;
#   • room_finished   — LiveKit a fermé la salle : plus personne n'y est ;
#   • page_opened     — page du café ou lien intervenant ouvert par une
#                       personne reconnue (WebinarsController) ;
#   • token_issued    — accès à la salle délivré (Api::TokensController).
#
# `identity` = identité LiveKit humaine (`host-<sub>`, `speaker-<id>`,
# `viewer-<id>`) ; ni l'enregistreur ni le transcripteur. Jamais de nom ni
# d'adresse ici : la personne est résolue à la lecture, ce qui suit son
# effacement (RGPD) sans réécrire le journal.
#
# `source` : « livekit » (webhook reçu), « livekit_log » (webhook rejoué
# depuis le journal du serveur LiveKit, PresenceLogImport), « app » (vu par
# l'app elle-même).
class PresenceEvent < ApplicationRecord
  ROOM_KINDS = %w[joined left aborted refused room_finished].freeze
  ATTEMPT_KINDS = %w[page_opened token_issued].freeze
  KINDS = (ROOM_KINDS + ATTEMPT_KINDS).freeze
  SOURCES = %w[livekit livekit_log app].freeze
  IDENTITY = /\A(?:host-.+|speaker-[1-9]\d*|viewer-[1-9]\d*)\z/
  # Une page rechargée ou une salle remontée ne fait qu'une tentative.
  ATTEMPT_DEDUP_WINDOW = 2.minutes

  belongs_to :webinar

  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :occurred_at, presence: true
  validates :identity, format: { with: IDENTITY }, unless: -> { kind == "room_finished" }

  scope :chronological, -> { order(:occurred_at, :id) }

  def self.human_identity?(identity)
    identity.is_a?(String) && IDENTITY.match?(identity)
  end

  # Heure du fait selon LiveKit (`created_at`, secondes), sinon réception.
  def self.webhook_time(event)
    seconds = Integer(event["created_at"].to_s, exception: false)
    seconds&.positive? ? Time.zone.at(seconds) : Time.current
  end

  # Fait de salle reçu par webhook. Rejoué (même `livekit_event_id`) : rien.
  # @return [PresenceEvent, nil]
  def self.record_room!(webinar, kind, identity, at:, livekit_event_id: nil, source: "livekit")
    create!(webinar: webinar, kind: kind, identity: identity, occurred_at: at,
            livekit_event_id: livekit_event_id.presence, source: source)
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # Tentative vue par l'app ; une seule par personne et par fenêtre.
  # @return [PresenceEvent, nil]
  def self.record_attempt!(webinar, kind, identity, at: Time.current)
    return unless human_identity?(identity)
    return if where(webinar: webinar, identity: identity, kind: kind, occurred_at: (at - ATTEMPT_DEDUP_WINDOW)..at).exists?

    create!(webinar: webinar, kind: kind, identity: identity, occurred_at: at, source: "app")
  end
end
