require "timeout"

# Qui peut publier (caméra, micro, partage d'écran) dans la salle d'un
# webinaire : la SEULE règle, et
# c'est LiveKit qui l'applique. La fenêtre de consentement côté client ne
# fait que demander ; sans cette garde, un jeton qui publie de droit
# laisserait entrer image et voix dans le composite (replay) et la
# transcription sans accord.
#
#   • propriétaire du webinaire et animateurs du projet : exemptés de la
#     fenêtre, publient de droit, toutes sources ;
#   • co-animateur invité, intervenant non retiré de la salle : seulement
#     sous un accord à l'image en cours (ParticipantConsent) ;
#   • spectateur : sous un accord en cours ET la parole accordée (main levée).
# Qui publie sous accord n'a que les sources de SOURCES.
#
# Appelée par :
#   • le jeton (Api::TokensController) : `token_grant` ;
#   • l'accord (Api::ParticipantConsentsController), le retrait
#     (ConsentWithdrawal, PublishingRevocationJob) et l'arrivée dans la salle
#     (webhook participant_joined), À TRAVERS HandRaiseControl
#     (`open_publication`, `close_publication_unless_allowed`,
#     `reconcile_publication`) ;
#   • la main levée (HandRaiseControl) : la parole donnée n'ouvre la
#     publication qu'avec l'accord (`consented?`, puis `update!`).
#
# `open!`, `close!` et `reconcile_on_join` relisent parole et accord en base
# puis appellent LiveKit : ils s'exécutent sous le verrou de HandRaiseControl,
# le même que donner ou retirer la parole. Hors de ce verrou, une parole
# retirée entre la lecture et l'appel serait rouverte.
class PublishPermission
  RPC_TIMEOUT_SECONDS = 5
  # Noms LiveKit (jeton : `canPublishSources` ; RoomService : TrackSource).
  SOURCES = %w[camera microphone screen_share screen_share_audio].freeze

  # Animation de droit : propriétaire et animateurs du projet.
  def self.exempt?(webinar, record)
    record.is_a?(User) && %i[owner project_host].include?(webinar.role_for(record))
  end

  # Doit donner son accord avant de publier : intervenant et spectateur de
  # ce webinaire, co-animateur invité.
  def self.consent_required?(webinar, record)
    case record
    when Speaker, Registration then record.webinar_id == webinar.id
    when User then webinar.role_for(record) == :guest_host
    else false
    end
  end

  # Identité LiveKit de `record` (forme émise par Api::TokensController).
  def self.identity_for(record)
    case record
    when Speaker then "speaker-#{record.id}"
    when Registration then "viewer-#{record.id}"
    when User then "host-#{record.oidc_sub}"
    end
  end

  def initialize(webinar, client: nil)
    @webinar = webinar
    @client = client
  end

  # Identité de l'animation de droit, même sans compte enregistré pour le
  # propriétaire (même règle que TrackRecordingSession.authorized?).
  def exempt_identity?(identity)
    sub = identity.to_s[/\Ahost-(.+)\z/, 1]
    return false unless sub

    sub == @webinar.host_sub || self.class.exempt?(@webinar, User.find_by(oidc_sub: sub))
  end

  def consented?(record)
    self.class.exempt?(@webinar, record) ||
      (self.class.consent_required?(@webinar, record) && ParticipantConsent.current_for(record, webinar: @webinar).present?)
  end

  # À la parole : le spectateur main accordée, l'intervenant tant qu'il n'est
  # pas retiré de la salle, le co-animateur de droit. Relu en base à chaque
  # appel.
  def floor?(record)
    case record
    when Registration then @webinar.hand_raises.granted.exists?(registration: record)
    when Speaker then @webinar.speakers.where(id: record.id, room_removed_at: nil).exists?
    else true
    end
  end

  # `record` peut-il publier maintenant ?
  def allowed?(record)
    consented?(record) && floor?(record)
  end

  # Droit de publier du jeton LiveKit : { can_publish:, sources: } ;
  # `sources` nil = toutes (animation de droit).
  def token_grant(record)
    return { can_publish: true, sources: nil } if self.class.exempt?(@webinar, record)

    allowed?(record) ? { can_publish: true, sources: SOURCES } : { can_publish: false, sources: nil }
  end

  # Ouvre la publication si la règle le permet (sous le verrou de
  # HandRaiseControl, voir l'en-tête).
  # @return [Boolean] ouverte ; false si la règle ne l'ouvre pas, ou si la
  #   personne n'est pas encore dans la salle (reconcile_on_join l'ouvrira).
  # @raise [RoomServiceClient::Error] salle injoignable
  def open!(record)
    return false unless allowed?(record)

    apply!(record, publish: true)
  end

  # @return [Boolean] fermée ; false si la personne n'est pas dans la salle.
  # @raise [RoomServiceClient::Error] salle injoignable
  def close!(record)
    apply!(record, publish: false)
  end

  # Webhook participant_joined, identité déjà autorisée : la permission du
  # jeton (`publishing`) est remise d'accord avec la règle.
  def reconcile_on_join(identity, publishing:)
    record = record_for(identity)
    return if record.nil? || self.class.exempt?(@webinar, record)

    allowed = allowed?(record)
    if publishing && !allowed
      close!(record)
    elsif !publishing && allowed
      open!(record)
    end
  end

  # Permission LiveKit posée telle quelle, pour qui a déjà appliqué la règle
  # (HandRaiseControl). @raise [RoomServiceClient::Error] y compris not_found
  def update!(record, publish:)
    Timeout.timeout(RPC_TIMEOUT_SECONDS, RoomServiceClient::Error, "LiveKit permission update timed out") do
      client.update_participant(room: @webinar.room_name, identity: self.class.identity_for(record),
                                can_publish: publish, sources: publish ? SOURCES : [])
    end
  end

  # Participant de ce webinaire derrière une identité LiveKit
  # (`speaker-<id>`, `viewer-<id>`, `host-<sub>`), ou nil.
  def record_for(identity)
    case identity.to_s
    when /\Aspeaker-([1-9]\d*)\z/ then @webinar.speakers.find_by(id: Regexp.last_match(1))
    when /\Aviewer-([1-9]\d*)\z/ then @webinar.registrations.find_by(id: Regexp.last_match(1))
    when /\Ahost-(.+)\z/ then User.find_by(oidc_sub: Regexp.last_match(1))
    end
  end

  private

  def apply!(record, publish:)
    update!(record, publish: publish)
    true
  rescue RoomServiceClient::RemoteError => error
    raise unless error.code == "not_found"

    false
  end

  def client
    @client ||= Rails.configuration.x.room_service_client_factory.call
  end
end
