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
end
