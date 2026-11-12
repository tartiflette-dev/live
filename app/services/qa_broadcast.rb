# frozen_string_literal: true

require "timeout"

# Diffusion temps réel de la file Q&R. Le SERVEUR
# publie sur le data channel LiveKit, à chaque changement de la file,
# l'enveloppe `{ topic: "qa", displayed: <QaItem#public_attributes> | null }` :
#   - toute la salle y lit la question affichée à l'écran (bandeau) ;
#   - la console de l'animation y voit le signal de relire la file par HTTP.
# Le paquet ne porte JAMAIS la file elle-même ni ses auteurs : chacun dans la
# salle le reçoit. Même transport et mêmes garanties que MessageBroadcast :
# la persistance fait foi, un échec est journalisé et rendu (`:unavailable`),
# les clients rattrapent au prochain poll.
class QaBroadcast
  TOPIC = "qa"
  RPC_TIMEOUT_SECONDS = 3

  def initialize(client: nil, timeout: RPC_TIMEOUT_SECONDS)
    @client = client
    @timeout = timeout
  end

  # @return [Symbol] :sent | :unavailable
  def deliver(webinar)
    data = self.class.envelope(webinar).to_json
    Timeout.timeout(@timeout, RoomServiceClient::Error, "diffusion LiveKit trop lente") do
      client.send_data(room: webinar.room_name, data: data, kind: :reliable)
    end
    :sent
  rescue RoomServiceClient::Error => error
    Rails.logger.warn("[qa_broadcast] webinar=#{webinar.id} #{error.class}: #{error.message}")
    :unavailable
  end

  # Même forme pour le paquet temps réel et `GET /w/:slug/qa/current`.
  def self.envelope(webinar)
    { topic: TOPIC, displayed: webinar.qa_items.displayed.first&.public_attributes }
  end

  private

  def client
    @client ||= Rails.configuration.x.room_service_client_factory.call
  end
end
