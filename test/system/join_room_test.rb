require "application_system_test_case"

class JoinRoomTest < ApplicationSystemTestCase
  # Critère principal (system test Capybara) :
  # "La page spectateur /w/<slug> charge la salle et obtient un token
  # viewer via l'endpoint token" (viewer_joins_room).
  #
  # Driver = rack_test (pas de JS). On vérifie donc le CHARGEMENT HTML
  # (data-attrs prêts pour React) puis on APPELLE explicitement /api/token
  # depuis le test comme le ferait le composant React monté — c'est le
  # même contrat serveur. Un test avec navigateur headless viendra plus
  # tard (l'infra CI restera rack_test tant que la vidéo réelle n'est
  # pas testée).

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"
  FAKE_URL    = "wss://livekit.example.test"

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    # Live requis : `viewer` ne rend #livekit-room
    # qu'en state=live — hors live, page avant-direct sans montage LiveKit.
    @webinar = Webinar.create!(
      title: "Kick-off Q4",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published",
      state: "live",
      started_at: Time.current
    )
    @prev_key    = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    @prev_url    = ENV["LIVEKIT_URL"]
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = FAKE_URL
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
    ENV["LIVEKIT_URL"]        = @prev_url
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "viewer_joins_room" do
    # Étape 1 — la page HTML spectateur charge, expose le container React.
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "#livekit-room"
    assert_selector "#livekit-room[data-slug='#{@webinar.slug}']"

    # Étape 2 — l'endpoint token répond viewer (ce que le JS React demande
    # au montage). En rack_test on émule directement l'appel.
    page.driver.post(
      "/api/token",
      { slug: @webinar.slug }.to_json,
      { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json" }
    )
    assert_equal 200, page.driver.response.status
    payload = JSON.parse(page.driver.response.body)
    assert_equal "viewer", payload.fetch("role")
    assert payload.fetch("token").present?
    # L'URL du signal est celle de l'instance (LIVEKIT_URL), sans défaut caché.
    assert_equal FAKE_URL, payload.fetch("serverUrl")
  end
end
