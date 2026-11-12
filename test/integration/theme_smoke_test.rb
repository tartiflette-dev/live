# frozen_string_literal: true

require "test_helper"

# Fumée du thème, quel qu'il soit : connexion, page d'erreur, salle et
# bascule clair/sombre rendent avec l'identité de Brand. Lancé aussi sans la
# gem undust-charte : BUNDLE_GEMFILE=Gemfile BRAND_THEME=tartiflette.
class ThemeSmokeTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  test "connexion : nom du produit, monogramme, crédit et favicon du thème" do
    get "/sign_in"

    assert_response :success
    assert_select "title", text: Brand.product_name
    assert_select ".connexion-produit", text: Brand.product_name
    assert_select ".connexion-marque svg.connexion-mono"
    assert_select "a.chrome-signature[href=?]", Brand.credit.url
    assert_select "meta[name=theme-color][content=?]", Theme.current.theme_color
    assert_select "link[rel=icon][href*=?]", File.basename(Brand.favicon, ".svg")
  end

  test "page d'erreur : code, hôte de la marque, crédit" do
    get erreur_path(code: "404")

    assert_response :not_found
    assert_select ".erreur-code", text: "404"
    assert_match Brand.host, response.body
  end

  test "salle : la scène de l'animateur rend avec le monogramme du thème" do
    host = User.create!(email: "theme@example.com", oidc_sub: "sub-theme", admin: true)
    webinar = Webinar.create!(title: "Fumée", starts_at: 1.day.from_now, host_sub: host.oidc_sub, visibility: "published")
    sign_in_as(host)

    get stage_webinar_path(slug: webinar.slug)

    assert_response :success
    assert_select "title", text: Brand.product_name
    assert_select "svg.lk-page__mono"
  end

  test "bascule clair/sombre : cookie posé, retour à la page" do
    post theme_path(theme: "dark"), headers: { "HTTP_REFERER" => "http://www.example.com/sign_in" }

    assert_redirected_to "http://www.example.com/sign_in"
    assert_equal "dark", cookies[:theme]
  end

  test "hors thème undust : aucune trace de la gem dans le rendu" do
    skip "thème undust : la gem rend le chrome" if Theme.undust?
    get "/sign_in"

    assert_not defined?(Undust::Charte)
    assert_select "script", text: /dataset\.theme = "(light|dark)"/
    assert_no_match(/undust-theme-toggle|undust\/charte/, response.body)
  end
end
