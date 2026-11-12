require "timeout"

# Modération du direct depuis la régie : couper le micro d'un participant, ou le retirer de la salle.
#
# Cibles : intervenants (`speaker-<id>`) et spectateurs (`viewer-<id>`) DU
# webinaire, jamais une identité d'animation (`host-*`) : un co-animateur
# invité ne peut pas expulser le propriétaire (privilege-escalation). L'autorisation de l'appelant (toute l'animation)
# revient à WebinarParticipantsController.
#
# `present_only: true` (co-animateur invité) : la cible doit être
# dans la salle LiveKit au moment de la commande, vérifié AVANT toute
# écriture ; absente → NotInRoom, LiveKit injoignable → RoomServiceClient::Error,
# rien n'est touché dans les deux cas. Sans cela, l'animation limitée
# révoquerait le lien d'un intervenant ou mettrait l'adresse d'un inscrit en
# pierre tombale, ce que seule la gestion (owner, project_host) peut faire.
#
# Retirer = retrait DURABLE d'abord (Speaker#remove_from_room!, qui révoque
# aussi le lien ; Registration#remove_from_room! ; les deux pour un
# intervenant rattaché à son inscription par le lien participants privé — un
# rattachement toujours PROUVÉ, InvitationEntry),
# expulsion LiveKit ensuite : si la salle ne répond pas, la personne est déjà
# retirée (RoomRemoval : jeton, lien partagé, inscription, discussion, main
# levée ; garde webhook participant_joined) et le retrait se relance sans
# effet de bord. La main levée d'un spectateur ne se referme qu'une fois
# l'expulsion acquise : tant qu'il est dans la salle, sa main reste visible
# (et « Retirer la parole » possible) dans « Mains levées ».
#
# Ce que « Retirer » garantit et ne garantit pas : docs/moderation.md.
#
# Couper le micro = mute serveur de ses pistes audio publiées (micro, son
# d'un partage d'écran). LiveKit laisse la personne rallumer son micro :
# l'arme durable reste « Retirer ».
class ParticipantModeration
  IDENTITY_FORMAT = /\A(speaker|viewer)-([1-9]\d*)\z/
  RPC_TIMEOUT_SECONDS = 5

  class InvalidIdentity < StandardError; end
  class NotInRoom < StandardError; end

  def self.target?(identity)
    identity.is_a?(String) && IDENTITY_FORMAT.match?(identity)
  end

  # Pistes audio publiées et audibles d'un participant tel que le décrit
  # RoomServiceClient#list_participants.
  def self.open_audio_tracks(participant)
    Array(participant[:tracks]).select { |track| track[:type] == "AUDIO" && !track[:muted] }
  end

  # @raise [InvalidIdentity] identité hors des cibles permises
  # @raise [ActiveRecord::RecordNotFound] personne inconnue de ce webinaire
  def initialize(webinar, identity, present_only: false, client: nil)
    raise InvalidIdentity, "seuls un intervenant ou un spectateur se modèrent" unless self.class.target?(identity)

    kind, id = IDENTITY_FORMAT.match(identity).captures
    @webinar = webinar
    @identity = identity
    @record = kind == "speaker" ? webinar.speakers.find(id) : webinar.registrations.find(id)
    @present_only = present_only
    @client = client
  end

  # @return [Integer] pistes coupées ; 0 si la personne est absente ou muette
  # @raise [NotInRoom] absente, en `present_only`
  def mute_audio
    within_timeout do
      participant = present_participant
      raise NotInRoom if participant.nil? && @present_only

      tracks = self.class.open_audio_tracks(participant || {})
      tracks.count do |track|
        unless_gone { client.mute_track(room: @webinar.room_name, identity: @identity, track_sid: track[:sid]) }
      end
    end
  ensure
    RoomSnapshot.expire(@webinar)
  end

  # @raise [NotInRoom] absente, en `present_only` : rien n'est retiré
  def remove
    within_timeout { raise NotInRoom unless present_participant } if @present_only
    revoke
    within_timeout { unless_gone { client.remove_participant(room: @webinar.room_name, identity: @identity) } }
    HandRaiseControl.new(@webinar).drop_hand(registration) if registration
  ensure
    RoomSnapshot.expire(@webinar)
  end

  # Retiré, un intervenant entré par le lien participants privé peut revenir
  # sous une nouvelle identité par ce lien tant qu'il vit (docs/moderation.md).
  # La régie propose alors de le régénérer, jamais d'office : ce serait couper
  # les intervenants légitimes qui n'ont pas encore cliqué.
  def share_link_reentry?
    @record.is_a?(Speaker) && @record.entered_by_share_link? && @webinar.share_token.present?
  end

  private

  # Un intervenant rattaché l'est toujours sur preuve de la boîte de son
  # adresse (Speaker#registration) : son inscription est retirée avec lui et
  # garde son adresse, même non confirmée (pas de pierre tombale qui la
  # libérerait pour une réinscription).
  def revoke
    @record.remove_from_room!
    registration.remove_from_room!(mailbox_proven: true) if @record.is_a?(Speaker) && registration
  end

  # Inscription de la personne : la sienne (spectateur), ou celle de
  # l'intervenant rattaché (Speaker#registration), absente sinon.
  def registration
    @record.is_a?(Speaker) ? @record.registration : @record
  end

  # LiveKit ne connaît pas (plus) la personne ou la piste : partie entre la
  # lecture de la salle et la commande, il n'y a plus rien à couper ni à
  # expulser. @return [Boolean] la commande a porté
  def unless_gone
    yield
    true
  rescue RoomServiceClient::RemoteError => e
    raise unless e.code == "not_found"

    false
  end

  def present_participant
    client.list_participants(room: @webinar.room_name).find { |participant| participant[:identity] == @identity }
  end

  def within_timeout(&)
    Timeout.timeout(RPC_TIMEOUT_SECONDS, RoomServiceClient::Error, "LiveKit moderation timed out", &)
  end

  def client
    @client ||= Rails.configuration.x.room_service_client_factory.call
  end
end
