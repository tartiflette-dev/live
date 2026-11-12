require "jwt"
require "base64"
require "digest"
require "livekit/proto/livekit_webhook_pb"

# Authenticate raw bytes before decoding the vendor event format.
#
# La vérification JWT HS256 + sha256 du corps est partagée avec
# le webhook transcript (POST /webhooks/transcripts) via la méthode de
# classe `authenticate!`. On garde le décodage protobuf ici — seul le
# webhook LiveKit en a besoin.
class LivekitWebhookVerifier
  class Unauthorized < StandardError; end
  class InvalidPayload < StandardError; end
  class MissingCredentials < StandardError; end

  def initialize(api_key: ENV["LIVEKIT_API_KEY"], api_secret: ENV["LIVEKIT_API_SECRET"])
    @api_key = api_key
    @api_secret = api_secret
  end

  def verify(body:, authorization:)
    self.class.authenticate!(body: body, authorization: authorization,
                             api_key: @api_key, api_secret: @api_secret)

    event = LiveKit::Proto::WebhookEvent.decode_json(body, ignore_unknown_fields: true)
    JSON.parse(Google::Protobuf.encode_json(event, preserve_proto_fieldnames: true))
  rescue Google::Protobuf::ParseError
    raise InvalidPayload, "Invalid webhook payload", cause: nil
  end

  # Vérifie la signature partagée (JWT HS256 iss=api_key, claim sha256 =
  # base64(SHA-256(body))). Levée des erreurs typées — pas de retour :
  # un appelant qui ignorerait un rescue devrait laisser remonter.
  def self.authenticate!(body:, authorization:, api_key:, api_secret:)
    raise MissingCredentials if api_key.blank? || api_secret.blank?

    claims, = JWT.decode(authorization.to_s.delete_prefix("Bearer "), api_secret, true,
      algorithm: "HS256", leeway: 30, verify_iss: true, iss: api_key, required_claims: %w[iss exp sha256])
    digest = Base64.strict_encode64(Digest::SHA256.digest(body))
    unless claims["sha256"].is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(digest, claims["sha256"])
      raise Unauthorized
    end
    claims
  rescue JWT::DecodeError
    raise Unauthorized, "Invalid webhook signature", cause: nil
  end
end
