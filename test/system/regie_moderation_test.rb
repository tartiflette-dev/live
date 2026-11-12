require "application_system_test_case"

# Modération du direct depuis la régie : jusqu'ici, la seule arme contre un intrus était
# « Terminer ». Deux navigateurs : la régie de l'animation et un spectateur
# inscrit. La CI n'a pas de LiveKit : la salle est la salle simulée partagée
# (LivekitPacketDelivery::RoomRecorder), qui coupe la piste et fait sortir la
# personne comme le ferait livekit-server.
class RegieModerationTest < JsSystemTestCase
  include OidcSignIn
  include LivekitPacketDelivery

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "marc@example.test", oidc_sub: "sub-marc-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @speaker = @webinar.speakers.create!(name: "Basile Delmas")
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    @room = RoomRecorder.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @room }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @previous_factory
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @saved_env[k] }
  end

  test "la régie coupe le micro d'un intervenant et retire un spectateur, qui ne revient plus" do
    registration = using_session(:viewer) { open_viewer_room }
    @room.participants = [
      person("host-#{@host.oidc_sub}", "Marc", tracks: [ microphone("TR_luc") ]),
      person("speaker-#{@speaker.id}", "Basile Delmas", tracks: [ microphone("TR_basile") ]),
      person("viewer-#{registration.id}", "Spectateur confirmé"),
      { identity: "agent-AJ_x", kind: "AGENT", name: "", permission: { can_publish: true }, tracks: [] }
    ]

    using_session(:host) do
      sign_in_as(@host)
      visit webinar_regie_path(@webinar)

      within("[data-testid='regie-participants']") do
        assert_selector "[data-testid='regie-participant']", count: 2, wait: 10
        assert_no_text "Marc"
        assert_selector "[data-testid='regie-participant']", text: /Basile Delmas\s*intervenant\s*micro ouvert/i
        assert_selector "button[aria-label='Couper le micro : Spectateur confirmé'][disabled]"

        find("button[aria-label='Couper le micro : Basile Delmas']").click
        assert_no_text(/micro ouvert/i, wait: 10)
        assert_selector "button[aria-label='Couper le micro : Basile Delmas'][disabled]"
      end
      assert_equal [ [ "speaker-#{@speaker.id}", "TR_basile" ] ], @room.muted

      within("[data-testid='regie-participant'][data-identity='viewer-#{registration.id}']") do
        click_on "Retirer"
        assert_selector "[data-testid='regie-participant-remove'][data-armed='true']", text: /\AConfirmer le retrait\s\?\z/
        click_on "Annuler"
        assert_selector "[data-testid='regie-participant-remove'][data-armed='false']", exact_text: "Retirer"
      end
      assert_empty @room.removed, "« Annuler » a retiré quelqu'un"

      within("[data-testid='regie-participant'][data-identity='viewer-#{registration.id}']") do
        click_on "Retirer"
        sleep 0.6 # au-delà de la garde anti double-clic (500 ms)
        click_on "Confirmer le retrait\u00a0?"
      end
      within("[data-testid='regie-participants']") do
        assert_no_selector "[data-testid='regie-participant']", text: "Spectateur confirmé", wait: 10
        assert_selector "[data-testid='regie-participant']", count: 1
        # Spectateur : rien à proposer sur le lien partagé (aucun n'est actif ici).
        assert_selector "[data-testid='regie-removal-notice']", exact_text: "Retrait de Spectateur confirmé confirmé."
        assert_no_selector "[data-testid='regie-share-link-regenerate']"
      end
    end
    assert_equal [ "viewer-#{registration.id}" ], @room.removed
    assert registration.reload.room_removed_at

    using_session(:viewer) do
      visit public_webinar_path(slug: @webinar.slug)
      assert_selector "[data-role='registration-cta']"
      assert_no_selector "[data-testid='side-panel']"
    end
  end

  # Le co-animateur invité ne retire qu'une personne présente ;
  # partie entre l'affichage et le clic, elle garde son lien.
  test "le co-animateur ne retire pas un intervenant sorti de la salle : la régie le dit, son lien tient" do
    guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co-#{SecureRandom.hex(4)}",
                         email_verified: true, email_verified_for: "co@partenaire.test")
    @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @host.oidc_sub)
    @room.participants = [ person("speaker-#{@speaker.id}", "Paul Martin") ]

    sign_in_as(guest, email_verified: true)
    visit webinar_regie_path(@webinar)
    within("[data-testid='regie-participant'][data-identity='speaker-#{@speaker.id}']", wait: 10) do
      @room.participants = []
      click_on "Retirer"
      sleep 0.6 # au-delà de la garde anti double-clic (500 ms)
      click_on "Confirmer le retrait ?"
    end

    assert_selector "[data-testid='participants-error']", exact_text: "Paul Martin non retiré : la personne n'est plus dans la salle, rien n'a été fait.", wait: 10
    assert_empty @room.removed
    assert_nil @speaker.reload.revoked_at
    assert_nil @speaker.room_removed_at
  end

  private

  def open_viewer_room
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "[data-testid='side-panel']", wait: 10
    @webinar.registrations.find_by!(email: "viewer@example.test")
  end

  def person(identity, name, tracks: [])
    { identity: identity, kind: "STANDARD", name: name, permission: { can_publish: tracks.any? }, tracks: tracks }
  end

  def microphone(sid)
    { sid: sid, type: "AUDIO", source: "MICROPHONE", muted: false }
  end
end
