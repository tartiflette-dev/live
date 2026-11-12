require "application_system_test_case"

# Constat en direct : un partage d'écran peut montrer la barre
# d'adresse de l'intervenant, donc son lien /join?t=…. « Partager l'écran »
# demande à Chrome de présélectionner un onglet, qui ne montre ni barre
# d'adresse ni onglets. Pas de serveur LiveKit (livekit.invalid) : la
# publication est accordée au participant local une fois la connexion
# échouée, et le sélecteur du navigateur est remplacé par un espion qui
# relève les contraintes puis répond comme un sélecteur fermé.
class ScreenShareCaptureTest < JsSystemTestCase
  include LivekitRoomRecipe

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  DISPLAY_MEDIA_SPY_JS = <<~JS.freeze
    window.displayMediaConstraints = [];
    navigator.mediaDevices.getDisplayMedia = (constraints) => {
      window.displayMediaConstraints.push(constraints);
      return Promise.reject(new DOMException("Sélecteur fermé", "NotAllowedError"));
    };
  JS

  setup do
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    webinar = Webinar.create!(title: "Café IA #7", starts_at: 1.day.from_now, host_sub: "sub-marc",
                              visibility: "published", state: "live", started_at: Time.current)
    @speaker = webinar.speakers.create!(name: "Basile")
    # Accord à l'image déjà donné (participant_consent_test couvre la fenêtre).
    ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)
  end

  teardown do
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |key| ENV[key] = @saved_env[key] }
  end

  test "Partager l'écran présélectionne un onglet, sans retirer l'onglet courant ni le son" do
    visit join_webinar_path(slug: @speaker.webinar.slug, t: @speaker.token)
    find("[data-testid='prejoin'] .lk-join-button:not([disabled])", wait: 10).click
    grant_local_publish
    execute_script(DISPLAY_MEDIA_SPY_JS)

    within("[data-testid='room-controls']") { click_on "Partager l'écran", wait: 10 }

    constraints = wait_until { evaluate_script("window.displayMediaConstraints[0] || null") }
    assert_equal "browser", constraints.dig("video", "displaySurface")
    assert_equal "include", constraints["selfBrowserSurface"]
    assert_equal true, constraints["audio"]
  end

  private

  def grant_local_publish
    assert_equal "ok", wait_until { evaluate_script(GRANT_LOCAL_PUBLISH_JS) }
  end

  def wait_until(timeout: 10)
    deadline = Time.current + timeout
    loop do
      value = yield
      return value if value
      flunk "condition jamais remplie en #{timeout} s" if Time.current > deadline
      sleep 0.1
    end
  end
end
