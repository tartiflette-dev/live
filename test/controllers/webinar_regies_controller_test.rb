require "test_helper"

# Régie : même périmètre que la scène :
# animation du webinaire (propriétaire, co-animateur invité) ; les autres
# reçoivent 404, l'anonyme est renvoyé à la connexion.
class WebinarRegiesControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  class FakeRoom
    attr_accessor :metadata, :participants, :error

    def initialize
      @metadata = '{"spotlight":"speaker-1"}'
      @participants = [
        { identity: "host-sub-owner", kind: "STANDARD", name: "Marc", permission: { can_publish: true },
          tracks: [ { sid: "TR_cam", source: "CAMERA" } ] },
        { identity: "viewer-2", kind: "STANDARD", name: "Ana", permission: { can_publish: false }, tracks: [] },
        { identity: "agent-AJ_x", kind: "AGENT", name: "", permission: { can_publish: true }, tracks: [] }
      ]
    end

    def room_metadata(room:)
      raise error if error

      metadata
    end

    def list_participants(room:)
      raise error if error

      participants
    end
  end

  setup do
    @owner = User.create!(email: "owner@example.test", oidc_sub: "sub-owner")
    @guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co", email_verified: true, email_verified_for: "co@partenaire.test")
    @stranger = User.create!(email: "autre@example.test", oidc_sub: "sub-autre")
    @webinar = Webinar.create!(title: "Café IA #8", starts_at: 1.hour.from_now, host_sub: @owner.oidc_sub)
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @room = FakeRoom.new
    @old_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @room }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @old_factory
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "anonyme : renvoyé à la connexion, page comme statut" do
    get webinar_regie_path(@webinar)
    assert_redirected_to sign_in_path

    get status_webinar_regie_path(@webinar)
    assert_redirected_to sign_in_path
  end

  test "connecté sans rôle d'animation : 404, page comme statut" do
    sign_in_as(@stranger)

    get webinar_regie_path(@webinar)
    assert_response :not_found

    get status_webinar_regie_path(@webinar)
    assert_response :not_found
  end

  test "intervenant (jeton t) sans session : jamais la régie" do
    speaker = @webinar.speakers.create!(name: "Basile")

    get webinar_regie_path(@webinar, t: speaker.token)
    assert_redirected_to sign_in_path
  end

  test "propriétaire : page sous le chrome undust, sans salle LiveKit, commandes branchées" do
    sign_in_as(@owner)

    get webinar_regie_path(@webinar)

    assert_response :success
    assert_select "body.chrome"
    assert_select "#livekit-room", count: 0
    assert_select "#regie[data-slug=?][data-state=?]", @webinar.slug, "draft"
    assert_select "#regie[data-status-url=?]", status_webinar_regie_path(@webinar)
    assert_select "#regie[data-go-live-url=?][data-end-url=?][data-resume-url=?]",
                  go_live_webinar_path(@webinar), end_webinar_path(@webinar), resume_webinar_path(@webinar)
    assert_select "#regie[data-recording-start-url=?]", webinar_recordings_path(@webinar, format: :json)
    assert_select "#regie[data-hand-raises-url=?]", webinar_hand_raises_path(@webinar)
    assert_select "#regie[data-spotlight-url=?]", webinar_spotlight_path(@webinar)
    assert_select "#regie[data-participants-url=?]", "#{webinar_path(@webinar)}/participants"
    assert_select "#regie[data-share-link-regeneration-url=?]", webinar_share_link_regeneration_path(@webinar)
    assert_select "#regie[data-message-moderation-url=?]", "#{webinar_path(@webinar)}/messages"
    assert_select "#regie[data-stage-url=?]", stage_webinar_path(slug: @webinar.slug)
    assert_select "#regie[data-attendance-url=?]", attendance_webinar_registrations_path(@webinar)
    assert_select "#regie[data-room-presence-url=?]", webinar_room_presence_path(@webinar)
  end

  test "co-animateur invité : la régie lui est ouverte" do
    sign_in_as(@guest)

    get webinar_regie_path(@webinar)
    assert_response :success
    # Liste des inscrits (PII) : pas pour le co-animateur invité.
    assert_select "#regie[data-attendance-url]", count: 0
    assert_select "#regie[data-room-presence-url]", count: 0

    get status_webinar_regie_path(@webinar)
    assert_response :success
  end

  test "animateur du projet (project_host) sans lien avec ce webinaire : la régie lui est ouverte" do
    project_host = User.create!(email: "projet@example.test", oidc_sub: "sub-projet", admin: true)
    assert project_host.project_host?
    sign_in_as(project_host)

    get webinar_regie_path(@webinar)
    assert_response :success

    get status_webinar_regie_path(@webinar)
    assert_response :success
  end

  # Contrat du JSON lu par regie.jsx (et par les consoles Sondages / Q&R qui
  # s'y brancheront) : liste blanche figée, rien de plus ne doit fuir.
  test "statut : clés de premier niveau et d'une personne sur scène figées" do
    sign_in_as(@owner)

    get status_webinar_regie_path(@webinar)

    body = response.parsed_body
    assert_equal %w[camera_health ended_at live_since on_stage participants present room share_link_fingerprint spotlight
                    starts_at state transcription_interrupted_since], body.keys.sort
    assert_equal %w[alerts fallbacks measured], body["camera_health"].keys.sort
    assert_equal %w[awaiting_consent camera identity name screen_share], body["on_stage"].first.keys.sort
    assert_equal %w[identity microphone name role], body["participants"].first.keys.sort
  end

  test "statut : état du direct, début, présents humains, scène et mise en avant" do
    @webinar.update!(state: "live", started_at: Time.zone.parse("2026-10-31T09:00:00Z"))
    sign_in_as(@owner)

    get status_webinar_regie_path(@webinar)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert_equal "live", body["state"]
    assert_equal Time.zone.parse("2026-10-31T09:00:00Z"), Time.zone.parse(body["live_since"])
    assert_equal "open", body["room"]
    assert_equal 2, body["present"]
    assert_equal "speaker-1", body["spotlight"]
    assert_equal [ { "identity" => "host-sub-owner", "name" => "Marc", "camera" => true, "screen_share" => false,
                     "awaiting_consent" => false } ],
                 body["on_stage"]
    assert_equal [ { "identity" => "viewer-2", "name" => "Ana", "role" => "viewer", "microphone" => false } ],
                 body["participants"]
  end

  test "statut d'un direct terminé : début et fin, pour le bilan de la régie" do
    @webinar.update!(state: "ended", started_at: Time.zone.parse("2026-11-10T08:30:00Z"),
                     ended_at: Time.zone.parse("2026-11-10T09:31:00Z"))
    sign_in_as(@owner)

    get status_webinar_regie_path(@webinar)

    body = response.parsed_body
    assert_equal "ended", body["state"]
    assert_equal Time.zone.parse("2026-11-10T08:30:00Z"), Time.zone.parse(body["live_since"])
    assert_equal Time.zone.parse("2026-11-10T09:31:00Z"), Time.zone.parse(body["ended_at"])
  end

  test "statut : caméra émise sous 720p depuis plus de 15 s, avec raison et encodeur" do
    sign_in_as(@owner)
    travel_to Time.zone.parse("2026-11-10T09:00:00Z") do
      [ 20, 10, 0 ].each do |seconds_ago|
        @webinar.camera_samples.create!(participant_identity: "speaker-14", top_width: 320, top_height: 180,
                                        quality_limitation_reason: "none", encoder_implementation: "ExternalEncoder",
                                        created_at: seconds_ago.seconds.ago)
      end

      get status_webinar_regie_path(@webinar)
    end

    alert = response.parsed_body.dig("camera_health", "alerts").sole
    assert_equal [ "speaker-14", 320, 180, "none", "ExternalEncoder" ],
                 alert.values_at("identity", "width", "height", "reason", "encoder")
    assert_equal Time.zone.parse("2026-11-10T08:59:40Z"), Time.zone.parse(alert["since"])
  end

  # Le bouton « Régénérer le lien intervenants »
  # suit l'empreinte ; le jeton ne voyage jamais dans un GET de la régie.
  test "lien participants privé : empreinte dans le statut, jeton absent de la page comme du statut" do
    sign_in_as(@guest)

    get status_webinar_regie_path(@webinar)
    assert_nil response.parsed_body.fetch("share_link_fingerprint"), "sans lien actif"

    token = @webinar.generate_share_token!
    get status_webinar_regie_path(@webinar)
    assert_equal @webinar.share_token_fingerprint, response.parsed_body.fetch("share_link_fingerprint")
    assert_not_includes response.body, token

    get webinar_regie_path(@webinar)
    assert_response :success
    assert_not_includes response.body, token
  end

  # Bandeau « Transcription en direct interrompue » de la régie : début de
  # l'absence, seulement une fois le seuil franchi (Webinar::TranscriptionOutage).
  test "statut : transcription interrompue datée du début de l'absence, null avant le seuil" do
    @webinar.update!(state: "live", started_at: 1.hour.ago)
    start = Time.zone.parse("2026-11-10T09:30:00Z")
    sign_in_as(@owner)

    @webinar.transcriber_observed!(:dispatched, at: start)
    get status_webinar_regie_path(@webinar)
    assert_nil response.parsed_body.fetch("transcription_interrupted_since")

    @webinar.transcriber_observed!(:pending, at: start + 3.minutes)
    get status_webinar_regie_path(@webinar)
    assert_equal start, Time.zone.parse(response.parsed_body.fetch("transcription_interrupted_since"))
  end

  test "statut : LiveKit injoignable, l'état du direct reste servi" do
    @room.error = RoomServiceClient::Error.new("connexion refusée")
    sign_in_as(@owner)

    get status_webinar_regie_path(@webinar)

    assert_response :success
    assert_equal "draft", response.parsed_body["state"]
    assert_equal "unavailable", response.parsed_body["room"]
    assert_nil response.parsed_body["present"]
  end

  test "page demandée en JSON : 406, jamais 500" do
    sign_in_as(@owner)

    get webinar_regie_path(@webinar), headers: { "Accept" => "application/json" }
    assert_response :not_acceptable
  end
end
