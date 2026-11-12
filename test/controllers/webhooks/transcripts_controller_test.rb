# frozen_string_literal: true

require "test_helper"

# Webhook de transcript — même recette de signature que le
# webhook LiveKit (JWT HS256 iss=api_key + sha256 corps). Invariants :
# - idempotent (duplicate segment_id → 204 no-op),
# - robuste (room inconnue → 204 no-op, payload mal formé → 400),
# - sans secret acceptée (signature invalide → 401, creds absentes → 503).
class Webhooks::TranscriptsControllerTest < ActionDispatch::IntegrationTest
  include LivekitWebhookSigning

  setup do
    @env_backup = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET")
    ENV["LIVEKIT_API_KEY"] = WEBHOOK_KEY
    ENV["LIVEKIT_API_SECRET"] = WEBHOOK_SECRET

    @webinar = Webinar.create!(title: "Café IA #2", starts_at: 1.hour.from_now, host_sub: "sub-marc")
    @speaker = @webinar.speakers.create!(name: "Pauline")
    @transcript_flag = ENV["TRANSCRIPT_ENABLED"]
    ENV["TRANSCRIPT_ENABLED"] = "true"
  end

  teardown do
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET].each { |k| ENV[k] = @env_backup[k] }
    ENV["TRANSCRIPT_ENABLED"] = @transcript_flag
  end

  def payload_for(webinar: @webinar, segment_id: SecureRandom.uuid, identity: "speaker-#{@speaker.id}", name: "Pauline",
                  text: "Bonjour.", started_at: Time.current - 2.seconds, ended_at: Time.current)
    {
      room: webinar.room_name,
      segment_id: segment_id,
      participant: { identity: identity, name: name },
      text: text,
      started_at: started_at.utc.iso8601(3),
      ended_at: ended_at.utc.iso8601(3)
    }.to_json
  end

  def deliver(body, authorization: signed_authorization(body))
    post "/webhooks/transcripts", params: body,
      headers: { "Content-Type" => "application/json", "Authorization" => authorization }
  end

  test "payload signé valide → segment créé, 204" do
    assert_difference -> { @webinar.transcript_segments.count }, 1 do
      deliver(payload_for)
    end
    assert_response :no_content
  end

  test "doublon (webinar_id, segment_id) → idempotent, 204 sans nouvelle ligne" do
    sid = SecureRandom.uuid
    deliver(payload_for(segment_id: sid))
    assert_response :no_content
    assert_no_difference -> { TranscriptSegment.count } do
      deliver(payload_for(segment_id: sid, text: "autre texte"))
    end
    assert_response :no_content
  end

  test "direct terminé : parole commencée avant la fin gardée, après la fin jamais archivée" do
    ended_at = 1.minute.ago
    @webinar.update!(state: "ended", started_at: 1.hour.ago, ended_at: ended_at)

    deliver(payload_for(text: "Avant.", started_at: ended_at - 3.seconds, ended_at: ended_at + 1.second))
    deliver(payload_for(text: "Après.", started_at: ended_at + 5.seconds, ended_at: ended_at + 8.seconds))

    assert_response :no_content
    assert_equal [ "Avant." ], @webinar.transcript_segments.pluck(:text)
  end

  test "direct repris : la parole de la reprise est archivée" do
    @webinar.update!(state: "ended", started_at: 1.hour.ago, ended_at: 2.minutes.ago)
    @webinar.resume!

    deliver(payload_for(text: "Reprise."))

    assert_equal [ "Reprise." ], @webinar.transcript_segments.pluck(:text)
  end

  test "room inconnue → no-op 204 (jamais 500)" do
    body = payload_for.sub(@webinar.room_name, "chambre-fantome")
    assert_no_difference -> { TranscriptSegment.count } do
      deliver(body)
    end
    assert_response :no_content
  end

  test "signature invalide → 401, aucun segment créé" do
    body = payload_for
    bad = signed_authorization(body, secret: "x" * 40)
    assert_no_difference -> { TranscriptSegment.count } do
      deliver(body, authorization: bad)
    end
    assert_response :unauthorized
  end

  test "sha256 falsifié → 401" do
    body = payload_for
    auth = signed_authorization(body, sha: Base64.strict_encode64("tampered"))
    deliver(body, authorization: auth)
    assert_response :unauthorized
  end

  test "credentials absentes → 503 service unavailable" do
    ENV["LIVEKIT_API_KEY"] = nil
    deliver(payload_for)
    assert_response :service_unavailable
  end

  test "JSON mal formé → 400 bad request" do
    deliver("{not json")
    assert_response :bad_request
  end

  test "payload sans segment_id → 400 bad request (champ obligatoire)" do
    body = payload_for
    parsed = JSON.parse(body); parsed.delete("segment_id")
    assert_no_difference -> { TranscriptSegment.count } do
      deliver(parsed.to_json)
    end
    assert_response :bad_request
  end

  test "payload avec segment_id vide → 204 no-op (invariant idempotence)" do
    body = payload_for
    parsed = JSON.parse(body); parsed["segment_id"] = ""
    assert_no_difference -> { TranscriptSegment.count } do
      deliver(parsed.to_json)
    end
    assert_response :no_content
  end

  test "payload > taille max → 413 content too large" do
    body = payload_for
    oversized = body.sub('"Bonjour."', '"' + ("a" * 200_000) + '"')
    deliver(oversized)
    assert_response :content_too_large
  end

  test "archive : animateur et spectateur inscrit confirmé acceptés ; révoqué, legacy, non confirmé et inconnu ignorés" do
    confirmed = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)
    pending = @webinar.registrations.create!(name: "Paul", email: "paul@example.test")
    revoked = @webinar.speakers.create!(name: "Parti")
    revoked.revoke!

    accepted = [ "host-sub-marc", "viewer-#{confirmed.id}" ]
    refused = [ "speaker-#{revoked.id}", "speaker-legacy-abc", "viewer-#{pending.id}", "host-sub-eve", "intrus" ]
    (accepted + refused).each { |identity| deliver(payload_for(identity: identity)) }

    assert_equal accepted.sort, @webinar.transcript_segments.pluck(:participant_identity).sort
  end

  test "drapeau TRANSCRIPT_ENABLED absent : l'agent est prévenu et rien n'est archivé" do
    get "/webhooks/transcripts/enabled"
    assert_equal({ "enabled" => true }, response.parsed_body)

    ENV["TRANSCRIPT_ENABLED"] = nil
    get "/webhooks/transcripts/enabled"
    assert_equal({ "enabled" => false }, response.parsed_body)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_no_difference -> { TranscriptSegment.count } do
      deliver(payload_for)
    end
    assert_response :no_content
  end
end
