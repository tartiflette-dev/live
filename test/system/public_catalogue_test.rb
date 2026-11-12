require "application_system_test_case"

class PublicCatalogueTest < ApplicationSystemTestCase
  include OidcSignIn

  # Capybara rack_test (pas de
  # JS requis : le catalogue rend HTML pur, aucun composant React ici). Même
  # driver que WebinarCreationTest — cohérence avec les critères côté serveur.

  test "un visiteur anonyme voit le titre catalogue et le lien /w/<slug>" do
    host_sub = "sub-host-#{SecureRandom.hex(4)}"
    w = Webinar.create!(
      title: "Café IA — automne",
      starts_at: 3.days.from_now,
      host_sub: host_sub,
      visibility: "published",
      kind: "cafe_ia",
      price_cents: 0
    )

    visit "/"

    assert_selector "h1", text: "Prochains webinaires"
    assert_selector "[data-role='catalogue']"
    assert_selector "a[href='/w/#{w.slug}']", text: "Café IA — automne"
    assert_text "Gratuit"
  end

  # Cas réel : à l'heure du direct, l'accueil disait
  # « Aucun événement à venir » et l'inscrit tournait en rond.
  test "un inscrit arrivé après l'heure trouve le direct en tête de l'accueil et le rejoint" do
    host_sub = "sub-host-#{SecureRandom.hex(4)}"
    Webinar.create!(title: "Bootcamp — à venir", starts_at: 2.days.from_now,
                    host_sub: host_sub, visibility: "published", kind: "bootcamp")
    live = Webinar.create!(title: "Café IA #7", starts_at: 10.minutes.ago, state: "live",
                           started_at: 5.minutes.ago, host_sub: host_sub, visibility: "published")

    visit "/"

    within("[data-role='catalogue'] > li:first-child") do
      assert_selector "[data-role='catalogue-status']", text: "En direct"
      click_link "Café IA #7"
    end

    assert_current_path "/w/#{live.slug}"
    assert_selector "[data-role='live-registration-required']", text: "Le café a commencé"
  end

  test "un visiteur anonyme rejoint l'écran de connexion depuis le catalogue" do
    visit "/"

    within(".chrome-haut") { click_link "Connexion animateur" }

    assert_current_path sign_in_path
    assert_button "Continuer avec Pocket ID"
  end

  test "un animateur connecté ne voit pas le lien de connexion sur le catalogue" do
    sign_in_as(User.create!(email: "anim@example.com", oidc_sub: "sub-anim"))

    visit "/"

    assert_selector "h1", text: "Prochains webinaires"
    assert_selector ".chrome-deconnexion"
    assert_no_link "Connexion animateur"
    assert_no_selector "a[href='#{sign_in_path}']"
  end
end
