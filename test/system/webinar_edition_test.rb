require "application_system_test_case"

# Parcours du propriétaire qui déplace ou annule son café (rack_test : la
# confirmation est une case vérifiée serveur, sans JavaScript).
class WebinarEditionSystemTest < ApplicationSystemTestCase
  include OidcSignIn

  setup do
    travel_to Time.zone.local(2026, 11, 10, 10, 0)
    @owner = User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
    @guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.zone.local(2026, 11, 12, 18, 0),
                               host_sub: @owner.oidc_sub, visibility: "published", kind: "cafe_ia")
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @webinar.registrations.create!(name: "Alice", email: "alice@example.com", confirmed_at: 1.hour.ago)
    @webinar.registrations.create!(name: "Bob", email: "bob@example.com", confirmed_at: 1.hour.ago)
    @webinar.registrations.create!(name: "Carol", email: "carol@example.com")
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "le propriétaire déplace la date depuis la page du webinaire" do
    sign_in_as(@owner)
    visit webinar_path(@webinar)
    click_link "Modifier"

    assert_selector "h1", text: "Modifier le café"
    assert_selector "[data-role='reschedule-notice']",
                    text: "Changer la date prévient les 2 personnes inscrites et confirmées"
    fill_in "Démarre le", with: "2026-11-13T19:30"
    fill_in "Titre", with: "Café IA #9 — reporté"
    click_on "Enregistrer"

    assert_current_path webinar_path(@webinar)
    assert_text "Webinaire modifié."
    assert_selector "h1", text: "Café IA #9 — reporté"
    assert_selector "time[datetime='#{Time.zone.local(2026, 11, 13, 19, 30).iso8601}']"
  end

  test "une date invalide est refusée avec son message" do
    sign_in_as(@owner)
    visit webinar_edition_path(@webinar)
    fill_in "Démarre le", with: "2026-11-01T18:00"
    click_on "Enregistrer"

    assert_selector "[role='alert']", text: "Démarre le doit être au moins 15 minutes après maintenant"
    assert_equal Time.zone.local(2026, 11, 12, 18, 0), @webinar.reload.starts_at
  end

  test "dépublier avec confirmation : le café quitte le catalogue et l'agenda" do
    visit root_path
    assert_link "Café IA #9"

    sign_in_as(@owner)
    visit webinar_edition_path(@webinar)

    click_on "Dépublier (annuler ce café)"
    assert_text "Coche la case de confirmation"
    assert @webinar.reload.visibility_published?

    check "Je confirme l’annulation : le café quitte le catalogue et l’agenda, " \
          "et les 2 personnes inscrites et confirmées seront prévenues."
    click_on "Dépublier (annuler ce café)"

    assert_current_path webinar_path(@webinar)
    assert_text "Webinaire annulé"
    visit root_path
    assert_no_link "Café IA #9"
    visit agenda_path
    assert_no_text "Café IA #9"
  end

  test "le co-animateur ne voit pas le lien et l'écran lui est fermé" do
    sign_in_as(@guest)
    visit webinar_path(@webinar)
    assert_no_selector "[data-role='webinar-edit']"

    visit webinar_edition_path(@webinar)
    assert_equal 404, page.status_code
  end

  test "un café passé ne se modifie plus" do
    @webinar.update!(starts_at: 2.days.ago)
    sign_in_as(@owner)
    visit webinar_path(@webinar)
    assert_no_selector "[data-role='webinar-edit']"

    visit webinar_edition_path(@webinar)
    assert_current_path webinar_path(@webinar)
    assert_text "Ce webinaire a commencé ou est passé : il ne se modifie plus."
  end
end
