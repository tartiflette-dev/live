# frozen_string_literal: true

require "test_helper"

# Bandeau, <title>,
# application-name et carte de connexion affichent le SEUL nom du produit
# inscrit au registre `apps.json` de la gem (plus de « Undust Live » ; undust
# s'écrit en minuscules). La gem sert un manifest à TOUT front,
# `installable?` ne change plus que `display` (standalone/browser) — Live
# porte donc un `link[rel=manifest]`, display = browser.
class AppIdentityTest < ActionDispatch::IntegrationTest
  setup do
    require_undust_theme!
    @identity = Undust::Charte::AppIdentity.find(slug: "live")
    @host = User.create!(email: "v2noms@example.com", oidc_sub: "sub-v2noms", admin: true)
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "le registre décide : Live, l., non installable" do
    assert_equal [ "Live", "l", false ], [ @identity.display_name, @identity.letter, @identity.installable? ]
  end

  test "connexion : title = carte = application-name = registre, manifest de la gem" do
    get "/sign_in"
    assert_response :success
    assert_select "title", text: @identity.display_name
    assert_select ".connexion-produit", text: @identity.display_name
    assert_select "meta[name=application-name][content=?]", @identity.display_name
    # La gem sert le manifest (écran d'accueil) sur tous les fronts ; non
    # installable → display = browser.
    assert_select 'link[rel=manifest][href="/site.webmanifest"]', count: 1
    refute_match(/Undust Live|\(staging\)/, response.body)
  end

  test "session : bandeau = produit seul" do
    sign_in_as(@host)
    get root_path
    assert_response :success
    assert_select "a.chrome-compte", text: /\A\s*#{@identity.chrome_name}\s*\z/
    assert_select "meta[name=application-name][content=?]", @identity.display_name
    refute_match(/Undust Live|\(staging\)/, response.body)
  end

  private

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub, info: { email: user.email }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    get "/auth/pocket_id/callback"
    Rails.application.env_config.delete("omniauth.auth")
  end
end
