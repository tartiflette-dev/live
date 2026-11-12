require "application_system_test_case"

# Pilotage de l'enregistrement depuis la scène
# animateur. Ce test système atteste les invariants OBSERVABLES par
# l'animateur en production :
#
#   1. host sur /w/:slug/stage : statut recording posé côté serveur
#      (indépendant du montage React) ; le pilotage est dans la régie ;
#   2. viewer /w/:slug : AUCUN data-attr recording (host-only strict) ;
#   3. auto-start : après visite /stage, un Recording actif existe (visible
#      dans /recordings.json et /webinars/:id/recordings — canal DB) ;
#   4. auto-start idempotent : 2 visites → 1 seul actif ;
#   5. failure egress : un start ratée laisse un Recording :failed, visible
#      côté /recordings/status.json avec error_message (fail-loud).
#
# Le rendu React du bouton est couvert par le test contrôleur JSON —
# selenium_chrome_headless est trop instable pour asserter la boucle de
# poll fetch (5 s) dans un timing raisonnable. Repli identique à
# stage_state_button_test.rb (voir bandeau).
class StageRecordingControlTest < ApplicationSystemTestCase
  setup do
    @host   = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @other  = User.create!(email: "eve@example.com", oidc_sub: "sub-eve")
    @webinar = Webinar.create!(
      title: "Kick-off Q4", starts_at: 1.day.from_now, host_sub: @host.oidc_sub,
      visibility: "published"
    )
    @prev_egress = Rails.configuration.x.egress_client_factory
    @prev_room   = Rails.configuration.x.room_service_client_factory
    install_stubs(egress: success_egress_stub, room: success_room_stub)
  end

  teardown do
    Rails.configuration.x.egress_client_factory       = @prev_egress
    Rails.configuration.x.room_service_client_factory = @prev_room
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  # done_when 'stage_recording_data_attrs_host_only' (rendu). Depuis
  # la régie, la scène ne garde que le statut (indicateur) ; le
  # démarrage est dans la régie.
  test "host stage : statut d'enregistrement présent, démarrage dans la régie seulement" do
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)

    assert_selector "#livekit-room[data-recording-status-url]",
                    visible: :all
    assert_no_selector "#livekit-room[data-recording-start-url]",
                       visible: :all

    visit webinar_regie_path(@webinar)
    assert_selector "#regie[data-recording-status-url][data-recording-start-url]", visible: :all
  end

  # done_when 'stage_recording_data_attrs_host_only' (viewer).
  test "viewer public /w/:slug NE reçoit PAS les data-attrs recording" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    confirm_viewer_registration(@webinar)

    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "#livekit-room[data-slug]", visible: :all
    assert_no_selector "#livekit-room[data-recording-status-url]", visible: :all
    assert_no_selector "#livekit-room[data-recording-start-url]",  visible: :all
  end

  # done_when 'auto_start_on_stage_entry'.
  test "auto-start : visite stage crée un Recording actif (aucun avant)" do
    assert_equal 0, @webinar.recordings.active.count
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)

    assert_equal 1, @webinar.recordings.active.count,
                 "un Recording actif doit avoir été créé au 1er accès stage"
    rec = @webinar.recordings.active.first
    assert rec.recording? || rec.starting?, "actif attendu ; vu :#{rec.status}"
  end

  # done_when 'auto_start_idempotent'.
  test "auto-start idempotent : 2 visites = 1 seul Recording actif" do
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)
    initial_count = @webinar.recordings.count
    visit stage_webinar_path(slug: @webinar.slug)
    assert_equal initial_count, @webinar.recordings.count,
                 "aucun doublon attendu ; deux Recordings créés = race non protégée"
    assert_equal 1, @webinar.recordings.active.count
  end

  # done_when 'egress_failure_surfaces_in_status_json'.
  test "auto-start : échec egress → Recording failed exposé par /recordings/status.json" do
    install_stubs(egress: failing_egress_stub("egress injoignable : refused"),
                  room:   success_room_stub)
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)

    # Recording persisté en :failed avec error_message (canal fail-loud).
    failed = @webinar.recordings.order(:id).last
    assert_equal "failed", failed.status
    assert_match(/refused/, failed.error_message)

    # Endpoint status.json expose le failure au consommateur <RecordingControl>.
    visit status_webinar_recordings_path(@webinar, format: :json)
    body = page.body
    assert_match(/"status":"failed"/, body)
    assert_match(/refused/, body)
  end

  private

  def install_stubs(egress:, room:)
    Rails.configuration.x.egress_client_factory       = -> { egress }
    Rails.configuration.x.room_service_client_factory = -> { room }
  end

  def success_egress_stub
    stub = Object.new
    def stub.start_room_composite(room_name:, filepath:)
      { egress_id: "EG_ok_#{SecureRandom.hex(3)}", status: :starting, raw: nil }
    end
    def stub.stop(egress_id:)
      { egress_id: egress_id, status: :ending, raw: nil }
    end
    def stub.list_egress(egress_id:)
      { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
    stub
  end

  def failing_egress_stub(message)
    stub = Object.new
    stub.define_singleton_method(:start_room_composite) do |**|
      raise EgressClient::RemoteError, message
    end
    def stub.stop(egress_id:)
      { egress_id: egress_id, status: :ending, raw: nil }
    end
    def stub.list_egress(egress_id:)
      { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
    stub
  end

  def success_room_stub
    stub = Object.new
    def stub.create_room(name:); { name: name }; end
    stub
  end

  # Miroir de RoomReactRenderTest#sign_in_as — flow OIDC test_mode.
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
