require "application_system_test_case"

# Parcours du programme d'un café : le co-animateur
# annonce le sujet, les intervenants et l'animateur du jour ; la page publique
# (et son inscription) et l'agenda les montrent. Le propriétaire le saisit dans
# son écran d'édition.
class WebinarProgramSystemTest < ApplicationSystemTestCase
  include OidcSignIn

  setup do
    @privacy_url = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/privacy"
    travel_to Time.zone.local(2026, 11, 10, 10, 0)
    @owner = User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
    @guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
    @webinar = Webinar.create!(title: "Café IA #10", starts_at: Time.zone.local(2026, 11, 12, 18, 0),
                               host_sub: @owner.oidc_sub, visibility: "published", kind: "cafe_ia")
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
  end

  teardown do
    ENV["REGISTRATION_PRIVACY_URL"] = @privacy_url
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "le co-animateur annonce le programme ; la page publique et l'agenda le montrent" do
    sign_in_as(@guest)
    visit webinar_path(@webinar)
    assert_no_selector "[data-role='webinar-edit']"
    click_link "Programme"

    fill_in "Sujet", with: "Agents IA : ce qui marche vraiment"
    fill_in "Présentation du sujet", with: "Deux retours de terrain, puis vos questions."
    fill_in "Intervenant annoncé 1", with: "Karim"
    fill_in "Intervenant annoncé 2", with: "Anne"
    fill_in "Animateur du jour", with: "Jean"
    click_on "Enregistrer le programme"

    assert_current_path webinar_path(@webinar)
    assert_text "Programme enregistré."
    assert_selector "[data-role='program-topic']", text: "Agents IA : ce qui marche vraiment"
    # Page animateur : les noms annoncés ne se confondent pas avec les liens
    # d'intervenants (Speaker), section que le co-animateur ne voit pas.
    assert_selector "dt", text: "Intervenants annoncés"
    assert_no_selector "h2#speakers-heading"

    visit public_webinar_path(slug: @webinar.slug)
    within "[data-role='pre-live'] [data-role='webinar-program']" do
      assert_selector "h2", text: "Agents IA : ce qui marche vraiment"
      assert_text "Deux retours de terrain, puis vos questions."
      assert_selector "[data-role='program-speakers']", text: "Karim et Anne"
      assert_selector "[data-role='program-lead-host']", text: "Jean"
    end
    assert_selector "[data-role='registration-cta'] form"

    visit agenda_path
    assert_selector "[data-role='agenda-program']", text: "Agents IA : ce qui marche vraiment · avec Karim et Anne · animé par Jean"
  end

  test "le propriétaire saisit le programme dans l'écran d'édition" do
    sign_in_as(@owner)
    visit webinar_path(@webinar)
    click_link "Modifier"

    within "[data-role='webinar-edition-program']" do
      fill_in "Sujet", with: "Prompting avancé"
      fill_in "Intervenant annoncé 1", with: "Zoé"
      click_on "Enregistrer le programme"
    end

    assert_text "Programme enregistré."
    assert_selector "dt", text: "Intervenant annoncé"
    assert_selector "h2#speakers-heading", text: "Intervenants"
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "[data-role='webinar-program'] h2", text: "Prompting avancé"
    assert_selector "[data-role='program-speakers']", text: "Zoé"
    assert_no_selector "[data-role='program-lead-host']"
  end

  test "sans programme, la page publique n'en montre aucun" do
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "[data-role='pre-live'] h1", text: "Café IA #10"
    assert_no_selector "[data-role='webinar-program']"
  end
end
