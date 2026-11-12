require "application_system_test_case"

class RoomChromeIsolationTest < ApplicationSystemTestCase
  # Verrouille l'invariant :
  # les pages salle rendent body.room via le layout `room` (AUCUN chrome
  # animateur : ni .chrome-haut, ni .chrome-fenetre, ni bande basse) — leur
  # <main class="lk-page"> vient de la vue. Les pages animateur portent le
  # chrome du thème (body.chrome-canvas[data-chrome=v3]) ; la connexion le
  # layout force.

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    # Webinaire EN LIVE : `WebinarsController#viewer`
    # ne rend `:room` (avec layout `:room` = body.room) QUE si state=live —
    # sinon, page avant-direct sous layout `:application`. Les invariants
    # testés ici portent sur la coquille salle : on doit donc être en live.
    @webinar = Webinar.create!(
      title: "Kick-off Q4",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published",
      state: "live",
      started_at: Time.current
    )
  end

  test "la page spectateur échappe au chrome animateur (body.room, layout room)" do
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "body.room"
    assert_no_selector "body.chrome-canvas"
    assert_no_selector ".chrome-haut"
    assert_no_selector ".chrome-fenetre"
    assert_no_selector ".chrome-bas"
    assert_selector "main.lk-page #livekit-room"
    # Monogramme rendu par le thème (gem : undust_monogramme, atome accent).
    assert_selector "main.lk-page svg.lk-page__mono"
    assert_selector "main.lk-page svg.lk-page__mono .atome" if Theme.undust?
    assert_theme_color_de_la_gem
  end

  test "l'écran de connexion est hors-session (layout force, carte de connexion)" do
    visit sign_in_path
    assert_selector "body.connexion-body .connexion-carte button.connexion-cta"
    assert_no_selector "body.room"
    assert_no_selector ".chrome-haut"
  end

  test "la table animateur porte le chrome animateur (fenêtre + bande basse système)" do
    # Même recette que WebinarsControllerTest#sign_in_as : env omniauth.auth
    # posé puis GET du callback (rack_test ne suit pas les redirections
    # d'un driver.post).
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: @host.oidc_sub, info: { email: @host.email }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    visit "/auth/pocket_id/callback"
    visit webinars_path
    assert_selector "body.chrome-canvas[data-chrome='v3']"
    assert_selector ".chrome-haut .chrome-compte .chrome-mono"
    assert_selector "main.chrome-fenetre"
    assert_selector ".chrome-bas [data-theme-toggle]"
    # Chrome v3 rendu par la gem : glyphes SVG de la gem, aucun emoji.
    assert_selector ".chrome-haut a.chrome-retour svg.glyphe-accueil"
    assert_no_text "⌂"
    assert_selector ".chrome-bas .chrome-langue"
    assert_selector ".chrome-bas form button.chrome-deconnexion svg.glyphe"
    assert_selector ".chrome-bas nav a[aria-current='page']", text: I18n.t("chrome.webinars")
    assert_selector ".chrome-bas-droite a.chrome-geste svg.glyphe"
    assert_selector ".chrome-bas a.chrome-signature"
    assert_no_selector "body.room"
    assert_theme_color_de_la_gem
  ensure
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "à la racine (profondeur 0), le chrome n'offre pas de retour à l'accueil" do
    visit root_path
    assert_selector "body.chrome-canvas[data-chrome='v3']"
    assert_selector ".chrome-haut .chrome-compte svg.chrome-mono"
    assert_no_selector ".chrome-retour"
    assert_no_selector ".chrome-deconnexion"
    assert_theme_color_de_la_gem
  end

  # Le pendant POSITIF (« la salle reçoit bien SA coquille ») exige le
  # style CALCULÉ, donc un vrai navigateur : voir
  # test/system/room_page_style_test.rb (JsSystemTestCase).

  private

  def assert_theme_color_de_la_gem
    meta = find("meta[name='theme-color']", visible: false)
    assert_equal Theme.current.theme_color, meta[:content]
  end
end
