require "timeout"

# Mise en avant d'un intervenant pendant le direct.
#
# L'état vit dans les MÉTADONNÉES DE LA SALLE LiveKit :
# `{"spotlight": "<identity>"}`, ou `{"spotlight": null}` sans mise en
# avant. LiveKit les diffuse à chaque participant (RoomMetadataChanged)
# et les livre dans la réponse de connexion : un spectateur arrivé en
# retard reçoit l'état courant sans autre appel. Rails est le SEUL
# écrivain (autorisation dans WebinarSpotlightsController) ; les clients
# ne font que lire (rooms/spotlight.jsx).
#
# UpdateRoomMetadata remplace la chaîne entière. La mise en avant est
# aujourd'hui la seule clé : une clé future imposera une lecture avant
# écriture. CreateRoom (RecordingSession) ne touche pas aux métadonnées
# d'une salle existante quand il n'en fournit pas.
#
# Les métadonnées n'ont pas d'historique : chaque changement accepté par
# LiveKit est aussi horodaté dans SpotlightChange, pour que le montage du
# replay respecte un choix explicite de l'animation (MontagePlan).
class RoomSpotlight
  # Identités émises par Api::TokensController : host-<sub>, speaker-<id>,
  # viewer-<id> (spectateur à qui l'on a donné la parole). Un agent
  # (`agent-…`) n'est jamais sur scène, il ne peut pas être mis en avant.
  IDENTITY_FORMAT = /\A(?:host|speaker|viewer)-[A-Za-z0-9_.:@-]{1,200}\z/
  RPC_TIMEOUT_SECONDS = 5

  class InvalidIdentity < StandardError; end

  # Identité mise en avant d'après les métadonnées brutes de la salle —
  # même lecture que les clients (rooms/spotlight.jsx, parseSpotlight) :
  # absentes, illisibles ou d'une autre forme = pas de mise en avant.
  #
  # @param metadata [String, nil]
  # @return [String, nil]
  def self.identity_in(metadata)
    return nil if metadata.blank?

    parsed = JSON.parse(metadata)
    identity = parsed["spotlight"] if parsed.is_a?(Hash)
    identity.is_a?(String) && identity.present? ? identity : nil
  rescue JSON::ParserError
    nil
  end

  def initialize(webinar, client: nil)
    @webinar = webinar
    @client = client
  end

  # @return [String] l'identité mise en avant
  def feature(identity)
    raise InvalidIdentity, "identité de participant invalide" unless identity.is_a?(String) && IDENTITY_FORMAT.match?(identity)

    publish(identity)
  end

  # @return [nil]
  def clear
    publish(nil)
  end

  private

  def publish(identity)
    client = @client || Rails.configuration.x.room_service_client_factory.call
    Timeout.timeout(RPC_TIMEOUT_SECONDS, RoomServiceClient::Error, "LiveKit metadata update timed out") do
      client.update_room_metadata(room: @webinar.room_name, metadata: { spotlight: identity })
    end
    @webinar.spotlight_changes.create!(identity: identity, changed_at: Time.current)
    RoomSnapshot.expire(@webinar)
    identity
  end
end
