require "application_system_test_case"

# Après la fin du direct, un animateur
# rechargeait la scène, rejoignait la salle et en était aussitôt déconnecté ;
# « j'ai même pas moyen de remettre le truc en direct, alors qu'il y avait
# un bouton avant pour l'arrêter » ; un bouton « Enregistrer » restait actif
# sur le direct terminé.
#
# Désormais : la scène d'un direct terminé dit « Direct terminé », liste les
# enregistrements et propose « Reprendre le direct » (confirmation en deux
# temps, comme « Terminer ») ; dans la régie (où vivent
# les commandes du direct), le bouton d'état passe à « Reprendre le direct »
# et l'enregistrement ne se relance plus seul.
class LiveResumeTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(title: "Café IA #7", starts_at: 2.hours.ago, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: 2.hours.ago)
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    @prev_egress = Rails.configuration.x.egress_client_factory
    @prev_room   = Rails.configuration.x.room_service_client_factory
    egress, room = egress_stub, room_stub
    Rails.configuration.x.egress_client_factory       = -> { egress }
    Rails.configuration.x.room_service_client_factory = -> { room }
    sign_in_host
  end

  teardown do
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @saved_env[k] }
    Rails.configuration.x.egress_client_factory       = @prev_egress
    Rails.configuration.x.room_service_client_factory = @prev_room
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "scène d'un direct terminé : pas de salle, les enregistrements, et la reprise en deux temps" do
    previous = @webinar.recordings.create!(status: "done", path: "#{@webinar.slug}/seance.mp4",
                                           started_at: 2.hours.ago, ended_at: 1.hour.ago)
    @webinar.update!(state: "ended", ended_at: 1.hour.ago)

    visit stage_webinar_path(slug: @webinar.slug)

    assert_selector "[data-testid='ended-stage'] h2", text: "Direct terminé"
    assert_no_selector "#livekit-room", visible: :all
    assert_selector "[data-testid='ended-recordings'] li", text: /Vue d'ensemble.*prête/
    assert_selector "a[data-testid='ended-recordings-link']", text: "Voir les enregistrements"

    click_on "Reprendre le direct"
    assert_selector "[data-testid='state-button'][data-armed='true']", text: "Confirmer la reprise du direct ?"
    assert_equal "ended", @webinar.reload.state, "un seul clic a repris le direct"
    sleep 0.6 # au-delà de la garde anti double-clic (500 ms)
    click_on "Confirmer la reprise du direct ?"

    assert_selector "[data-testid='prejoin']", wait: 10
    assert_equal "live", @webinar.reload.state
    assert_equal 1, @webinar.recordings.composite.active.count, "l'enregistrement repart dans un nouveau fichier"
    assert_equal [ "done", "#{@webinar.slug}/seance.mp4" ], previous.reload.values_at(:status, :path)
  end

  test "dans la régie : après la fin, « Reprendre le direct » et plus de bouton « Enregistrer »" do
    open_regie
    assert_selector "[data-testid='recording-control'][data-state='recording']", wait: 10

    click_on "Terminer le direct"
    sleep 0.6
    click_on "Confirmer la fin du direct ?"

    assert_selector "[data-testid='state-button'][data-state='ended']", text: "Reprendre le direct", wait: 10
    assert_selector "[data-testid='recording-status']", text: "Enregistrement arrêté", wait: 10
    assert_no_selector "[data-testid='recording-start']"

    click_on "Reprendre le direct"
    sleep 0.6
    click_on "Confirmer la reprise du direct ?"

    assert_selector "[data-testid='state-button'][data-state='live']", text: "Terminer le direct", wait: 10
    assert_equal "live", @webinar.reload.state
    assert_selector "[data-testid='recording-control'][data-state='recording']", wait: 15
  end

  private

  def sign_in_host
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: @host.oidc_sub, info: { email: @host.email }
    )
    visit "/auth/pocket_id/callback"
  end

  # Scène d'abord (auto-démarrage de l'enregistrement), puis la régie.
  def open_regie
    visit stage_webinar_path(slug: @webinar.slug)
    visit webinar_regie_path(@webinar)
    assert_selector "[data-testid='state-button']", wait: 10
  end

  def egress_stub
    stub = Object.new
    def stub.start_room_composite(room_name:, filepath:)
      { egress_id: "EG_#{SecureRandom.hex(3)}", status: :active, raw: nil }
    end
    def stub.stop(egress_id:)
      { egress_id: egress_id, status: :ending, raw: nil }
    end
    def stub.list_egress(egress_id:)
      { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
    stub
  end

  def room_stub
    stub = Object.new
    def stub.create_room(name:, **) = { name: name }
    def stub.list_participants(room:) = []
    def stub.list_agent_dispatches(room:) = []
    def stub.room_metadata(room:) = ""
    def stub.remove_participant(room:, identity:) = {}
    stub
  end
end
