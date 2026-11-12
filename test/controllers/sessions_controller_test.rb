require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  # Auth animateur — OpenID Connect.

  setup do
    # OmniAuth test_mode : le provider :pocket_id reçoit son mock via
    # `stub_pocket_id_auth` — rien n'est appelé côté réseau.
    OmniAuth.config.test_mode = true
    OmniAuth.config.logger = Rails.logger
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.test_mode = false
  end

  test "GET /sign_in renders the Pocket ID button" do
    get sign_in_path
    assert_response :success
    assert_select "form[action=?][method=?]", "/auth/pocket_id", "post"
    assert_select "button", text: /Continuer avec Pocket ID/
  end

  test "GET /sign_in rend l'écran de connexion (layout force, thème undust)" do
    require_undust_theme!
    get sign_in_path
    assert_response :success
    # Non-régression : le rendu inline d'origine (sans layout, sans CSS) ne
    # doit pas revenir. Depuis la charte :
    # bundle tailwind + carte de connexion, UN seul CTA aplat accent,
    # aucun chrome de session, bande basse système (langue + thème).
    assert_select "link[href*=?]", "tailwind"
    assert_select "body.connexion-body .connexion-carte button.connexion-cta", count: 1
    assert_select ".connexion-carte .connexion-mono .atome"
    assert_select "footer.connexion-bas [data-theme-toggle]"
    assert_select "footer.connexion-bas a.chrome-bouton[lang]"
    assert_select ".chrome-haut", count: 0
    assert_select ".chrome-deconnexion", count: 0
    # La couleur de barre vient de la gem (manifest), pas d'un hex recopié.
    assert_select "meta[name='theme-color'][content=?]", Theme.current.theme_color
  end

  # done_when spec (2/2) : "Une route animateur sans session redirige
  # vers le login OIDC" — le login OIDC est derrière /sign_in (le bouton
  # POST /auth/pocket_id, cf. omniauth-rails_csrf_protection).
  test "requires_authentication" do
    get webinars_path
    assert_redirected_to sign_in_path
    assert_match(/animateur/i, flash[:alert])
  end

  # Un compte sans droit d'animation est spectateur (404 sur cette zone,
  # SpectatorAuthorizationTest) : l'animateur est ici propriétaire d'un webinaire.
  test "authenticated user sees the animateur zone" do
    user = User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
    Webinar.create!(title: "Le sien", starts_at: 1.day.from_now, host_sub: user.oidc_sub)
    stub_pocket_id_auth(sub: "sub-marc", email: "marc@example.com")
    get "/auth/pocket_id/callback"
    assert_equal user.id, session[:user_id]

    get webinars_path
    assert_response :success
    assert_match(/webinars/i, response.body)
  end

  # done_when spec (1/2) : "Le callback OIDC retrouve/lie l'user par
  # oidc_sub, jamais par simple email". Le point critique : un email
  # existant en base pour un SUB DIFFÉRENT ne doit PAS ouvrir la session
  # sur ce user (sinon un attaquant qui contrôle un Pocket ID avec le
  # même email prendrait la place de l'animateur légitime).
  test "callback_links_by_oidc_sub" do
    # Cas 1 — sub connu, email différent : session s'ouvre sur CET user,
    # sans création. L'email local est actualisé (le sub est roi).
    existing = User.create!(email: "marc-old@example.com", oidc_sub: "sub-marc")
    stub_pocket_id_auth(sub: "sub-marc", email: "marc-new@example.com")

    assert_no_difference -> { User.count } do
      get "/auth/pocket_id/callback"
    end
    assert_equal existing.id, session[:user_id]
    assert_equal "marc-new@example.com", existing.reload.email

    reset!

    # Cas 2 — sub INCONNU, mais email A DÉJÀ un user (avec un autre sub) :
    # rapprochement PAR EMAIL INTERDIT. Ici l'unicité email (validation
    # AR case-insensitive + index lower(email)) protège le modèle, et
    # le controller REFUSE proprement (pas de 500, pas de doublon, pas
    # de "prise de compte" par email).
    victime = User.create!(email: "victime@example.com", oidc_sub: "sub-victime")
    stub_pocket_id_auth(sub: "sub-attaquant", email: "victime@example.com")

    assert_no_difference -> { User.count } do
      get "/auth/pocket_id/callback"
    end
    assert_redirected_to sign_in_path
    assert_match(/conflit/i, flash[:alert])
    assert_nil session[:user_id]
    # La victime n'a pas été "prise" — son sub reste intact.
    assert_equal "sub-victime", victime.reload.oidc_sub
  end

  test "callback creates the user on first sub" do
    stub_pocket_id_auth(sub: "sub-brand-new", email: "new@example.com")
    assert_difference -> { User.count }, 1 do
      get "/auth/pocket_id/callback"
    end
    user = User.find_by(oidc_sub: "sub-brand-new")
    assert user
    assert_equal "new@example.com", user.email
    assert_equal user.id, session[:user_id]
  end

  # `return_to` (posé par Authenticatable avant la redirection vers /sign_in)
  # était lu APRÈS `reset_session`, donc toujours vide : retour forcé sur
  # /webinars. Lu avant, il ramène sur la page demandée.
  test "callback ramène sur la page demandée avant la connexion" do
    User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
    webinar = Webinar.create!(title: "Demo", starts_at: 1.day.from_now, host_sub: "sub-marc")
    get webinar_path(webinar)
    assert_redirected_to sign_in_path

    stub_pocket_id_auth(sub: "sub-marc", email: "marc@example.com")
    get "/auth/pocket_id/callback"

    assert_redirected_to webinar_path(webinar)
    assert_nil session[:return_to]
  end

  # 10/11 : un onglet resté ouvert sondait /webinars/<slug>/recordings/
  # status.json sans session. Authenticatable posait ce JSON en
  # `return_to` (la connexion suivante atterrissait dessus) et un flash
  # « Connexion animateur requise » qui s'affichait sur la page publique
  # du café suivant.
  test "un sondage JSON sans session est renvoyé à la connexion sans return_to ni flash" do
    User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
    webinar = Webinar.create!(title: "Demo", starts_at: 1.day.from_now, host_sub: "sub-marc")

    get "/webinars/#{webinar.slug}/recordings/status.json",
        headers: { "Sec-Fetch-Mode" => "cors", "Accept" => "application/json" }

    # Redirection conservée : les clients JS de l'animation lisent
    # l'`opaqueredirect` comme « session animateur expirée ».
    assert_redirected_to sign_in_path
    assert_nil session[:return_to]
    assert_nil flash[:alert]

    get webinar_path(webinar)
    assert_redirected_to sign_in_path
    stub_pocket_id_auth(sub: "sub-marc", email: "marc@example.com")
    get "/auth/pocket_id/callback"
    assert_redirected_to webinar_path(webinar)
  end

  test "callback rejects incomplete OIDC payload" do
    stub_pocket_id_auth(sub: "sub-x", email: "")
    assert_no_difference -> { User.count } do
      get "/auth/pocket_id/callback"
    end
    assert_redirected_to sign_in_path
    assert_match(/incomplète/i, flash[:alert])
  end

  test "oidc_failure redirects to sign_in with alert" do
    get "/auth/failure", params: { message: "invalid_credentials", strategy: "pocket_id" }
    assert_redirected_to sign_in_path
    assert_match(/échouée/i, flash[:alert])
  end

  test "oidc_failure ne laisse pas un paramètre forger une ligne de journal" do
    io = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)

    get "/auth/failure", params: { message: "x\nI, [faux] INFO -- : ligne forgée", strategy: "a" * 500 }

    assert_redirected_to sign_in_path
    line = io.string.lines.grep(/\[OIDC\] failure/).sole
    assert_includes line, '"x\\nI, [faux] INFO -- : ligne forgée"'
    assert_includes line, "(strategy=\"#{'a' * 40}\")"
    assert_no_match(/^I, \[faux\]/, io.string)
  ensure
    Rails.logger = previous_logger
  end

  test "sign_out clears session" do
    user = User.create!(email: "alice@example.com", oidc_sub: "sub-alice")
    stub_pocket_id_auth(sub: "sub-alice", email: "alice@example.com")
    get "/auth/pocket_id/callback"
    assert session[:user_id]

    delete sign_out_path
    assert_nil session[:user_id]
  end

  private

  def stub_pocket_id_auth(sub:, email:)
    hash = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: sub,
      info: { email: email }
    )
    OmniAuth.config.mock_auth[:pocket_id] = hash
    Rails.application.env_config["omniauth.auth"] = hash
  end
end
