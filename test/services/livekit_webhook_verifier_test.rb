# frozen_string_literal: true

require "test_helper"

# Le corps BRUT est authentifié (JWT HS256 + iss + exp + sha256)
# avant tout décodage du format LiveKit.
class LivekitWebhookVerifierTest < ActiveSupport::TestCase
  include LivekitWebhookSigning

  setup do
    @verifier = LivekitWebhookVerifier.new(api_key: WEBHOOK_KEY, api_secret: WEBHOOK_SECRET)
    @body = webhook_body(event: "track_published", room: "r1", identity: "host-sub", track_sid: "TR_a", source: :CAMERA)
  end

  test "signature valide → hash simple aux noms de champs proto" do
    event = @verifier.verify(body: @body, authorization: signed_authorization(@body))

    assert_equal "track_published", event["event"]
    assert_equal "r1", event.dig("room", "name")
    assert_equal "host-sub", event.dig("participant", "identity")
    assert_equal "CAMERA", event.dig("track", "source")
  end

  test "corps modifié après signature → Unauthorized" do
    authorization = signed_authorization(@body)
    tampered = @body.sub("host-sub", "host-evil")

    assert_raises(LivekitWebhookVerifier::Unauthorized) do
      @verifier.verify(body: tampered, authorization: authorization)
    end
  end

  test "mauvais secret, mauvais émetteur, jeton expiré ou absent → Unauthorized" do
    [
      signed_authorization(@body, secret: "x" * 40),
      signed_authorization(@body, key: "APIother"),
      signed_authorization(@body, exp: 1.minute.ago),
      nil,
      "Bearer not-a-jwt"
    ].each do |authorization|
      assert_raises(LivekitWebhookVerifier::Unauthorized) do
        @verifier.verify(body: @body, authorization: authorization)
      end
    end
  end

  test "sha256 absent des claims → Unauthorized" do
    token = JWT.encode({ iss: WEBHOOK_KEY, exp: 5.minutes.from_now.to_i }, WEBHOOK_SECRET, "HS256")

    assert_raises(LivekitWebhookVerifier::Unauthorized) do
      @verifier.verify(body: @body, authorization: "Bearer #{token}")
    end
  end

  test "corps signé mais illisible → InvalidPayload" do
    body = "{not json"

    assert_raises(LivekitWebhookVerifier::InvalidPayload) do
      @verifier.verify(body: body, authorization: signed_authorization(body))
    end
  end

  test "clés absentes → MissingCredentials" do
    verifier = LivekitWebhookVerifier.new(api_key: "", api_secret: nil)

    assert_raises(LivekitWebhookVerifier::MissingCredentials) do
      verifier.verify(body: @body, authorization: signed_authorization(@body))
    end
  end
end
