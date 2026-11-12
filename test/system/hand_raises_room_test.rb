require "application_system_test_case"

# Capybara couverture bout en bout des contrôles « lever la main » /
# « donner la parole » rendus par app/javascript/rooms/room.jsx.
#
# Pattern : la permission réelle LiveKit (push participant.permissions)
# exige un serveur WebRTC — IRRÉALISTE dans ces tests headless. On stub
# donc RoomServiceClient (comme stage_state_button_test / recording) et
# on vérifie :
#   1. le spectateur voit « Lever la main » et sa requête POST crée
#      effectivement un HandRaise en base ;
#   2. l'animateur voit la file se peupler dans la RÉGIE
#      (via le poll de 5 s) et son
#      clic « Donner la parole » déclenche RoomServiceClient#update_participant
#      avec can_publish=true + marque la main granted en base ;
#   3. « Retirer la parole » déclenche update_participant can_publish=false
#      + marque la main revoked.
#   4. Isolation : le viewer public ne reçoit AUCUN data-attr host, et
#      la scène animateur ne reçoit ni la file (régie) ni le data-attr viewer.
#
# La transition viewer → ControlBar visible dépend du push LiveKit
# (useLocalParticipantPermissions). On ne la pilote pas ici : le test
# contrôleur `grant and revoke use server identity` couvre déjà l'invariant
# côté serveur. Ce test système atteste la BOUCLE d'appels côté UI.
class HandRaisesRoomTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  class FakeRoomClient
    attr_accessor :calls, :error
    def initialize
      @calls = []
    end
    def update_participant(**arguments)
      @calls << arguments
      raise error if error
      {}
    end
    # No-op : RecordingSession.start_composite (ensure_active côté /stage)
    # appelle create_room sur le même client que les permissions. Pas
    # d'intérêt dans ce test — on log pour debug mais on n'échoue pas.
    def create_room(**_arguments); {}; end
    # Lectures de la régie (RoomSnapshot) : salle ouverte, vide.
    def room_metadata(room:) = ""
    def list_participants(room:) = []
  end

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(
      title: "Kick-off Q4",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published",
      state: "live",
      started_at: Time.current
    )
    @prev_key    = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    @prev_url    = ENV["LIVEKIT_URL"]
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"

    @client = FakeRoomClient.new
    @prev_room_factory    = Rails.configuration.x.room_service_client_factory
    @prev_egress_factory  = Rails.configuration.x.egress_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @client }
    # Egress stub de courtoisie — l'auto-start côté stage ne doit pas se
    # perdre sur un refus réseau pendant les tests UI hand-raise.
    stub = Object.new
    def stub.start_room_composite(**_); { egress_id: "EG_test", status: :starting, raw: nil }; end
    def stub.stop(**_); { egress_id: "EG_test", status: :ending, raw: nil }; end
    def stub.list_egress(**_); { egress_id: "EG_test", status: :active, ended_at: 0, error: nil, raw: nil }; end
    Rails.configuration.x.egress_client_factory = -> { stub }
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
    ENV["LIVEKIT_URL"]        = @prev_url
    Rails.configuration.x.room_service_client_factory = @prev_room_factory
    Rails.configuration.x.egress_client_factory       = @prev_egress_factory
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "viewer sees the raise button and his POST creates a HandRaise" do
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)

    # Data-attr viewer posé (viewer confirmé + webinaire live).
    assert_selector "#livekit-room[data-viewer-hand-raises-url]", visible: :all
    assert_no_selector "#livekit-room[data-host-hand-raises-url]", visible: :all

    # Composant monté dès que la salle est connectée (le wrapper reste
    # rendu même si LiveKit échoue — le poll REST tourne quand même).
    assert_selector "[data-testid='hand-raise-toggle']", text: /Lever la main/, wait: 10
    assert_selector "[data-testid='hand-raise-notice']", text: /image et ta voix sont enregistrées/

    click_button "Lever la main"

    # Le serveur crée la main (invariant observable via DB) et la UI passe
    # en « Baisser la main » après le refresh immédiat du composant.
    assert_selector "[data-testid='hand-raise-toggle']", text: /Baisser la main/, wait: 10
    assert_equal 1, @webinar.hand_raises.active.count
    hand = @webinar.hand_raises.active.first
    assert_equal "waiting", hand.state
  end

  test "host grants and revokes a raised hand from the régie, driving LiveKit" do
    registration = @webinar.registrations.create!(
      name: "Alice",
      email: "alice@example.test",
      confirmed_at: Time.current
    )
    # Accord à l'image déjà donné : la parole accordée ouvre la publication.
    ParticipantConsent.grant!(registration, recording: true, excerpts: false, adult: true)
    HandRaiseControl.new(@webinar, client: @client).raise_hand(registration)

    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)

    # Ni la file (régie) ni le data-attr viewer côté scène.
    assert_no_selector "#livekit-room[data-host-hand-raises-url]", visible: :all
    assert_no_selector "#livekit-room[data-viewer-hand-raises-url]", visible: :all

    visit webinar_regie_path(@webinar)

    # File peuplée (poll immédiat au montage de HandRaiseHost).
    assert_selector "[data-testid='hand-raise-item']", text: "Alice", wait: 10
    assert_selector "[data-testid='hand-raise-grant']", text: /Donner la parole/

    click_button "Donner la parole"

    # Grant → update_participant côté LiveKit + état granted en base + bouton
    # revoke.
    assert_selector "[data-testid='hand-raise-revoke']", text: /Retirer la parole/, wait: 10
    grant_call = @client.calls.find { |c| c[:can_publish] == true }
    refute_nil grant_call, "update_participant can_publish=true attendu"
    assert_equal "viewer-#{registration.id}", grant_call[:identity]
    assert_equal @webinar.room_name, grant_call[:room]
    assert_equal "granted", @webinar.hand_raises.find_by(registration: registration).state

    click_button "Retirer la parole"

    # Revoke → update_participant can_publish=false + état revoked + liste vide.
    assert_selector "[data-testid='hand-raise-host-empty']", text: /Aucune main levée/, wait: 10
    revoke_call = @client.calls.find { |c| c[:can_publish] == false }
    refute_nil revoke_call, "update_participant can_publish=false attendu"
    assert_equal "viewer-#{registration.id}", revoke_call[:identity]
    assert_equal "revoked", @webinar.hand_raises.find_by(registration: registration).state
  end

  private

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: { email: user.email }
    )
    visit "/auth/pocket_id/callback"
  end
end
