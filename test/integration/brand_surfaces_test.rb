# frozen_string_literal: true

require "test_helper"

# Les points d'entrée partagés (layouts, bande basse, pages d'erreur, mails)
# affichent la marque de `Brand` (valeurs de l'environnement de test).
class BrandSurfacesTest < ActionDispatch::IntegrationTest
  test "connexion : titre, carte et signature viennent de la marque" do
    require_undust_theme!
    get "/sign_in"

    assert_response :success
    assert_select "title", text: "Live"
    assert_select ".connexion-produit", text: "Live"
    assert_select "footer.connexion-bas a.chrome-signature[href='https://undust.co']", text: "undust"
  end

  test "page d'erreur : mention de l'hôte public de la marque" do
    get erreur_path(code: "404")

    assert_match "live.example.test", response.body
  end

  test "mails : expéditeur, contact de repli et signature de la marque" do
    webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: "sub-absent", visibility: "published")
    mail = ConsentMailer.revocation_failed(webinar, webinar.speakers.create!(name: "Camille Martin"))

    assert_equal [ "noreply@live.example.test" ], mail.from
    assert_equal [ "contact@example.test" ], mail.to
    assert_match "— live.example.test", mail.text_part.body.to_s
  end

  test "crédit du thème : affiché par défaut, retiré par BRAND_CREDIT_SHOWN=false" do
    get "/sign_in"
    assert_select "footer.connexion-bas a.chrome-signature[href=?]", Brand.credit.url, text: Brand.credit.label

    with_brand("BRAND_CREDIT_SHOWN" => "false") do
      get "/sign_in"
      assert_select "footer.connexion-bas"
      assert_select ".chrome-signature", 0
    end
  end

  # Page d'erreur du chrome par défaut (la charte undust rend la sienne).
  test "page d'erreur du chrome par défaut : crédit et liens retirés par BRAND_CREDIT_SHOWN=false" do
    skip "page d'erreur de la charte undust" if Theme.undust?
    get erreur_path(code: "404")
    assert_select ".erreur-pied .theme-credit a.chrome-signature", text: Brand.credit.label

    with_brand("BRAND_CREDIT_SHOWN" => "false") do
      get erreur_path(code: "404")
      assert_select ".erreur-pied"
      assert_select ".theme-credit, .chrome-signature, .theme-lien", 0
    end
  end
end
