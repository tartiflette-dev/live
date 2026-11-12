# frozen_string_literal: true

require "test_helper"

# RecordingsController.
#
# EgressClient MOCKÉ via factory injectée (config.x.egress_client_factory).
# On assert :
#   • start/stop pilotent le client mocké et persistent l'egress_id (done_when
#     'start_stop_egress')
#   • listing / start / stop / download refusent un non-host (done_when
#     'recordings_scoped_to_host', 403 spec = 404 ici : révéler l'existence
#     d'un webinaire d'un autre = leak, on rend 404 comme WebinarsController)
#   • un échec egress est visible dans l'UI (flash) + Recording en failed
#     (done_when 'egress_failure_surfaces', invariant fail-loud)
#   • le téléchargement refuse un path forgé (traversal)
class RecordingsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # ---- Stub EgressClient (duck-type sur start_room_composite / stop) ----

  class StubClient
    attr_reader :calls, :behavior

    def initialize(behavior = {})
      @behavior = behavior # keys: :start_result, :start_raise, :stop_raise, :stop_result
      @calls = []
    end

    def start_room_composite(room_name:, filepath:)
      @calls << [ :start, room_name, filepath ]
      raise @behavior[:start_raise] if @behavior[:start_raise]

      @behavior[:start_result] || { egress_id: "EG_stub", status: :starting, raw: nil }
    end

    def stop(egress_id:)
      @calls << [ :stop, egress_id ]
      raise @behavior[:stop_raise] if @behavior[:stop_raise]

      @behavior[:stop_result] || { egress_id: egress_id, status: :ending, raw: nil }
    end

    # RecordingSession.reconcile
    # est appelé par create/status via RecordingsController. Le stub doit
    # répondre — par défaut :active (Recording DB reste inchangé). Un
    # test peut surcharger via `behavior[:list_egress] = { id → payload }`.
    def list_egress(egress_id:)
      @calls << [ :list_egress, egress_id ]
      override = @behavior[:list_egress] && @behavior[:list_egress][egress_id]
      override || { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
  end

  setup do
    @host  = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @other = User.create!(email: "eve@example.com", oidc_sub: "sub-eve")

    @webinar = Webinar.create!(
      title: "Kick-off", starts_at: 1.day.from_now, host_sub: @host.oidc_sub
    )

    # Racine fichiers temporaire (isolation par test — parallelize workers).
    @root = Dir.mktmpdir("recordings-root-")
    @prev_root = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = @root

    # Factory par défaut = client succès. Chaque test peut le remplacer via
    # `install_egress_client(StubClient.new(...))`.
    @prev_room_factory = Rails.configuration.x.room_service_client_factory
    @room_participants = []
    participants_ref = -> { @room_participants }
    room_client = Object.new
    room_client.define_singleton_method(:create_room) { |name:| { name: name } }
    room_client.define_singleton_method(:list_participants) { |room:| participants_ref.call }
    Rails.configuration.x.room_service_client_factory = -> { room_client }
    @prev_factory = Rails.configuration.x.egress_client_factory
    install_egress_client(StubClient.new)
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @prev_room_factory
    Rails.configuration.x.egress_client_factory = @prev_factory
    ENV["RECORDINGS_ROOT"] = @prev_root
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # ---- Auth animateur (les 4 endpoints exigent une session) ----

  test "index redirects anonymous to sign_in" do
    get webinar_recordings_path(@webinar)
    assert_redirected_to sign_in_path
  end

  test "create redirects anonymous to sign_in (no Recording created)" do
    assert_no_difference -> { Recording.count } do
      post webinar_recordings_path(@webinar)
    end
    assert_redirected_to sign_in_path
  end

  test "stop redirects anonymous to sign_in" do
    r = Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_1")
    post stop_webinar_recording_path(@webinar, r)
    assert_redirected_to sign_in_path
  end

  test "download redirects anonymous to sign_in" do
    r = Recording.create!(webinar: @webinar, status: "done", path: "#{@webinar.slug}/x.mp4")
    get download_webinar_recording_path(@webinar, r)
    assert_redirected_to sign_in_path
  end

  # ---- done_when 'recordings_scoped_to_host' ----

  test "recordings_scoped_to_host — non-host gets 404 on index" do
    sign_in_as(@other)
    get webinar_recordings_path(@webinar)
    assert_response :not_found
  end

  test "recordings_scoped_to_host — non-host cannot start recording (404, aucun Recording créé)" do
    sign_in_as(@other)
    assert_no_difference -> { Recording.count } do
      post webinar_recordings_path(@webinar)
    end
    assert_response :not_found
  end

  test "recordings_scoped_to_host — non-host cannot download other's file" do
    r = Recording.create!(webinar: @webinar, status: "done", path: "#{@webinar.slug}/x.mp4")
    FileUtils.mkdir_p(File.join(@root, @webinar.slug))
    File.write(File.join(@root, @webinar.slug, "x.mp4"), "fake")

    sign_in_as(@other)
    get download_webinar_recording_path(@webinar, r)
    assert_response :not_found
  end

  # Cas réel : composite démarré en draft (parcours
  # observé, le webinaire est resté draft) → rattrapage des
  # pistes publiées au moment de l'ouverture de la fenêtre composite.
  test "create — rattrape les pistes déjà publiées en draft (fenêtre composite)" do
    previous = ENV["TRACK_EGRESS_ENABLED"]
    ENV["TRACK_EGRESS_ENABLED"] = "true"
    speaker = @webinar.speakers.create!(name: "Basile")
    ParticipantConsent.grant!(speaker, recording: true, excerpts: false, adult: true)
    @room_participants = [
      { identity: "host-#{@webinar.host_sub}", kind: "STANDARD", tracks: [
        { sid: "TR_h_cam", source: "CAMERA" }
      ] },
      { identity: "speaker-#{speaker.id}", kind: "STANDARD", tracks: [
        { sid: "TR_s_mic", source: "MICROPHONE" }
      ] },
      { identity: "EG_recorder", kind: "EGRESS", tracks: [ { sid: "TR_eg", source: "CAMERA" } ] }
    ]
    sign_in_as(@host)

    assert_enqueued_jobs 2, only: StartTrackEgressJob do
      post webinar_recordings_path(@webinar)
    end
    assert_equal "draft", @webinar.reload.state
  ensure
    ENV["TRACK_EGRESS_ENABLED"] = previous
  end

  # ---- done_when 'start_stop_egress' ----

  test "start_stop_egress — start persiste egress_id et transitionne recording" do
    stub = StubClient.new(start_result: { egress_id: "EG_alpha", status: :starting, raw: nil })
    install_egress_client(stub)

    sign_in_as(@host)
    assert_difference -> { Recording.count }, 1 do
      post webinar_recordings_path(@webinar)
    end
    assert_redirected_to webinar_recordings_path(@webinar)
    follow_redirect!
    assert_response :success

    rec = Recording.order(:id).last
    assert_equal "EG_alpha", rec.egress_id
    # Egress encore EGRESS_STARTING côté livekit : pas de « REC » avant ACTIVE.
    assert_equal "starting", rec.status
    assert rec.started_at.present?
    assert rec.path.start_with?("#{@webinar.slug}/")

    # Client appelé avec room_name = webinar.room_name (SFU) et filepath
    # /data/<slug>/... (préfixe conteneur egress).
    kind, room, filepath = stub.calls.first
    assert_equal :start, kind
    assert_equal @webinar.room_name, room
    assert filepath.start_with?("/data/#{@webinar.slug}/"), "filepath: #{filepath}"
  end

  test "start_stop_egress — stop appelle client avec egress_id et transitionne done" do
    stub = StubClient.new
    install_egress_client(stub)

    r = Recording.create!(webinar: @webinar, status: "recording",
                          egress_id: "EG_beta", started_at: 1.minute.ago)
    sign_in_as(@host)
    post stop_webinar_recording_path(@webinar, r)
    assert_redirected_to webinar_recordings_path(@webinar)

    r.reload
    assert_equal "done", r.status
    assert r.ended_at.present?
    assert_includes stub.calls, [ :stop, "EG_beta" ]
  end

  test "start refuses concurrent recording (une seule active par webinaire)" do
    Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_existing")
    sign_in_as(@host)

    assert_no_difference -> { Recording.count } do
      post webinar_recordings_path(@webinar)
    end
    assert_redirected_to webinar_recordings_path(@webinar)
    # Le flash est le canal officiel (le layout applicatif peut évoluer
    # sans que la garde métier régresse). Test invariant, pas rendu.
    assert_match(/déjà en cours/i, flash[:alert])
  end

  # ---- done_when 'egress_failure_surfaces' (fail-loud) ----

  test "egress_failure_surfaces — start échec = Recording failed + flash alert" do
    stub = StubClient.new(start_raise: EgressClient::RemoteError.new("egress start refusé (internal) : nope"))
    install_egress_client(stub)

    sign_in_as(@host)
    assert_difference -> { Recording.count }, 1 do
      post webinar_recordings_path(@webinar)
    end

    rec = Recording.order(:id).last
    assert_equal "failed", rec.status
    assert_match(/nope/, rec.error_message)
    assert rec.ended_at.present?

    # 303 See Other côté HTTP + flash[:alert] = canal fail-loud (le rendu
    # visuel dépend du layout ; on assert le canal, pas le CSS).
    assert_response :see_other
    assert_match(/Échec démarrage/i, flash[:alert])
    assert_match(/nope/,             flash[:alert])
  end

  test "egress_failure_surfaces — stop échec = Recording failed + flash alert" do
    stub = StubClient.new(stop_raise: EgressClient::RemoteError.new("egress stop refusé (not_found) : unknown"))
    install_egress_client(stub)

    r = Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_x")
    sign_in_as(@host)
    post stop_webinar_recording_path(@webinar, r)

    r.reload
    assert_equal "failed", r.status
    assert_match(/unknown/, r.error_message)
    assert r.ended_at.present?

    assert_response :see_other
    assert_match(/Échec arrêt/i, flash[:alert])
    assert_match(/unknown/,      flash[:alert])
  end

  # ---- Téléchargement : path validé strictement ----

  test "download streams file when path resolves under recordings_root/<slug>/" do
    FileUtils.mkdir_p(File.join(@root, @webinar.slug))
    payload = "M".b + "P4-fake-content".b
    File.write(File.join(@root, @webinar.slug, "ok.mp4"), payload)
    r = Recording.create!(webinar: @webinar, status: "done",
                          path: "#{@webinar.slug}/ok.mp4",
                          ended_at: 1.minute.ago)

    sign_in_as(@host)
    get download_webinar_recording_path(@webinar, r)
    assert_response :success
    assert_equal "video/mp4", response.media_type
    assert_match(/attachment/, response.headers["Content-Disposition"])
  end

  test "download 404 when file missing on disk (chemin non résolu)" do
    r = Recording.create!(webinar: @webinar, status: "done",
                          path: "#{@webinar.slug}/missing.mp4")
    sign_in_as(@host)
    get download_webinar_recording_path(@webinar, r)
    assert_response :not_found
  end

  test "download_rejects_traversal — path forgé ../../etc/passwd → 404" do
    r = Recording.create!(webinar: @webinar, status: "done",
                          path: "#{@webinar.slug}/../../etc/passwd")
    sign_in_as(@host)
    get download_webinar_recording_path(@webinar, r)
    assert_response :not_found
  end

  test "download participant mux file sous _participants/<slug>/" do
    dir = File.join(@root, "_participants", @webinar.slug)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "mux-speaker-7.mp4"), "mux-payload")

    r = Recording.create!(webinar: @webinar, kind: "participant", status: "done",
                          participant_identity: "speaker-7",
                          path: "_participants/#{@webinar.slug}/mux-speaker-7.mp4",
                          ended_at: 1.minute.ago)

    sign_in_as(@host)
    get download_webinar_recording_path(@webinar, r)
    assert_response :success
    assert_equal "video/mp4", response.media_type
    assert_match(/attachment/, response.headers["Content-Disposition"])
    assert_match(/mux-speaker-7\.mp4/, response.headers["Content-Disposition"])
  end

  test "download participant mux .webm (caméra VP8) servi en video/webm" do
    write_file("_participants/#{@webinar.slug}/mux-speaker-7.webm", "mux-vp8")
    r = Recording.create!(webinar: @webinar, kind: "participant", status: "done",
                          participant_identity: "speaker-7", track_source: "camera+microphone",
                          path: "_participants/#{@webinar.slug}/mux-speaker-7.webm",
                          ended_at: 1.minute.ago)

    sign_in_as(@host)
    get download_webinar_recording_path(@webinar, r)

    assert_response :success
    assert_equal "video/webm", response.media_type
  end

  test "index : montage complet affiche vidéo + son et le conteneur, sans réserve" do
    write_file("_participants/#{@webinar.slug}/mux-speaker-7.webm", "mux-vp8")
    track("speaker-7", "camera", path: "#{@webinar.slug}/cam.webm")
    Recording.create!(webinar: @webinar, kind: "participant", status: "done",
                      participant_identity: "speaker-7", track_source: "camera+microphone",
                      path: "_participants/#{@webinar.slug}/mux-speaker-7.webm", ended_at: 1.minute.ago)

    sign_in_as(@host)
    get webinar_recordings_path(@webinar)

    assert_select "[data-participant='speaker-7'] [data-role='participant-mux']", /vidéo \+ son\s*· \.webm/
    assert_select "[data-participant='speaker-7'] [data-role='participant-mux']", { text: /Montage avec réserve/, count: 0 }
  end

  test "index : montage avec réserve (caméra vide) affiche son seul, la réserve et sa raison" do
    write_file("_participants/#{@webinar.slug}/mux-speaker-7.m4a", "mux-audio")
    track("speaker-7", "camera", path: "#{@webinar.slug}/cam.webm")
    Recording.create!(webinar: @webinar, kind: "participant", status: "done",
                      participant_identity: "speaker-7", track_source: "microphone",
                      error_message: "piste camera 4 écartée : aucun paquet video exploitable",
                      path: "_participants/#{@webinar.slug}/mux-speaker-7.m4a", ended_at: 1.minute.ago)

    sign_in_as(@host)
    get webinar_recordings_path(@webinar)

    assert_select "[data-participant='speaker-7'] [data-role='participant-mux']", /son seul/
    assert_select "[data-participant='speaker-7'] [data-role='participant-mux']", /Montage avec réserve/
    assert_select "[data-participant='speaker-7'] [data-role='participant-mux']", /aucun paquet video exploitable/
  end

  test "index : montage complet au calage approximatif — vidéo + son, réserve et raison, pas « partiel »" do
    write_file("_participants/#{@webinar.slug}/mux-speaker-7.mp4", "mux-h264")
    track("speaker-7", "camera", path: "#{@webinar.slug}/cam.mp4")
    Recording.create!(webinar: @webinar, kind: "participant", status: "done",
                      participant_identity: "speaker-7", track_source: "camera+microphone",
                      error_message: "calage lèvres/voix approximatif : instant de début de fichier inconnu (micro (piste 5))",
                      path: "_participants/#{@webinar.slug}/mux-speaker-7.mp4", ended_at: 1.minute.ago)

    sign_in_as(@host)
    get webinar_recordings_path(@webinar)

    mux = "[data-participant='speaker-7'] [data-role='participant-mux']"
    assert_select mux, /vidéo \+ son/
    assert_select mux, /Montage avec réserve/
    assert_select mux, /calage lèvres\/voix approximatif/
    assert_select mux, { text: /partiel/, count: 0 }
  end

  # Répétition puis séance, deux montages d'une personne.
  test "index : plusieurs montages d'une personne, chacun daté du début de ses pistes" do
    rehearsal = Recording.create!(webinar: @webinar, kind: "track", status: "done", participant_identity: "speaker-9",
                                  track_source: "camera", path: "#{@webinar.slug}/r.mp4",
                                  started_at: Time.zone.parse("2026-10-30T09:03:00"), ended_at: Time.zone.parse("2026-10-30T09:09:00"))
    session = Recording.create!(webinar: @webinar, kind: "track", status: "done", participant_identity: "speaker-9",
                                track_source: "camera", path: "#{@webinar.slug}/s.mp4",
                                started_at: Time.zone.parse("2026-10-30T09:31:00"), ended_at: Time.zone.parse("2026-10-30T10:27:00"))
    [ [ rehearsal, "mux-speaker-9.mp4" ], [ session, "mux-speaker-9-20261030-083100.mp4" ] ].each do |track, file|
      write_file("_participants/#{@webinar.slug}/#{file}", "mux")
      Recording.create!(webinar: @webinar, kind: "participant", status: "done", participant_identity: "speaker-9",
                        track_source: "camera", source_track_ids: [ track.id ], started_at: track.ended_at,
                        path: "_participants/#{@webinar.slug}/#{file}", ended_at: track.ended_at)
    end

    sign_in_as(@host)
    get webinar_recordings_path(@webinar)

    assert_select "[data-participant='speaker-9'] [data-role='participant-mux']", count: 2
    assert_select "[data-participant='speaker-9'] [data-role='participant-mux']", /à partir de 30 oct\. 09h03/
    assert_select "[data-participant='speaker-9'] [data-role='participant-mux']", /à partir de 30 oct\. 09h31/
    assert_select "[data-participant='speaker-9'] [data-role='participant-mux-download']", count: 2
  end

  test "index d'un direct terminé : aucun bouton pour démarrer un enregistrement" do
    @webinar.update!(state: "ended", started_at: 1.hour.ago, ended_at: 1.minute.ago)
    sign_in_as(@host)
    get webinar_recordings_path(@webinar)

    assert_select "[data-role='recording-closed']", /Direct terminé/
    assert_select "[data-role='recording-start']", count: 0
  end

  test "create sur un direct terminé → refus, aucun egress lancé (HTML et JSON)" do
    @webinar.update!(state: "ended", started_at: 1.hour.ago, ended_at: 1.minute.ago)
    stub = StubClient.new
    install_egress_client(stub)
    sign_in_as(@host)

    assert_no_difference -> { Recording.count } do
      post webinar_recordings_path(@webinar, format: :json)
      assert_response :conflict
      assert_equal "ended", JSON.parse(response.body)["webinar_state"]

      post webinar_recordings_path(@webinar)
      assert_redirected_to webinar_recordings_path(@webinar)
      assert_match(/reprenez le direct/, flash[:alert])
    end
    refute stub.calls.any? { |c| c[0] == :start }, "aucun egress démarré après la fin du direct"
  end

  test "status.json porte l'état du direct" do
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    assert_equal "draft", JSON.parse(response.body)["webinar_state"]
  end

  test "download — participant kind refuse un path pointant sur un AUTRE webinaire" do
    # Défense en profondeur : même si une anomalie DB (bug, migration
    # bâclée) posait un path forgé qui pointe sur l'arborescence mux
    # d'un AUTRE webinaire, le controller refuse. Le préfixe exigé est
    # construit depuis @webinar.slug — jamais depuis le path.
    other = Webinar.create!(title: "Autre", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    other_dir = File.join(@root, "_participants", other.slug)
    FileUtils.mkdir_p(other_dir)
    File.write(File.join(other_dir, "mux-victim.mp4"), "cible")

    forged = Recording.create!(webinar: @webinar, kind: "participant", status: "done",
                               participant_identity: "speaker-9",
                               path: "_participants/#{other.slug}/mux-victim.mp4")
    sign_in_as(@host)
    get download_webinar_recording_path(@webinar, forged)
    assert_response :not_found
  end

  test "download refuse un participant pointant sur <slug>/ (ancien chemin)" do
    # Garde symétrique : un composite ne peut pas pointer sous
    # participants/, un participant ne peut pas pointer directement
    # sous <slug>/ — mutuellement exclusifs.
    dir = File.join(@root, @webinar.slug)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "mux-ghost.mp4"), "data")

    r = Recording.create!(webinar: @webinar, kind: "participant", status: "done",
                          participant_identity: "speaker-9",
                          path: "#{@webinar.slug}/mux-ghost.mp4")

    sign_in_as(@host)
    get download_webinar_recording_path(@webinar, r)
    assert_response :not_found
  end

  # ---- Listing UI ----

  test "index lists recordings and shows start button when none active" do
    Recording.create!(webinar: @webinar, status: "done",
                      path: "#{@webinar.slug}/past.mp4",
                      ended_at: 1.hour.ago, started_at: 2.hours.ago)
    sign_in_as(@host)
    get webinar_recordings_path(@webinar)
    assert_response :success
    assert_select "[data-role='recording-start']"
  end

  test "index shows stop button when a recording is active" do
    Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_live")
    sign_in_as(@host)
    get webinar_recordings_path(@webinar)
    assert_response :success
    assert_select "[data-role='recording-stop']"
  end

  # ---- Pistes par personne ----

  def track(identity, source, status: "done", path: nil, error: nil)
    Recording.create!(webinar: @webinar, kind: "track", status: status, path: path, error_message: error,
                      participant_identity: identity, track_source: source,
                      started_at: 10.minutes.ago, ended_at: (status == "done" ? 1.minute.ago : nil))
  end

  def write_file(relative, bytes = "x")
    FileUtils.mkdir_p(File.join(@root, File.dirname(relative)))
    File.binwrite(File.join(@root, relative), bytes)
  end

  test "recordings_index_grouped_by_participant — composite puis un bloc nommé par personne" do
    basile = @webinar.speakers.create!(name: "Basile")
    write_file("#{@webinar.slug}/b-cam.mp4", "v" * 2048)
    Recording.create!(webinar: @webinar, status: "done", path: "#{@webinar.slug}/mix.mp4",
                      started_at: 1.hour.ago, ended_at: 10.minutes.ago)
    track("speaker-#{basile.id}", "camera", path: "#{@webinar.slug}/b-cam.mp4")
    track("speaker-#{basile.id}", "microphone", path: "#{@webinar.slug}/b-mic.ogg")
    track("host-#{@host.oidc_sub}", "screen_share", status: "recording")

    sign_in_as(@host)
    get webinar_recordings_path(@webinar)

    assert_response :success
    assert_select "#rec-list + .conteneur-table tbody tr", 1
    assert_select "[data-participant='speaker-#{basile.id}'] h3", "Basile"
    assert_select "[data-participant='speaker-#{basile.id}'] tbody tr", 2
    assert_select "[data-participant='speaker-#{basile.id}'] td", "Caméra"
    assert_select "[data-participant='speaker-#{basile.id}'] td", "Micro"
    assert_select "[data-participant='speaker-#{basile.id}'] td", "2 ko"
    assert_select "[data-participant='speaker-#{basile.id}'] [data-role='recording-download']", 1
    assert_select "[data-participant='host-#{@host.oidc_sub}'] h3", "Animateur"
    assert_select "[data-participant='host-#{@host.oidc_sub}'] td", "Écran partagé"
  end

  test "piste d'un spectateur en prise de parole → bloc à son nom d'inscription" do
    inscrit = @webinar.registrations.create!(name: "Inès", email: "ines@example.com", confirmed_at: Time.current)
    track("viewer-#{inscrit.id}", "microphone", status: "recording")
    sign_in_as(@host)
    get webinar_recordings_path(@webinar)

    assert_select "[data-participant='viewer-#{inscrit.id}'] h3", "Inès (spectateur)"
  end

  test "extraits et shorts : l'accord de chaque personne, dans le tableau et sur son bloc de pistes" do
    camille = @webinar.speakers.create!(name: "Camille")
    mathilde = @webinar.speakers.create!(name: "Mathilde")
    lorenzo = @webinar.speakers.create!(name: "Lorenzo")
    ines = @webinar.registrations.create!(name: "Inès", email: "ines@example.com", confirmed_at: Time.current)
    ParticipantConsent.grant!(camille, recording: true, excerpts: true, adult: true)
    ParticipantConsent.grant!(mathilde, recording: true, excerpts: false, adult: true)
    ParticipantConsent.grant!(ines, recording: true, excerpts: true, adult: true).withdraw!
    track("speaker-#{camille.id}", "camera")
    track("speaker-#{lorenzo.id}", "camera")
    track("host-#{@host.oidc_sub}", "camera")

    sign_in_as(@host)
    get webinar_recordings_path(@webinar)

    assert_response :success
    {
      "speaker-#{camille.id}" => [ "Camille", "allowed", "extraits autorisés" ],
      "speaker-#{mathilde.id}" => [ "Mathilde", "refused", "extraits non autorisés" ],
      "speaker-#{lorenzo.id}" => [ "Lorenzo", "missing", "aucun accord : extraits non autorisés" ],
      "viewer-#{ines.id}" => [ "Inès (spectateur)", "withdrawn", "accord retiré" ],
      "host-#{@host.oidc_sub}" => [ "Animateur", "animation", "animation : couverte par la politique" ]
    }.each do |identity, (name, status, label)|
      assert_select "[data-excerpt-participant='#{identity}'] td", name
      assert_select "[data-excerpt-participant='#{identity}'] [data-role='excerpt-consent'][data-status='#{status}']", label
    end
    assert_select "[data-participant='speaker-#{camille.id}'] [data-role='excerpt-consent']", "extraits autorisés"
    assert_select "[data-participant='speaker-#{lorenzo.id}'] [data-role='excerpt-consent'].etat--ecart"
  end

  test "une piste active ne transforme pas le bouton composite en « Arrêter »" do
    track("host-#{@host.oidc_sub}", "camera", status: "recording")
    sign_in_as(@host)
    get webinar_recordings_path(@webinar)

    assert_select "[data-role='recording-start']"
    assert_select "[data-role='recording-stop']", 0
  end

  test "download_track_recording — type réel de la piste (.ogg, .webm), même garde de chemin" do
    { "ogg" => "audio/ogg", "webm" => "video/webm" }.each do |ext, type|
      write_file("#{@webinar.slug}/piste.#{ext}")
      r = track("speaker-1", "microphone", path: "#{@webinar.slug}/piste.#{ext}")
      sign_in_as(@host)
      get download_webinar_recording_path(@webinar, r)
      assert_response :success
      assert_equal type, response.media_type
    end

    forged = track("speaker-1", "camera", path: "#{@webinar.slug}/../../etc/passwd")
    get download_webinar_recording_path(@webinar, forged)
    assert_response :not_found
  end

  test "track_failure_visible — l'erreur d'une piste s'affiche dans son bloc" do
    track("speaker-9", "camera", status: "failed", error: "Egress terminé en échec (aborted).")
    sign_in_as(@host)
    get webinar_recordings_path(@webinar)

    assert_select "[data-participant='speaker-9'] h3", "speaker-9"
    assert_select "[data-participant='speaker-9'] td", "Egress terminé en échec (aborted)."
  end

  # ---- API JSON pour <RecordingControl> ----

  test "status.json répond `recording: null` quand aucun recording n'existe" do
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    assert_response :success
    payload = JSON.parse(response.body)
    assert_nil payload["recording"], "attendu null, vu #{payload.inspect}"
  end

  test "status.json expose le recording actif + stop_url" do
    Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_live")
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    assert_response :success
    payload = JSON.parse(response.body)
    rec = payload["recording"]
    assert_not_nil rec
    assert_equal "recording", rec["status"]
    assert rec["stop_url"].to_s.include?("/stop"),
           "stop_url attendu sur un recording actif, vu #{rec.inspect}"
  end

  # Priorité à un enregistrement
  # ACTIF (composite d'abord), pas simplement le plus récent. Un
  # `recent_first.first` seul renvoyait parfois une piste `done` plus
  # récente qu'un composite `recording`, éteignant l'indicateur REC
  # pendant l'enregistrement.
  test "status.json priorise un composite recording sur une piste done plus récente" do
    composite = Recording.create!(webinar: @webinar, kind: "composite", status: "recording",
                                   egress_id: "EG_comp", started_at: 10.minutes.ago)
    Recording.create!(webinar: @webinar, kind: "track", status: "done",
                      egress_id: "EG_tr", track_sid: "TR_1", participant_identity: "speaker-1",
                      track_source: "camera", output_prefix: "#{@webinar.slug}/x",
                      started_at: 2.minutes.ago, ended_at: 1.minute.ago,
                      path: "#{@webinar.slug}/x.webm")
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "recording", payload.dig("recording", "status")
    assert_equal composite.id, payload.dig("recording", "id")
    assert payload["participant_recording"], "composite actif → participant_recording true"
  end

  test "status.json expose participant_recording true quand une piste du host tourne (composite done)" do
    Recording.create!(webinar: @webinar, kind: "composite", status: "done",
                      egress_id: "EG_c_done", started_at: 10.minutes.ago, ended_at: 1.minute.ago,
                      path: "#{@webinar.slug}/c.mp4")
    Recording.create!(webinar: @webinar, kind: "track", status: "recording",
                      egress_id: "EG_tr_h", track_sid: "TR_h",
                      participant_identity: "host-#{@host.oidc_sub}",
                      track_source: "camera", output_prefix: "#{@webinar.slug}/h",
                      started_at: 1.minute.ago)
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    assert_response :success
    payload = JSON.parse(response.body)
    assert payload["participant_recording"], "piste host active → participant_recording true"
  end

  # ---- `recording` = composite, jamais une
  # piste ni un montage. ----

  test "status.json : montage participant en cours après le direct → jamais « démarrage » sur le bouton" do
    Recording.create!(webinar: @webinar, kind: "composite", status: "done", egress_id: "EG_c",
                      started_at: 20.minutes.ago, ended_at: 2.minutes.ago, path: "#{@webinar.slug}/c.mp4")
    Recording.create!(webinar: @webinar, kind: "participant", status: "starting",
                      participant_identity: "speaker-7", started_at: 1.minute.ago)
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    payload = JSON.parse(response.body)
    assert_equal "done", payload.dig("recording", "status")
    assert_equal 0, payload["tracks_recording"]
  end

  test "status.json : composite en échec + pistes en cours → composite failed et nombre de pistes, jamais une piste" do
    composite = Recording.create!(webinar: @webinar, kind: "composite", status: "failed", egress_id: "EG_ab",
                                  started_at: 3.minutes.ago, ended_at: 2.minutes.ago,
                                  error_message: "Egress terminé en échec (aborted).")
    %w[camera microphone].each do |source|
      Recording.create!(webinar: @webinar, kind: "track", status: "recording", egress_id: "EG_#{source}",
                        track_sid: "TR_#{source}", participant_identity: "host-#{@host.oidc_sub}",
                        track_source: source, output_prefix: "#{@webinar.slug}/#{source}", started_at: 1.minute.ago)
    end
    Recording.create!(webinar: @webinar, kind: "track", status: "stopping", egress_id: "EG_scr",
                      track_sid: "TR_scr", participant_identity: "speaker-7", track_source: "screen_share",
                      output_prefix: "#{@webinar.slug}/scr", started_at: 30.seconds.ago)
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    payload = JSON.parse(response.body)
    assert_equal composite.id, payload.dig("recording", "id")
    assert_equal "failed", payload.dig("recording", "status")
    assert_nil payload.dig("recording", "stop_url"), "« Arrêter » ne doit jamais viser une piste"
    assert_equal 2, payload["tracks_recording"], "une piste en arrêt n'est plus en captation"
    assert payload["participant_recording"]
  end

  test "status.json : pistes seules (aucun composite) → recording null" do
    speaker = @webinar.speakers.create!(name: "Basile")
    ParticipantConsent.grant!(speaker, recording: true, excerpts: false, adult: true)
    Recording.create!(webinar: @webinar, kind: "track", status: "recording", egress_id: "EG_solo",
                      track_sid: "TR_solo", participant_identity: "speaker-#{speaker.id}", track_source: "camera",
                      output_prefix: "#{@webinar.slug}/solo", started_at: 1.minute.ago)
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    payload = JSON.parse(response.body)
    assert_nil payload["recording"]
    assert_equal 1, payload["tracks_recording"]
  end

  test "status.json : composite starting puis egress ACTIF → recording au poll suivant" do
    install_egress_client(StubClient.new(list_egress: {
      "EG_boot" => { egress_id: "EG_boot", status: :starting, ended_at: 0, error: nil, raw: nil }
    }))
    Recording.create!(webinar: @webinar, status: "starting", egress_id: "EG_boot", started_at: 2.seconds.ago)
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    assert_equal "starting", JSON.parse(response.body).dig("recording", "status")

    install_egress_client(StubClient.new)
    get status_webinar_recordings_path(@webinar, format: :json)
    payload = JSON.parse(response.body)
    assert_equal "recording", payload.dig("recording", "status")
    assert payload.dig("recording", "stop_url").to_s.include?("/stop")
  end

  test "stop.json sur un enregistrement déjà arrêté (second clic) → 409 + état réel, sans redirection" do
    stub = StubClient.new
    install_egress_client(stub)
    r = Recording.create!(webinar: @webinar, status: "done", egress_id: "EG_twice",
                          started_at: 2.minutes.ago, ended_at: 1.second.ago)
    sign_in_as(@host)
    post stop_webinar_recording_path(@webinar, r, format: :json)
    assert_response :conflict
    assert_equal "done", JSON.parse(response.body).dig("recording", "status")
    refute(stub.calls.any? { |call| call.first == :stop }, "aucun second ordre d'arrêt")
  end

  test "status.json expose l'erreur du dernier recording failed (stop_url nil)" do
    Recording.create!(webinar: @webinar, status: "failed",
                      error_message: "egress injoignable (http://x) : refused",
                      ended_at: 1.minute.ago)
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    assert_response :success
    payload = JSON.parse(response.body)
    rec = payload["recording"]
    assert_equal "failed", rec["status"]
    assert_match(/refused/, rec["error_message"])
    assert_nil rec["stop_url"], "aucun stop_url sur un recording failed"
  end

  test "status.json — non-host reçoit 404 (scope host_sub)" do
    sign_in_as(@other)
    get status_webinar_recordings_path(@webinar, format: :json)
    assert_response :not_found
  end

  test "status.json — anonyme redirigé vers sign_in" do
    get status_webinar_recordings_path(@webinar, format: :json)
    assert_redirected_to sign_in_path
  end

  test "create.json démarre et renvoie le payload en :starting (egress pas encore actif)" do
    stub = StubClient.new(start_result: { egress_id: "EG_json", status: :starting, raw: nil })
    install_egress_client(stub)

    sign_in_as(@host)
    assert_difference -> { Recording.count }, 1 do
      post webinar_recordings_path(@webinar, format: :json)
    end
    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "starting", payload.dig("recording", "status")
    assert payload.dig("recording", "stop_url").to_s.include?("/stop")
  end

  test "create.json — deuxième démarrage sur actif = 409 + payload de l'actif" do
    Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_first")
    sign_in_as(@host)
    assert_no_difference -> { Recording.count } do
      post webinar_recordings_path(@webinar, format: :json)
    end
    assert_response :conflict
    payload = JSON.parse(response.body)
    assert_equal "recording", payload.dig("recording", "status")
  end

  test "create.json — échec egress = payload failed + error_message (fail-loud)" do
    stub = StubClient.new(start_raise: EgressClient::RemoteError.new("egress start refusé (internal) : boom"))
    install_egress_client(stub)

    sign_in_as(@host)
    post webinar_recordings_path(@webinar, format: :json)
    # 200 : le payload PORTE l'erreur (jamais un 500 muet côté fail-loud
    # invariant, cf. bandeau service RecordingSession).
    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "failed", payload.dig("recording", "status")
    assert_match(/boom/, payload.dig("recording", "error_message"))
  end

  test "stop.json arrête et renvoie le payload en :done (aucun stop_url)" do
    stub = StubClient.new
    install_egress_client(stub)
    r = Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_stopme")
    sign_in_as(@host)
    post stop_webinar_recording_path(@webinar, r, format: :json)
    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "done", payload.dig("recording", "status")
    assert_nil payload.dig("recording", "stop_url")
  end

  # ---- Auth speaker token ----
  #
  # L'intervenant sur /w/:slug/join?t=<token> doit pouvoir piloter le
  # recording (start/stop/status) SANS session animateur. Le token est
  # re-validé serveur à chaque appel via Webinar.find_for_speaker
  # (invariant re-signature).

  test "create.json — speaker avec token nominatif valide → OK (aucune session)" do
    speaker = @webinar.speakers.create!(name: "Basile")
    stub = StubClient.new(start_result: { egress_id: "EG_speaker", status: :starting, raw: nil })
    install_egress_client(stub)

    # PAS de sign_in_as — juste le token en query param.
    assert_difference -> { Recording.count }, 1 do
      post webinar_recordings_path(@webinar, format: :json), params: { t: speaker.token }
    end
    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "starting", payload.dig("recording", "status")
  end

  test "create.json — un ancien signed_id legacy est désormais refusé" do
    # `Webinar#speaker_token` et le
    # fallback `find_signed` ont été retirés. Un ancien token signé
    # (purpose:speaker) ne résout plus → fallback sign_in.
    legacy_token = @webinar.signed_id(purpose: :speaker)
    post webinar_recordings_path(@webinar, format: :json), params: { t: legacy_token }
    assert_redirected_to sign_in_path
  end

  test "create.json — token invalide + aucune session → redirect sign_in (comportement anonyme)" do
    post webinar_recordings_path(@webinar, format: :json), params: { t: "not-a-real-token" }
    assert_redirected_to sign_in_path
  end

  test "create.json — token d'un AUTRE webinaire → redirect sign_in (find_for_speaker n'apparie pas)" do
    other = Webinar.create!(title: "autre", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    other_speaker = other.speakers.create!(name: "Alice")
    # Le token d'Alice est valide pour `other`, PAS pour `@webinar`.
    post webinar_recordings_path(@webinar, format: :json), params: { t: other_speaker.token }
    assert_redirected_to sign_in_path
  end

  test "stop.json — speaker avec token valide peut arrêter" do
    speaker = @webinar.speakers.create!(name: "Basile")
    stub = StubClient.new
    install_egress_client(stub)
    r = Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_speaker_stop")

    post stop_webinar_recording_path(@webinar, r, format: :json), params: { t: speaker.token }
    assert_response :success
    assert_equal "done", r.reload.status
  end

  test "status.json — speaker avec token valide voit le payload" do
    speaker = @webinar.speakers.create!(name: "Basile")
    Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_speaker_status")
    get status_webinar_recordings_path(@webinar, format: :json), params: { t: speaker.token }
    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "recording", payload.dig("recording", "status")
    # stop_url doit propager le token — l'arrêt côté React n'a pas
    # d'autre credentials (le speaker n'a pas de session).
    assert_match(/[?&]t=#{Regexp.escape(CGI.escape(speaker.token))}/,
                 payload.dig("recording", "stop_url"),
                 "stop_url doit contenir ?t=<token> quand le status est appelé avec un token")
  end

  test "status.json — appelé par host (sans token) : stop_url ne contient PAS de ?t=" do
    Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_host_status")
    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    payload = JSON.parse(response.body)
    assert_no_match(/[?&]t=/, payload.dig("recording", "stop_url").to_s,
                    "un stop_url pour host ne doit pas fuiter de token speaker")
  end

  test "index — speaker token PAS accepté (privilège animateur : lecture des enregistrements)" do
    speaker = @webinar.speakers.create!(name: "Basile")
    get webinar_recordings_path(@webinar), params: { t: speaker.token }
    # Aucune session animateur → redirect sign_in ; token ignoré sur index.
    assert_redirected_to sign_in_path
  end

  test "download — speaker token PAS accepté (privilège animateur)" do
    speaker = @webinar.speakers.create!(name: "Basile")
    r = Recording.create!(webinar: @webinar, status: "done",
                          path: "#{@webinar.slug}/x.mp4", ended_at: 1.minute.ago)
    get download_webinar_recording_path(@webinar, r), params: { t: speaker.token }
    assert_redirected_to sign_in_path
  end

  # ---- Arrêt d'une piste : animateur ou intervenant propriétaire ----

  def track_of(identity, egress_id)
    Recording.create!(webinar: @webinar, kind: "track", status: "recording", egress_id: egress_id,
                      participant_identity: identity, track_source: "camera", started_at: 1.minute.ago)
  end

  test "un intervenant ne peut pas arrêter la piste d'un autre (404, aucun appel)" do
    me    = @webinar.speakers.create!(name: "Basile")
    other = @webinar.speakers.create!(name: "Chloé")
    piste = track_of("speaker-#{other.id}", "EG_other")

    post stop_webinar_recording_path(@webinar, piste, t: me.token)

    assert_response :not_found
    assert_equal "recording", piste.reload.status
    refute_includes @egress_stub.calls, [ :stop, "EG_other" ]
  end

  test "un ancien lien intervenant legacy (signed_id) ne peut rien arrêter" do
    # Le chemin legacy est supprimé :
    # un ancien signed_id ne résout plus en Webinar.find_for_speaker,
    # retombe sur authenticate_animateur! sans session → redirect sign_in.
    piste = track_of("speaker-1", "EG_legacy")
    legacy_token = @webinar.signed_id(purpose: :speaker)

    post stop_webinar_recording_path(@webinar, piste, t: legacy_token)

    assert_redirected_to sign_in_path
    assert_equal "recording", piste.reload.status
  end

  test "l'intervenant propriétaire arrête sa propre piste" do
    me    = @webinar.speakers.create!(name: "Basile")
    piste = track_of("speaker-#{me.id}", "EG_mine")

    post stop_webinar_recording_path(@webinar, piste, t: me.token)

    assert_includes @egress_stub.calls, [ :stop, "EG_mine" ]
    assert_equal "stopping", piste.reload.status
  end

  test "l'animateur arrête n'importe quelle piste" do
    other = @webinar.speakers.create!(name: "Chloé")
    piste = track_of("speaker-#{other.id}", "EG_host")
    sign_in_as(@host)

    post stop_webinar_recording_path(@webinar, piste)

    assert_includes @egress_stub.calls, [ :stop, "EG_host" ]
    assert_equal "stopping", piste.reload.status
  end

  # ---- Réconciliation au status ----

  test "status.json déclenche reconcile → transitionne un Recording actif dont l'egress est complete" do
    stale = Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_stale_status")

    reconciling = Object.new
    reconciling.define_singleton_method(:list_egress) do |egress_id:|
      { egress_id: egress_id, status: :complete, ended_at: 1_690_000_000_000, error: nil, raw: nil }
    end
    install_egress_client(reconciling)

    sign_in_as(@host)
    get status_webinar_recordings_path(@webinar, format: :json)
    assert_response :success

    # Le Recording a été transitionné à done ; le payload reflète l'état
    # POST-réconciliation (status=done, stop_url nil).
    assert_equal "done", stale.reload.status
    payload = JSON.parse(response.body)
    assert_equal "done", payload.dig("recording", "status")
    assert_nil payload.dig("recording", "stop_url")
  end

  test "stop.json — échec egress = payload failed + error_message" do
    stub = StubClient.new(stop_raise: EgressClient::RemoteError.new("egress stop refusé (not_found) : gone"))
    install_egress_client(stub)
    r = Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_bad")
    sign_in_as(@host)
    post stop_webinar_recording_path(@webinar, r, format: :json)
    # 200 (fail-loud dans le payload) OU 303 refus si status inactif —
    # ici le recording était actif donc on entre bien dans le stop → 200.
    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "failed", payload.dig("recording", "status")
    assert_match(/gone/, payload.dig("recording", "error_message"))
  end

  private

  def install_egress_client(client)
    @egress_stub = client
    Rails.configuration.x.egress_client_factory = -> { client }
  end

  # Identique à WebinarsControllerTest#sign_in_as — flow OIDC test_mode
  # (idiomatique Rails, aucun monkey-patch).
  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: { email: user.email }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    get "/auth/pocket_id/callback"
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end
end
