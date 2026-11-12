require "test_helper"

# File du relais WhatsApp — GET /internal/registration_messages/pending,
# POST /internal/registration_messages/:id/relayed.
class Internal::RegistrationMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @saved_token = ENV["REGISTRATION_RELAY_TOKEN"]
    ENV["REGISTRATION_RELAY_TOKEN"] = "relais-test"
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.zone.local(2026, 11, 20, 18, 30), host_sub: "h",
                               visibility: "published")
    @message_request = team_request("camille@example.test", created_at: 2.days.ago)
    Registration.find_or_create_for(@webinar, email: @message_request.email, name: @message_request.name, registration_request: @message_request)
  end

  teardown { ENV["REGISTRATION_RELAY_TOKEN"] = @saved_token }

  test "fermée sans REGISTRATION_RELAY_TOKEN, ou avec une valeur vide : 404 sur les deux routes" do
    [ nil, "" ].each do |value|
      ENV["REGISTRATION_RELAY_TOKEN"] = value
      get internal_pending_registration_messages_path, headers: auth("")
      assert_response :not_found, value.inspect
      post internal_relayed_registration_message_path(@message_request), headers: auth("")
      assert_response :not_found, value.inspect
    end
    assert_nil @message_request.reload.whatsapp_relayed_at
  end

  test "seul `Authorization: Bearer <jeton>` est accepté ; refus sans corps ni effet" do
    [ nil, "relais-test", "Token relais-test", "Bearer autre", "Bearer  relais-test" ].each do |value|
      headers = value ? { "Authorization" => value } : {}
      get internal_pending_registration_messages_path, headers: headers
      assert_response :unauthorized, value.inspect
      assert_empty response.body
      post internal_relayed_registration_message_path(@message_request), headers: headers
      assert_response :unauthorized, value.inspect
    end
    assert_nil @message_request.reload.whatsapp_relayed_at
  end

  test "le jeton de la supervision n'ouvre pas la file" do
    saved = ENV["CRM_STATUS_TOKEN"]
    ENV["CRM_STATUS_TOKEN"] = "sonde-test"
    get internal_pending_registration_messages_path, headers: auth("sonde-test")
    assert_response :unauthorized
  ensure
    ENV["CRM_STATUS_TOKEN"] = saved
  end

  test "pending : forme exacte d'un message, sans cache" do
    get internal_pending_registration_messages_path, headers: auth("relais-test")
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal({ "registration_messages" => [ {
      "id" => @message_request.id, "name" => "Camille", "email" => "camille@example.test", "profile" => "dev",
      "webinars" => [ { "slug" => @webinar.slug, "title" => "Café IA #9", "starts_at" => "2026-11-20T18:30:00+01:00" } ],
      "notify_next" => true, "message" => "Je propose une présentation pour le Café IA #9.",
      "created_at" => @message_request.created_at.iso8601, "confirmed_at" => @message_request.confirmed_at.iso8601
    } ] }, response.parsed_body)
  end

  test "pending : toutes les confirmées, avec ou sans message ; ni non confirmée, ni autre source, ni déjà relayée ; plus anciennes d'abord, 20 au plus" do
    team_request("unconfirmed@example.test", confirmed_at: nil)
    team_request("other@example.test", source: nil)
    team_request("relayed@example.test", whatsapp_relayed_at: 1.hour.ago)
    silent = team_request("silent@example.test", message: nil, created_at: 1.day.ago)
    oldest = team_request("oldest@example.test", created_at: 3.days.ago)

    get internal_pending_registration_messages_path, headers: auth("relais-test")
    entries = response.parsed_body["registration_messages"]
    assert_equal [ oldest.id, @message_request.id, silent.id ], entries.pluck("id")
    assert_nil entries.last["message"], "sans message : clé présente, valeur nulle"

    20.times { |index| team_request("bulk#{index}@example.test") }
    get internal_pending_registration_messages_path, headers: auth("relais-test")
    assert_equal 20, response.parsed_body["registration_messages"].size
  end

  test "relayed : sort de la file ; rejoué, 200 et même date" do
    post internal_relayed_registration_message_path(@message_request), headers: auth("relais-test")
    assert_response :ok
    first = response.parsed_body
    assert_equal @message_request.id, first["id"]
    assert_equal @message_request.reload.whatsapp_relayed_at.iso8601, first["whatsapp_relayed_at"]

    travel 1.minute do
      post internal_relayed_registration_message_path(@message_request), headers: auth("relais-test")
    end
    assert_response :ok
    assert_equal first, response.parsed_body

    get internal_pending_registration_messages_path, headers: auth("relais-test")
    assert_empty response.parsed_body["registration_messages"]
  end

  test "relayed : une inscription sans message s'acquitte comme les autres" do
    silent = team_request("silent@example.test", message: nil)
    post internal_relayed_registration_message_path(silent), headers: auth("relais-test")
    assert_response :ok
    assert_not_nil silent.reload.whatsapp_relayed_at
  end

  test "relayed : demande inconnue ou hors de la file → 404, rien de posé" do
    unconfirmed = team_request("unconfirmed@example.test", confirmed_at: nil)
    post internal_relayed_registration_message_path(unconfirmed), headers: auth("relais-test")
    assert_response :not_found
    assert_nil unconfirmed.reload.whatsapp_relayed_at

    post internal_relayed_registration_message_path(id: RegistrationRequest.maximum(:id) + 1), headers: auth("relais-test")
    assert_response :not_found
  end

  private

  def auth(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def team_request(email, **attributes)
    RegistrationRequest.create!({ name: "Camille", email: email, source: "tartiflette.dev", profile: "dev",
                                  notify_next: true, message: "Je propose une présentation pour le Café IA #9.",
                                  confirmed_at: Time.current.change(usec: 0) }.merge(attributes))
  end
end
