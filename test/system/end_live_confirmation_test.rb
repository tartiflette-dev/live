require "application_system_test_case"

# Audit UX : « Terminer le direct » partait au premier clic.
# Or `Webinar#end!` arrête tous les enregistrements et ferme le direct pour
# tous (la reprise, relance de NOUVEAUX fichiers). Un
# clic d'inattention pendant le Café IA fermait la salle pour tous.
#
# Désormais : premier clic → bouton armé « Confirmer la fin du direct ? »
# + « Annuler », pendant 5 s ; second clic → fin du direct. Échap,
# « Annuler », un clic ailleurs ou le délai désarment, sans rien envoyer ;
# un double-clic arme sans terminer (garde de 500 ms après l'armement).
# L'état est relu EN BASE : un clic seul ne doit jamais terminer.
#
# Le bouton d'état vit dans la régie (la salle de
# l'animation est celle des participants) : même composant, même garde.
class EndLiveConfirmationTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(title: "Café IA #7", starts_at: 1.day.from_now, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
  end

  teardown do
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @saved_env[k] }
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "un clic arme sans terminer ; le second clic termine le direct" do
    open_regie
    click_on "Terminer le direct"

    assert_selector "[data-testid='state-button'][data-armed='true']", text: "Confirmer la fin du direct ?"
    assert_selector "[data-testid='state-button-cancel']", text: "Annuler"
    assert_equal "live", @webinar.reload.state, "un seul clic a terminé le direct"

    sleep 0.6 # au-delà de la garde anti double-clic (500 ms), comme un humain qui lit
    # Insécable avant « ? » : à 360 px le point d'interrogation ne part plus
    # seul sur une troisième ligne (Capybara normalise `text:`, pas click_on).
    click_on "Confirmer la fin du direct\u00a0?"
    assert_selector "[data-testid='state-button'][data-state='ended']", text: "Reprendre le direct", wait: 10
    assert_equal "ended", @webinar.reload.state
  end

  test "un double-clic arme sans terminer le direct" do
    open_regie
    find("[data-testid='state-button']").double_click

    assert_selector "[data-testid='state-button'][data-armed='true']", text: "Confirmer la fin du direct ?"
    sleep 1 # au-delà de la garde de 500 ms : aucun POST différé
    assert_equal "live", @webinar.reload.state, "un double-clic a terminé le direct"
    assert_selector "[data-testid='state-button'][data-armed='true']"
  end

  test "le bouton se désarme seul après 5 secondes" do
    open_regie
    click_on "Terminer le direct"
    assert_selector "[data-testid='state-button'][data-armed='true']"

    assert_selector "[data-testid='state-button'][data-armed='false']", text: "Terminer le direct", wait: 8
    assert_no_selector "[data-testid='state-button-cancel']"
    assert_equal "live", @webinar.reload.state
  end

  test "Échap, Annuler ou un clic ailleurs désarment sans terminer" do
    open_regie

    click_on "Terminer le direct"
    find("[data-testid='state-button']").send_keys(:escape)
    assert_selector "[data-testid='state-button'][data-armed='false']", text: "Terminer le direct"

    click_on "Terminer le direct"
    click_on "Annuler"
    assert_selector "[data-testid='state-button'][data-armed='false']", text: "Terminer le direct"

    click_on "Terminer le direct"
    find("[data-testid='regie-present']").click
    assert_selector "[data-testid='state-button'][data-armed='false']", text: "Terminer le direct"

    assert_equal "live", @webinar.reload.state
  end

  test "Démarrer le direct reste à un clic" do
    @webinar.update!(state: "draft", started_at: nil)
    open_regie
    click_on "Démarrer le direct"

    assert_selector "[data-testid='state-button'][data-state='live']", text: "Terminer le direct", wait: 10
    assert_equal "live", @webinar.reload.state
  end

  private

  def open_regie
    Capybara.current_session.current_window.resize_to(1400, 900)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: @host.oidc_sub, info: { email: @host.email }
    )
    visit "/auth/pocket_id/callback"
    visit webinar_regie_path(@webinar)
    assert_selector "[data-testid='state-button']", wait: 10
  end
end
