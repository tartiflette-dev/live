require "test_helper"

# Annonces au groupe WhatsApp de la communauté Tartiflette —
# GET /internal/registration_messages/announcements/pending,
# POST /internal/registration_messages/announcements/:id/announced.
class Internal::CommunityAnnouncementsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @saved_token = ENV["REGISTRATION_RELAY_TOKEN"]
    ENV["REGISTRATION_RELAY_TOKEN"] = "relais-test"
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.zone.local(2026, 11, 10, 9, 30), host_sub: "h",
                               visibility: "published")
    @signup = signup("pierre@example.test", name: "Pierre Martin", confirmed_at: 2.hours.ago.change(usec: 0))
  end

  teardown { ENV["REGISTRATION_RELAY_TOKEN"] = @saved_token }

  test "fermée sans REGISTRATION_RELAY_TOKEN, ou avec une valeur vide : 404 sur les deux routes" do
    [ nil, "" ].each do |value|
      ENV["REGISTRATION_RELAY_TOKEN"] = value
      get internal_pending_community_announcements_path, headers: auth("")
      assert_response :not_found, value.inspect
      post internal_announced_community_announcement_path(@signup), headers: auth("")
      assert_response :not_found, value.inspect
    end
    assert_nil @signup.reload.community_announced_at
  end

  test "jeton absent, nu ou faux : 401 sans corps ni effet" do
    [ nil, "relais-test", "Bearer autre" ].each do |value|
      headers = value ? { "Authorization" => value } : {}
      get internal_pending_community_announcements_path, headers: headers
      assert_response :unauthorized, value.inspect
      assert_empty response.body
      post internal_announced_community_announcement_path(@signup), headers: headers
      assert_response :unauthorized, value.inspect
    end
    assert_nil @signup.reload.community_announced_at
  end

  test "pending : prénom et cafés SEULEMENT — ni email, ni nom complet, ni profil, ni message" do
    get internal_pending_community_announcements_path, headers: auth("relais-test")
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal({ "announcements" => [ {
      "id" => @signup.id, "first_name" => "Pierre",
      "webinars" => [ { "slug" => @webinar.slug, "title" => "Café IA #9", "starts_at" => "2026-11-10T09:30:00+01:00" } ],
      "confirmed_at" => @signup.confirmed_at.iso8601
    } ] }, response.parsed_body)
    assert_no_match(/pierre@|Martin|présentation/, response.body)
  end

  test "pending : ni non confirmée, ni « préviens-moi » seul, ni test de bout en bout, ni prénom retenu, ni déjà annoncée ; ordre des confirmations, 20 au plus" do
    signup("attente@example.test", confirmed_at: nil)
    signup("autre@example.test", source: nil)
    signup("annoncee@example.test", community_announced_at: 1.hour.ago)
    signup("camille+cafe-test-1@example.test")
    signup("retenu@example.test", community_announcement_withheld_at: 1.hour.ago)
    RegistrationRequest.create!(name: "Lou", email: "lou@example.test", source: "tartiflette.dev", notify_next: true,
                                confirmed_at: 3.hours.ago)
    draft = Webinar.create!(title: "Brouillon", starts_at: 5.days.from_now, host_sub: "h", visibility: "draft")
    signup("brouillon@example.test", webinar: draft)
    first = signup("premiere@example.test", confirmed_at: 3.hours.ago)

    get internal_pending_community_announcements_path, headers: auth("relais-test")
    assert_equal [ first.id, @signup.id ], response.parsed_body["announcements"].pluck("id")

    20.times { |index| signup("bulk#{index}@example.test") }
    get internal_pending_community_announcements_path, headers: auth("relais-test")
    assert_equal 20, response.parsed_body["announcements"].size
  end

  test "announced : sort de la file ; rejoué, 200 et même date ; indépendant du groupe des co-organisateurs" do
    post internal_announced_community_announcement_path(@signup), headers: auth("relais-test")
    assert_response :ok
    first = response.parsed_body
    assert_equal({ "id" => @signup.id, "community_announced_at" => @signup.reload.community_announced_at.iso8601 }, first)

    travel 1.minute do
      post internal_announced_community_announcement_path(@signup), headers: auth("relais-test")
    end
    assert_equal first, response.parsed_body

    get internal_pending_community_announcements_path, headers: auth("relais-test")
    assert_empty response.parsed_body["announcements"]
    assert_nil @signup.whatsapp_relayed_at
  end

  test "announced : hors de la file (test de bout en bout, prénom retenu, inconnue) → 404, rien de posé" do
    end_to_end = signup("camille+cafe-test-2@example.test")
    withheld = signup("retenu@example.test", community_announcement_withheld_at: 1.hour.ago)
    [ end_to_end, withheld ].each do |request|
      post internal_announced_community_announcement_path(request), headers: auth("relais-test")
      assert_response :not_found
      assert_nil request.reload.community_announced_at
    end

    post internal_announced_community_announcement_path(id: RegistrationRequest.maximum(:id) + 1), headers: auth("relais-test")
    assert_response :not_found
  end

  private

  def auth(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def signup(email, webinar: @webinar, name: "Camille", **attributes)
    request = RegistrationRequest.create!({ name: name, email: email, source: "tartiflette.dev", profile: "dev",
                                            message: "Je propose une présentation.",
                                            confirmed_at: 1.hour.ago.change(usec: 0) }.merge(attributes))
    Registration.find_or_create_for(webinar, email: email, name: name, registration_request: request)
    request
  end
end
