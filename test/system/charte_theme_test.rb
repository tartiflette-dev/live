require "application_system_test_case"
# Thème undust seulement : la gem undust-charte fournit le contrat testé ;
# sous un autre thème, les tests sont sautés (comptés), pas retirés.
require "undust/charte/testing/theme_contract" if Theme.undust?

# Thème undust : la palette se vérifie APRÈS la
# cascade, dans un vrai navigateur, sur les deux thèmes, avec persistance.
# Contrat livré par la gem (Undust::Charte::Testing::ThemeContract), complété
# par les surfaces propres à Live : carte de connexion, chrome des
# pages animateur, salle (sombre en mode clair comme en mode sombre),
# fonte Aspekta réellement chargée.
class CharteThemeTest < JsSystemTestCase
  setup { require_undust_theme! }
  include Undust::Charte::Testing::ThemeContract if Theme.undust?

  # Page de connexion (layout force, sans chrome de session) : elle nomme
  # sa structure — canvas de page et carte de contenu (contrat 3.0.0).
  CONNEXION = { canvas: ".connexion-canvas", window: ".connexion-carte" }.freeze

  # Clés LiveKit factices : la salle appelle POST /api/token au montage
  # (fail-loud MissingCredentials sinon). Même recette que
  # RoomReactRenderTest ; aucune connexion WebRTC réelle n'est attendue.
  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    # Live requis pour body.room : bascule /w/:slug sur la
    # page avant-direct (layout `:application`) hors live.
    @webinar = Webinar.create!(
      title: "Café IA",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published",
      state: "live",
      started_at: Time.current
    )
    @prev_env = ENV.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = "APIcharte"
    ENV["LIVEKIT_API_SECRET"] = "charte-secret-32-bytes-long-enough-x"
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
  end

  teardown do
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @prev_env[k] }
  end

  test "la fonte de l'interface est livrée par l'app (Aspekta chargée)" do
    visit sign_in_path
    result = page.driver.browser.execute_async_script(<<~JS)
      const done = arguments[0];
      const style = getComputedStyle(document.body);
      const font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
      document.fonts.load(font, 'Undust').then(faces => {
        done({ family: style.fontFamily, loaded: faces.some(face => face.family.replaceAll('"', '') === 'Aspekta' && face.status === 'loaded') });
      }).catch(() => done({ family: style.fontFamily, loaded: false }));
    JS
    assert_match(/\A["']?Aspekta/, result.fetch("family"))
    assert result.fetch("loaded"), "Aspekta doit être une fonte web chargée"
  end

  test "un nouveau visiteur suit le thème système et le premier clic le change" do
    visit sign_in_path
    page.execute_script("document.cookie = 'theme=; Max-Age=0; path=/'; localStorage.removeItem('u-theme')")
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ])
    page.refresh
    assert_undust_theme("light", **CONNEXION)
    find("[data-theme-toggle]").click
    assert_selector "html[data-theme=dark]"
    assert_undust_theme("dark", **CONNEXION)
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end

  test "la carte de connexion suit les deux palettes et persiste le choix" do
    visit sign_in_path
    page.execute_script("document.cookie = 'theme=light; path=/'; localStorage.setItem('u-theme', 'light')")
    page.refresh
    assert_undust_theme("light", **CONNEXION)
    assert_connexion_cta
    find("[data-theme-toggle]").click
    assert_selector "html[data-theme=dark]"
    assert_undust_theme("dark", **CONNEXION)
    assert_connexion_cta
    page.refresh
    assert_undust_theme("dark", **CONNEXION)
  end

  test "le chrome animateur suit les deux palettes (canvas + fenêtre)" do
    sign_in_via_browser(@host)
    visit webinars_path
    page.execute_script("document.cookie = 'theme=light; path=/'; localStorage.setItem('u-theme', 'light')")
    page.refresh
    assert_undust_theme("light", canvas: ".chrome-canvas", window: ".chrome-fenetre")
    find("[data-theme-toggle]").click
    assert_selector "html[data-theme=dark]"
    assert_undust_theme("dark", canvas: ".chrome-canvas", window: ".chrome-fenetre")
  end

  test "la salle reste sur encre profonde (gray-925) dans les deux thèmes" do
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    %w[light dark].each do |theme|
      page.execute_script("document.cookie = 'theme=#{theme}; path=/'; localStorage.setItem('u-theme', '#{theme}')")
      page.refresh
      assert_selector "html[data-theme=#{theme}]"
      assert_equal "rgb(15, 16, 23)", find("body.room").evaluate_script("getComputedStyle(this).backgroundColor"),
        "body.room doit rester var(--gray-925) en #{theme}"
    end
  end

  test "viewport 411 css pixels does not overflow" do
    page.current_window.resize_to(411, 869)
    visit sign_in_path
    overflow = page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth")
    assert_operator overflow, :<=, 1
  ensure
    # Le navigateur est partagé par les tests du même processus : sans
    # retour au format par défaut, le test suivant tourne en 411 px
    # (RoomPageStyleTest a échoué ainsi).
    page.current_window.resize_to(1400, 900)
  end

  test "une feuille périmée chargée en dernier ne passe pas le contrat" do
    visit sign_in_path
    page.execute_script("document.documentElement.dataset.theme = 'dark'; document.documentElement.classList.add('dark')")
    # Par le CSSOM (insertRule dans une feuille existante), pas par un
    # <style> posé par script : la CSP bloquante (style-src sans
    # 'unsafe-inline') refuse l'élément entier — sa propriété `sheet` reste
    # null. La feuille périmée simulée doit passer par un chemin que la CSP
    # n'interdit pas, en fin de cascade pour garder le sens du test.
    page.execute_script(<<~JS)
      const sheet = document.styleSheets[document.styleSheets.length - 1];
      sheet.insertRule('html[data-theme="dark"] { --surface: #1C1E2A; }', sheet.cssRules.length);
    JS
    assert_raises(Minitest::Assertion) { assert_undust_theme("dark", **CONNEXION) }
  end

  private

  # CTA de connexion : UN seul, aplat accent, hauteur tactile, sans arrondi.
  def assert_connexion_cta
    assert_selector ".connexion-carte .connexion-cta", count: 1
    button = find(".connexion-carte .connexion-cta")
    assert_operator button.evaluate_script("this.getBoundingClientRect().height"), :>=, 44
    assert_equal "0px", button.evaluate_script("getComputedStyle(this).borderRadius")
    refute_equal button.evaluate_script("getComputedStyle(this).color"), button.evaluate_script("getComputedStyle(this).backgroundColor")
  end

  def sign_in_via_browser(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub, info: { email: user.email }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    visit "/auth/pocket_id/callback"
    assert_current_path webinars_path
  ensure
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end
end
