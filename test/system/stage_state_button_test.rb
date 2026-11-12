require "application_system_test_case"

# Browser coverage of host controls (régie), owner-only warnings and viewer isolation.
class StageStateButtonTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(
      title: "Kick-off Q4",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub
    )
    @prev_key    = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    @prev_url    = ENV["LIVEKIT_URL"]
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
    ENV["LIVEKIT_URL"]        = @prev_url
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  # La scène ne porte plus le bouton d'état ; la régie, si.
  test "host draft : scène sans bouton d'état, régie avec « Démarrer le direct »" do
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)

    assert_no_selector "#livekit-room[data-state]",       visible: :all
    assert_no_selector "#livekit-room[data-go-live-url]", visible: :all
    assert_selector "#livekit-room[data-regie-url]",      visible: :all

    # React monte (pas de crash hooks — sinon container reste au noscript).
    assert_no_selector "#livekit-room:empty"
    # Le PreJoin est monté (host = canPublish), pas le viewer layout.
    assert_selector "[data-testid='prejoin']", wait: 5

    visit webinar_regie_path(@webinar)
    assert_selector "#regie[data-state='draft'][data-go-live-url][data-end-url]", visible: :all
    assert_selector "[data-testid='state-button'][data-state='draft']", exact_text: "Démarrer le direct", wait: 10
  end

  # L'avertissement de révocation à la fin du direct est couvert côté serveur
  # (hand_raises_controller_test « end failure is visible to the host… »).
  # Son affichage dans le StateButton exige une salle LiveKit connectée,
  # injoignable depuis la CI : vérification manuelle sur staging.

  # critère 'state_button_host_only' — viewer ne voit ni bouton ni
  # data-attrs host. Un attribut forgé n'obtiendrait rien (les endpoints
  # restent host-only via authenticate_animateur!) — la garde de RENDU
  # est un signal UX ET une propriété testable, pas une sécurité.
  test "viewer public ne voit ni le bouton d'état ni les data-attrs host" do
    # Contrat : sur /w/:slug, la salle
    # (#livekit-room) n'est rendue QUE si state=live ; hors live → pre_live
    # sans bundle LiveKit. Pour asserter « pas de data-attrs host côté
    # spectateur DANS LA SALLE », on force donc state=live — sinon le test
    # passerait pour la mauvaise raison (aucun conteneur salle rendu).
    live = Webinar.create!(
      title: "démo live",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published"
    )
    live.update!(state: "live", started_at: Time.current)

    confirm_viewer_registration(live)
    visit public_webinar_path(slug: live.slug)

    # Le container est rendu (data-slug présent, cf. join_room_test.rb)
    # mais SANS les data-attrs host.
    assert_selector "#livekit-room[data-slug]", visible: :all
    assert_no_selector "#livekit-room[data-go-live-url]", visible: :all
    assert_no_selector "#livekit-room[data-end-url]",     visible: :all
    assert_no_selector "#livekit-room[data-state]",       visible: :all

    # Aucun bouton d'état côté viewer, même après montage React.
    Capybara.using_wait_time(5) do
      assert_no_selector "[data-testid='state-button']"
    end
  end

  private

  # Miroir de RoomReactRenderTest#sign_in_as — flow OIDC test_mode.
  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: { email: user.email }
    )
    visit "/auth/pocket_id/callback"
  end
end
