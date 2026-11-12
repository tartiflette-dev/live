require "application_system_test_case"

# « Ce n'est pas moi » (NotMeController) : le cookie
# d'inscription est persistant et un navigateur garde sa première inscription
# valide (409 sur une autre). Parcours réels, au bouton : ordinateur partagé
# pendant le direct, deux adresses dans un même navigateur, navigateur retiré.
# Garanties détaillées (retrait jamais levé, cookie d'un autre webinaire
# gardé) : test/integration/room_removal_test.rb.
# Capybara lit le texte visible : les espaces insécables des libellés
# (avant « ? », « : », dans les guillemets) y deviennent des espaces.
class NotMeTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @privacy_url = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
  end

  teardown do
    ENV["REGISTRATION_PRIVACY_URL"] = @privacy_url
  end

  test "Café IA, ordinateur partagé : la personne suivante fait oublier la salle de la précédente et entre sous son nom" do
    cafe = live_webinar(kind: "cafe_ia")
    visit public_webinar_path(cafe.slug)
    register_during_live("Alice", "alice@example.test")
    assert_selector "#livekit-room"
    assert_text "Tu es dans le café sous le nom « Alice »."

    # Basile s'assoit au même poste : la salle s'ouvre sous le nom d'Alice.
    visit public_webinar_path(cafe.slug)
    assert_text "sous le nom « Alice »"
    click_button "Ce n'est pas moi"

    assert_current_path public_webinar_path(cafe.slug)
    assert_text "C'est oublié : ce navigateur n'a plus d'inscription à ce café."
    assert_no_selector "#livekit-room"
    register_during_live("Basile", "basile@example.test")
    assert_selector "#livekit-room"
    assert_text "Tu es dans le café sous le nom « Basile »."
    assert_no_text "Alice"
    alice = Registration.find_by!(email: "alice@example.test")
    assert alice.provisional?, "l'inscription d'Alice n'est pas touchée"
    assert_nil alice.room_removed_at
  end

  test "deux adresses dans un même navigateur : 409 sur la deuxième, qui entre après « Ce n'est pas moi »" do
    webinar = live_webinar
    confirm_viewer_registration(webinar)
    second = webinar.registrations.create!(name: "Inès pro", email: "ines.pro@example.test")

    visit confirm_registration_path(second.token)
    click_button "Confirmer mon inscription"
    assert_text "Ce navigateur est déjà inscrit"
    # La page nomme l'inscription GARDÉE, celle que le bouton oublie.
    assert_text "Cette inscription est au nom de « Spectateur confirmé ». Ce n'est pas vous (ordinateur partagé) ?"
    assert_no_text "Inès pro"
    click_button "Ce n'est pas moi"

    assert_current_path public_webinar_path(webinar.slug)
    assert_text "Ce navigateur a oublié son inscription à ce webinaire."
    visit confirm_registration_path(second.token)
    click_button "Ouvrir la page du webinaire"
    assert_current_path public_webinar_path(webinar.slug)
    assert_selector "#livekit-room"
    assert_text "Vous êtes dans la salle sous le nom « Inès pro »."
  end

  test "avant le direct, la page nomme l'inscription et la fait oublier" do
    webinar = Webinar.create!(title: "Bootcamp demain", starts_at: 1.day.from_now, host_sub: "host",
                              visibility: "published", kind: "bootcamp")
    confirm_viewer_registration(webinar)
    assert_text "Vous êtes inscrit·e, Spectateur confirmé."
    click_button "Ce n'est pas moi"

    assert_text "Ce navigateur a oublié son inscription à ce webinaire."
    assert_button "M'inscrire"
    assert_no_text "Vous êtes inscrit·e"
  end

  test "navigateur retiré : aucun bouton « Ce n'est pas moi », la salle reste fermée" do
    webinar = live_webinar
    confirm_viewer_registration(webinar)
    webinar.registrations.find_by!(email: "viewer@example.test").remove_from_room!

    visit public_webinar_path(webinar.slug)
    assert_no_selector "#livekit-room"
    assert_no_button "Ce n'est pas moi"
  end

  private

  def live_webinar(kind: "bootcamp")
    Webinar.create!(title: "Direct #{kind.dasherize}", starts_at: 10.minutes.ago, host_sub: "host",
                    visibility: "published", kind: kind, state: "live", started_at: 10.minutes.ago)
  end

  # Formulaire de la page pendant le direct, libellés de la tonalité.
  def register_during_live(name, email)
    voice = Webinar.find_by!(slug: current_path.split("/").last).voice
    fill_in Voice.t("webinars.registration_cta.name", voice: voice), with: name
    fill_in Voice.t("webinars.registration_cta.email", voice: voice), with: email
    click_button Voice.t("webinars.registration_cta.submit", voice: voice)
  end
end
