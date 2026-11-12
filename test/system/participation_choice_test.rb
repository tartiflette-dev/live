require "application_system_test_case"

# Entrée d'un inscrit qui n'a jamais choisi « J'observe » ou « Je participe »
# (inscrit venu d'un site partenaire qui ne transmet pas le choix) : la
# salle le demande avant d'entrer, une fois ; « Je participe » le fait entrer
# main levée, visible dans la file de la régie. LiveKit n'est pas joignable
# ici (wss://livekit.invalid) : la salle se monte, la main se lit par l'API.
class ParticipationChoiceTest < JsSystemTestCase
  include OidcSignIn

  class FakeRoomClient
    def update_participant(**_arguments) = {}
    def create_room(**_arguments) = {}
    def room_metadata(room:) = ""
    def list_participants(room:) = []
  end

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(title: "Café IA #12", kind: "cafe_ia", starts_at: Time.current, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @previous_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"] = "APIfake"
    ENV["LIVEKIT_API_SECRET"] = "sekret-32bytes-long-enough-abcdef"
    ENV["LIVEKIT_URL"] = "wss://livekit.invalid"
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { FakeRoomClient.new }
  end

  teardown do
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |key| ENV[key] = @previous_env[key] }
    Rails.configuration.x.room_service_client_factory = @previous_factory
  end

  test "spectateur qui choisit « Je participe » : message neutre côté salle, la régie le met en évidence" do
    confirm_viewer_registration(@webinar, participation_chosen: false)
    visit public_webinar_path(slug: @webinar.slug)

    within "[data-role=participation-choice]" do
      assert_selector "legend", text: /tu viens comment/i
      # Choix produit : l'écran ne parle ni de main levée ni d'admission.
      assert_no_text(/main|admet|animation|attente/i)
      assert_checked_field "J'observe — j'ai le chat"
      choose "Je participe — caméra et micro"
      click_button "J'entre"
    end

    assert_no_selector "[data-role=participation-choice]", wait: 10
    # En attente d'admission sans le lire : message neutre, jamais « main
    # levée » ni l'animation qui doit admettre (choix produit).
    assert_selector "[data-testid='hand-raise-status']", text: "On t'ouvre la caméra et le micro dans un instant.", wait: 10
    assert_selector "[data-testid='hand-raise-toggle']", text: "Je préfère observer"
    within("[data-testid='hand-raise-viewer']") { assert_no_text(/main levée|animat|admi|validation/i) }
    registration = @webinar.registrations.sole
    assert registration.participant?
    assert_equal "waiting", @webinar.hand_raises.active.sole.state

    # Rechargement dans le même direct : le choix n'est pas redemandé.
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "[data-testid='hand-raise-status']", text: "On t'ouvre la caméra et le micro dans un instant.", wait: 10
    assert_no_selector "[data-role=participation-choice]"

    # La régie met en évidence la personne à admettre.
    using_session(:animation) do
      sign_in_as(@host)
      visit webinar_regie_path(@webinar)
      assert_selector "[data-testid='hand-raise-to-admit']", text: "1 participant·e à admettre en caméra et micro", wait: 10
      within ".lk-hand-raise-host__item--a-admettre[data-testid='hand-raise-item']" do
        assert_selector "[data-testid='hand-raise-name']", text: registration.name
        assert_selector "[data-testid='hand-raise-wants-video']"
      end
    end

    # Changer d'avis : « Je préfère observer » baisse la main.
    click_button "Je préfère observer"
    assert_selector "[data-testid='hand-raise-toggle']", text: "Lever la main", wait: 10
    assert_empty @webinar.hand_raises.active
  end

  test "spectateur qui choisit « J'observe » : il entre sans main levée et peut la lever ensuite" do
    confirm_viewer_registration(@webinar, participation_chosen: false)
    visit public_webinar_path(slug: @webinar.slug)

    within "[data-role=participation-choice]" do
      click_button "J'entre"
    end

    assert_selector "[data-testid='hand-raise-toggle']", text: /Lever la main/, wait: 10
    assert_no_selector "[data-role=participation-choice]"
    registration = @webinar.registrations.sole
    assert registration.spectator?
    assert registration.participation_chosen?
    assert_empty @webinar.hand_raises

    click_button "Lever la main"
    assert_selector "[data-testid='hand-raise-toggle']", text: /Baisser la main/, wait: 10
  end

  test "choix refusé par le serveur : message visible, la salle n'est pas montée" do
    confirm_viewer_registration(@webinar, participation_chosen: false)
    visit public_webinar_path(slug: @webinar.slug)
    @webinar.registrations.sole.remove_from_room!

    within "[data-role=participation-choice]" do
      click_button "J'entre"
      assert_selector "[role=alert]", text: "Ton choix n'est pas passé. Réessaie, ou recharge la page."
    end
    assert_no_selector "[data-testid='hand-raise-toggle']"
  end
end
