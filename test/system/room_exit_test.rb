require "application_system_test_case"

# Retour d'un animateur :
# « je viens de cliquer sur quitter et je me retrouve un peu nulle part […]
# je suis juste déconnecté sans savoir exactement ce qu'on a ». Seul un toast
# vendor « Disconnected » restait, sur une scène vide.
#
# Après « Quitter », chacun (animateur, intervenant, spectateur) voit un
# écran en français : pourquoi il est dehors, l'état du direct et de
# l'enregistrement, « Rejoindre à nouveau » ; l'animation garde « Terminer le
# direct » tant que le direct est en cours.
#
# La CI n'a pas de LiveKit (livekit.invalid, comme les autres tests salle) :
# la connexion échoue. Le test repasse la Room de la page à « connectée »
# (comme transcript_filter_test) puis clique le VRAI bouton « Quitter » de
# la barre : livekit-client émet alors Disconnected(CLIENT_INITIATED), comme
# en production.
class RoomExitTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  CONNECT_ROOM_JS = <<~JS.freeze
    const anchor = document.querySelector('[data-testid="stage"], .lk-viewer');
    const fiberKey = anchor && Object.keys(anchor).find((k) => k.startsWith('__reactFiber$'));
    let room = null;
    for (let fiber = fiberKey && anchor[fiberKey]; fiber && !room; fiber = fiber.return) {
      const value = fiber.memoizedProps && fiber.memoizedProps.value;
      if (value && value.remoteParticipants instanceof Map && value.localParticipant) room = value;
    }
    if (!room) return 'room introuvable';
    if (room.state !== 'disconnected') return 'connexion en cours : ' + room.state;
    room.setAndEmitConnectionState('connected');
    room.emit('connected');
    return 'ok';
  JS

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(title: "Café IA #7", starts_at: 1.hour.ago, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: 1.hour.ago)
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    @prev_egress = Rails.configuration.x.egress_client_factory
    @prev_room   = Rails.configuration.x.room_service_client_factory
    egress, room = egress_stub, room_stub
    Rails.configuration.x.egress_client_factory       = -> { egress }
    Rails.configuration.x.room_service_client_factory = -> { room }
  end

  teardown do
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @saved_env[k] }
    Rails.configuration.x.egress_client_factory       = @prev_egress
    Rails.configuration.x.room_service_client_factory = @prev_room
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "animateur : après « Quitter », l'écran dit où en sont le direct et l'enregistrement, et permet de terminer" do
    sign_in_host
    visit stage_webinar_path(slug: @webinar.slug)
    join_from_prejoin
    leave_room

    assert_selector "[data-testid='room-exit'] h2", text: "Vous avez quitté la salle"
    assert_selector "[data-testid='room-exit-live']", text: "en cours"
    assert_selector "[data-testid='room-exit-recording']", text: "en cours"
    assert_selector "[data-testid='room-exit-rejoin']", text: "Rejoindre à nouveau"
    assert_no_text "Disconnected"

    click_on "Terminer le direct"
    sleep 0.6 # au-delà de la garde anti double-clic (500 ms)
    click_on "Confirmer la fin du direct ?"

    assert_selector "[data-testid='room-exit-live']", text: "terminé", wait: 10
    assert_selector "[data-testid='room-exit-recording']", text: "arrêté", wait: 10
    assert_no_selector "[data-testid='state-button']"
    assert_equal "ended", @webinar.reload.state
  end

  test "« Rejoindre à nouveau » ramène au choix des périphériques" do
    sign_in_host
    visit stage_webinar_path(slug: @webinar.slug)
    join_from_prejoin
    leave_room

    click_on "Rejoindre à nouveau"

    assert_selector "[data-testid='prejoin']", wait: 10
  end

  test "intervenant : écran de sortie sans bouton de fin du direct" do
    speaker = @webinar.speakers.create!(name: "Basile")
    # Accord à l'image déjà donné (participant_consent_test couvre la fenêtre).
    ParticipantConsent.grant!(speaker, recording: true, excerpts: false, adult: true)
    visit join_webinar_path(slug: @webinar.slug, t: speaker.token)
    join_from_prejoin
    leave_room

    assert_selector "[data-testid='room-exit'] h2", text: "Vous avez quitté la salle"
    assert_selector "[data-testid='room-exit-live']", text: "en cours"
    assert_selector "[data-testid='room-exit-recording']", text: "en cours"
    assert_no_selector "[data-testid='state-button']"
  end

  test "spectateur : écran de sortie avec l'état du direct et de l'enregistrement" do
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    @webinar.recordings.create!(status: "recording", egress_id: "EG_live", started_at: 1.minute.ago)
    assert_selector ".lk-viewer", wait: 10
    leave_room

    assert_selector "[data-testid='room-exit'] h2", text: "Vous avez quitté la salle"
    assert_selector "[data-testid='room-exit-live']", text: "en cours"
    assert_selector "[data-testid='room-exit-recording']", text: "en cours"
    assert_no_selector "[data-testid='state-button']"
  end

  test "échec de la connexion initiale : la scène reste, avec un avis en français" do
    sign_in_host
    visit stage_webinar_path(slug: @webinar.slug)
    join_from_prejoin

    assert_selector "[data-testid='connection-notice']", text: "Connexion impossible", wait: 10
    assert_no_selector "[data-testid='room-exit']"
    assert_no_text "Disconnected"
  end

  private

  def sign_in_host
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: @host.oidc_sub, info: { email: @host.email }
    )
    visit "/auth/pocket_id/callback"
  end

  def join_from_prejoin
    assert_selector "[data-testid='prejoin']", wait: 10
    fill_in "username", with: "Marc" if has_field?("username", with: "")
    find(".lk-join-button:not([disabled])", wait: 10).click
    assert_selector "[data-testid='stage']", wait: 10
  end

  # Connexion simulée une fois l'échec réseau constaté, puis clic réel sur
  # « Quitter ».
  def leave_room
    result = nil
    25.times do
      result = evaluate_script("(() => { #{CONNECT_ROOM_JS} })()")
      break if result == "ok"
      sleep 0.4
    end
    assert_equal "ok", result, "Room non repassée à connectée"
    find(".lk-disconnect-button").click
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
    def stub.remove_participant(room:, identity:) = {}
    stub
  end
end
