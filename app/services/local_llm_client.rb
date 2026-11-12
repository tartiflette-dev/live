# frozen_string_literal: true

require "net/http"
require "json"
require "timeout"
require "uri"

# Adaptateur vers un LLM LOCAL à API compatible OpenAI (llama-swap,
# llama.cpp, Ollama…). Utilisé par la file Q&R (QaExtractionJob) et la
# proposition de chapitres des replays (ChapterProposalJob). Le client
# n'envoie aucune clé : l'endpoint reste sur le réseau privé de l'instance,
# jamais exposé publiquement.
#
# Contraintes : le modèle est déjà chargé par le serveur, qui garde la main
# sur ses modèles résidents. Aucun réglage de chargement n'est donc envoyé
# (jamais de `ttl`) : seulement le modèle, les messages, une température
# basse et `response_format: json_object`.
#
# Désactivé par défaut : `from_env` rend nil tant que QA_LLM_ENABLED n'est pas
# "true" ou que QA_LLM_URL manque (aucun hôte par défaut : l'adresse vient du
# déploiement) ; l'appelant passe alors en repli. Délai TOTAL borné (connexion,
# envoi et lecture compris) : une file Q&R en retard vaut mieux qu'un worker
# Solid Queue immobilisé. Les chapitres, qui envoient un passage de
# transcription entier, demandent un délai et une réponse plus longs
# (second argument de `from_env`, `max_tokens:`).
#
# Toute panne lève LocalLlmClient::Error — délai dépassé : sa sous-classe
# Timeout ; réseau, protocole HTTP, réponse non 2xx, JSON illisible, contenu
# absent ou non objet : Error. Rien d'autre ne sort, l'appelant peut compter
# sur son repli. Les journaux et messages d'erreur ne portent jamais le texte
# envoyé ni reçu (données personnelles du chat).
class LocalLlmClient
  class Error < StandardError; end
  class Timeout < Error; end

  NETWORK_ERRORS = [ SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError,
                     Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error ].freeze
  TIMEOUT_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, ::Timeout::Error ].freeze

  DEFAULT_MODEL = "glm-4-9b"
  TIMEOUT_SECONDS = 15
  OPEN_TIMEOUT_SECONDS = 3
  MAX_TOKENS = 300

  attr_reader :model

  def self.from_env(env = ENV, timeout = TIMEOUT_SECONDS)
    return unless env["QA_LLM_ENABLED"] == "true" && env["QA_LLM_URL"].present?

    new(base_url: env["QA_LLM_URL"], model: env["QA_LLM_MODEL"].presence || DEFAULT_MODEL, timeout: timeout)
  end

  # Pourquoi `from_env` n'a rendu aucun client, pour le journal de la file :
  # coupée (QA_LLM_ENABLED ≠ "true") ou activée sans QA_LLM_URL. Ne se lit
  # qu'après un `from_env` nil.
  def self.unavailable_reason(env = ENV)
    env["QA_LLM_ENABLED"] == "true" ? "llm_unconfigured" : "llm_disabled"
  end

  def initialize(base_url:, model:, timeout: TIMEOUT_SECONDS)
    @endpoint = URI.join("#{base_url.chomp("/")}/", "chat/completions")
    @model = model
    @timeout = timeout
  end

  # @param messages [Array<Hash>] messages au format OpenAI ({ role:, content: })
  # @param max_tokens [Integer] longueur maximale de la réponse
  # @return [Hash] l'objet JSON produit par le modèle
  def complete_json(messages, max_tokens: MAX_TOKENS)
    payload = { model: @model, messages: messages, temperature: 0, max_tokens: max_tokens,
                response_format: { type: "json_object" } }
    content = JSON.parse(post(payload)).dig("choices", 0, "message", "content")
    raise Error, "réponse sans contenu" unless content.is_a?(String)

    parsed = JSON.parse(unfenced(content))
    raise Error, "contenu JSON non objet" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise Error, "JSON illisible"
  end

  private

  # glm-4-9b derrière llama-swap n'applique pas `response_format` : il
  # enveloppe l'objet dans un bloc ```json (essai réel). Seule
  # cette enveloppe est retirée ; le reste doit être du JSON pur.
  def unfenced(content)
    content.strip.delete_prefix("```json").delete_prefix("```").delete_suffix("```").strip
  end

  def post(payload)
    request = Net::HTTP::Post.new(@endpoint, "Content-Type" => "application/json", "Accept" => "application/json")
    request.body = payload.to_json
    response = ::Timeout.timeout(@timeout, Timeout, "délai total dépassé") do
      Net::HTTP.start(@endpoint.host, @endpoint.port, use_ssl: @endpoint.scheme == "https",
                      open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: @timeout, write_timeout: @timeout) do |http|
        http.request(request)
      end
    end
    raise Error, "HTTP #{response.code}" unless response.code.to_s.start_with?("2")

    response.body.to_s
  rescue *TIMEOUT_ERRORS => error
    raise Timeout, error.class.name
  rescue *NETWORK_ERRORS => error
    raise Error, error.class.name
  end
end
