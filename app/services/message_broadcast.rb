require "timeout"

# Diffusion temps réel du fil de discussion. Le SERVEUR publie,
# par le data channel LiveKit (RoomServiceClient#send_data, fiable),
# l'enveloppe `{ topic: "chat", message: <Message#public_attributes> }`.
# Ce qui garantit le fil, c'est le client : il rejette tout paquet émis par
# un participant (chat_state.mjs, readServerMessage). Défense en
# profondeur côté jeton : aucun rôle humain ne porte `canPublishData`
# (LivekitTokenService), et la parole accordée (HandRaiseControl →
# update_participant) ne le rouvre pas non plus.
#
# La persistance fait foi : un échec ou une lenteur de diffusion est
# journalisé et RENDU (`:unavailable`), jamais levé — les clients
# rattrapent le message au prochain poll HTTP. Délai court : la discussion
# est l'écriture la plus fréquente de la salle, une LiveKit lente ne doit
# pas immobiliser les threads Puma. Seul l'appel LiveKit est borné : salle
# et données sont calculées avant (en modération, `message.webinar` est une
# requête, `with_lock` ayant vidé le cache d'association).
class MessageBroadcast
  TOPIC = "chat"
  RPC_TIMEOUT_SECONDS = 3

  def initialize(client: nil, timeout: RPC_TIMEOUT_SECONDS)
    @client = client
    @timeout = timeout
  end

  # @return [Symbol] :sent | :unavailable
  def deliver(message)
    room = message.webinar.room_name
    data = { topic: TOPIC, message: message.public_attributes }.to_json
    Timeout.timeout(@timeout, RoomServiceClient::Error, "diffusion LiveKit trop lente") do
      client.send_data(room: room, data: data, kind: :reliable)
    end
    :sent
  rescue RoomServiceClient::Error => error
    Rails.logger.warn("[message_broadcast] webinar=#{message.webinar_id} message=#{message.id} #{error.class}: #{error.message}")
    :unavailable
  end

  private

  def client
    @client ||= Rails.configuration.x.room_service_client_factory.call
  end
end
