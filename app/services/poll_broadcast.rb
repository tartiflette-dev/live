require "timeout"

# Diffusion temps réel des sondages du direct. Même
# mécanique que MessageBroadcast : le SERVEUR publie sur le data channel
# LiveKit (fiable) l'état à l'écran de tous, et le client rejette tout paquet
# émis par un participant (poll_state.mjs).
#
#   { topic: "poll", at: <horodatage serveur µs>, poll: <Poll public | null> }
#
# Chaque paquet porte l'état COMPLET (sondage à l'écran, compteur, résultat
# s'il est montré) : rejouable, et `at` permet au client d'écarter un
# paquet plus ancien que ce qu'il sait déjà (poll HTTP de repli, 5 s).
# `at` est relevé AVANT la lecture de l'état : un état lu après un
# changement porte toujours un `at` postérieur à ce changement.
#
# Changement d'état (ouverture, fermeture, résultat) : diffusé aussitôt.
# Nouvelle réponse : `schedule_tally` regroupe les réponses par seconde
# d'horloge — la première d'une seconde programme UNE diffusion à la fin de
# cette seconde (PollTallyJob), qui porte toutes les réponses arrivées
# entre-temps ; au plus une diffusion de compteur par seconde, quel que soit
# le nombre de workers Puma (compteur fichier partagé).
#
# La persistance fait foi : un échec de diffusion est journalisé et rendu
# (`:unavailable`), jamais levé.
class PollBroadcast
  TOPIC = "poll"
  RPC_TIMEOUT_SECONDS = 3
  # Compteur fichier partagé par les workers (même mécanique que les
  # limites de débit), dans son propre répertoire et sous son propre verrou.
  # Remplaçable par les tests (répertoire jetable : les ids de webinaire se
  # réutilisent d'une base de test à l'autre).
  class << self
    attr_writer :tally_counter

    def tally_counter
      @tally_counter ||= RegistrationRateLimitStore.new(name: "poll_tally")
    end
  end

  def self.schedule_tally(webinar, store: tally_counter, now: Time.current)
    second = now.to_i
    first_of_second = store.increment("poll-tally:#{webinar.id}:#{second}", 1, expires_in: 5.seconds) == 1
    PollTallyJob.set(wait_until: Time.zone.at(second + 1)).perform_later(webinar) if first_of_second
  end

  # Enveloppe commune à la diffusion et au poll HTTP (PollParticipationsController).
  def self.snapshot(webinar)
    at = Time.current.utc.iso8601(6)
    poll = Poll.current_for(webinar)
    { at: at, poll: poll&.public_attributes }
  end

  def initialize(client: nil, timeout: RPC_TIMEOUT_SECONDS)
    @client = client
    @timeout = timeout
  end

  # @return [Symbol] :sent | :unavailable
  def deliver(webinar)
    data = { topic: TOPIC }.merge(self.class.snapshot(webinar)).to_json
    Timeout.timeout(@timeout, RoomServiceClient::Error, "diffusion LiveKit trop lente") do
      client.send_data(room: webinar.room_name, data: data, kind: :reliable)
    end
    :sent
  rescue RoomServiceClient::Error => error
    Rails.logger.warn("[poll_broadcast] webinar=#{webinar.id} #{error.class}: #{error.message}")
    :unavailable
  end

  private

  def client
    @client ||= Rails.configuration.x.room_service_client_factory.call
  end
end
