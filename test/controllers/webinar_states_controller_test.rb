# frozen_string_literal: true

require "test_helper"

# WebinarStatesController.
#
# On assert (3 critères) :
#   • go_live_starts_recording : POST go_live (host) → draft→live +
#     started_at + Recording composite créé via EgressClient (stubbé) ;
#     déjà live/ended → 409, aucun changement.
#   • end_stops_recordings_fail_loud : POST end → live→ended + ended_at +
#     TOUS les Recordings actifs stoppés ; un échec egress = Recording
#     failed + error_message + flash, transition ended s'applique quand
#     même (invariant fail-loud).
#   • public_state_endpoint : GET /w/:slug/state.json (aucune auth) →
#     JSON { state, starts_at, live_since } ; visibility=draft → 404.
class WebinarStatesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include LivekitWebhookSigning

  # ---- Stub EgressClient (duck-type sur start_room_composite / stop) ----
  # Identique en shape à RecordingsControllerTest::StubClient — dupliqué
  # ici volontairement : les deux suites ont leur propre setup et
  # partager le stub introduirait un couplage inter-tests.

  class StubClient
    attr_reader :calls, :behavior

    def initialize(behavior = {})
      @behavior = behavior
      @calls    = []
    end

    def start_room_composite(room_name:, filepath:)
      @calls << [ :start, room_name, filepath ]
      raise @behavior[:start_raise] if @behavior[:start_raise]

      @behavior[:start_result] || { egress_id: "EG_stub", status: :starting, raw: nil }
    end

    def stop(egress_id:)
      @calls << [ :stop, egress_id ]

      if @behavior[:stop_raises]&.key?(egress_id)
        raise @behavior[:stop_raises][egress_id]
      end
      raise @behavior[:stop_raise] if @behavior[:stop_raise]

      { egress_id: egress_id, status: :ending, raw: nil }
    end

    # go_live passe désormais par ensure_active → reconcile → list_egress
    # (review).
    # Le stub doit répondre : par défaut :active (pas de transition) pour
    # ne pas parasiter les tests existants.
    def list_egress(egress_id:)
      @calls << [ :list_egress, egress_id ]
      (@behavior[:list_egress] && @behavior[:list_egress][egress_id]) ||
        { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
  end

  setup do
    @host  = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @other = User.create!(email: "eve@example.com", oidc_sub: "sub-eve")
    @webinar = Webinar.create!(
      title: "Direct alpha", starts_at: 1.hour.from_now, host_sub: @host.oidc_sub
    )

    @root      = Dir.mktmpdir("recordings-root-")
    @prev_root = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = @root

    @prev_room_factory = Rails.configuration.x.room_service_client_factory
    @room_participants = []
    @removed_participants = []
    @list_participants_error = nil
    participants_ref = -> { @room_participants }
    removed_ref = @removed_participants
    error_ref = -> { @list_participants_error }
    room_client = Object.new
    room_client.define_singleton_method(:create_room) { |name:| { name: name } }
    room_client.define_singleton_method(:list_participants) do |room:|
      raise error_ref.call if error_ref.call

      participants_ref.call
    end
    room_client.define_singleton_method(:remove_participant) do |room:, identity:|
      removed_ref << [ room, identity ]
      {}
    end
    # Dispatches du transcripteur nommé (TranscriberPresence).
    @dispatches = []
    dispatches_ref = @dispatches
    room_client.define_singleton_method(:list_agent_dispatches) { |room:| dispatches_ref.dup }
    room_client.define_singleton_method(:create_agent_dispatch) do |room:, agent_name:|
      dispatch = { id: "AD_#{SecureRandom.hex(4)}", agent_name: agent_name,
                   state: { created_at: Time.current.to_i * 1_000_000_000, jobs: [] } }
      dispatches_ref << dispatch
      dispatch
    end
    room_client.define_singleton_method(:delete_agent_dispatch) do |room:, dispatch_id:|
      dispatches_ref.reject! { |dispatch| dispatch[:id] == dispatch_id }
      {}
    end
    @sent_packets = []
    sent_ref = @sent_packets
    room_client.define_singleton_method(:send_data) do |room:, data:, kind:|
      sent_ref << [ room, JSON.parse(data), kind ]
      {}
    end
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

  # ---- Auth animateur (go_live / end exigent une session host) ----

  test "go_live redirects anonymous to sign_in (aucun changement d'état)" do
    post go_live_webinar_path(@webinar)
    assert_redirected_to sign_in_path
    assert_equal "draft", @webinar.reload.state
    assert_nil @webinar.started_at
  end

  test "end redirects anonymous to sign_in (aucun changement d'état)" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    post end_webinar_path(@webinar)
    assert_redirected_to sign_in_path
    assert_equal "live", @webinar.reload.state
  end

  test "go_live non-host → 404 (isolation host_sub)" do
    sign_in_as(@other)
    assert_no_difference -> { Recording.count } do
      post go_live_webinar_path(@webinar)
    end
    assert_response :not_found
    assert_equal "draft", @webinar.reload.state
  end

  test "end non-host → 404 (isolation host_sub)" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    sign_in_as(@other)
    post end_webinar_path(@webinar)
    assert_response :not_found
    assert_equal "live", @webinar.reload.state
  end

  # ---- critère 'go_live_starts_recording' ----

  test "go_live_starts_recording — draft → live + started_at + Recording composite via egress" do
    stub = StubClient.new(start_result: { egress_id: "EG_go", status: :starting, raw: nil })
    install_egress_client(stub)

    sign_in_as(@host)
    freeze = Time.zone.parse("2026-09-21T10:00:00")
    travel_to(freeze) do
      assert_difference -> { Recording.count }, 1 do
        post go_live_webinar_path(@webinar)
      end
    end

    @webinar.reload
    assert_equal "live", @webinar.state
    assert_equal freeze.utc, @webinar.started_at.utc

    rec = Recording.order(:id).last
    assert_equal "starting", rec.status
    assert_equal "EG_go",    rec.egress_id
    assert rec.path.start_with?("#{@webinar.slug}/"), "path: #{rec.path.inspect}"

    kind, room, filepath = stub.calls.first
    assert_equal :start, kind
    assert_equal @webinar.room_name, room
    assert filepath.start_with?("/data/#{@webinar.slug}/"), "filepath: #{filepath}"

    assert_redirected_to webinar_path(@webinar)
  end

  # /stage auto-crée un Recording
  # actif, puis go_live appelait start_composite qui violait
  # only_one_active_composite → flash d'échec à CHAQUE « Démarrer le
  # direct » après visite scène. Fix : go_live utilise ensure_active
  # (idempotent) et réutilise l'actif en place.
  test "chain stage→go_live : aucun doublon, aucun flash d'échec, l'actif est réutilisé" do
    stub = StubClient.new(start_result: { egress_id: "EG_auto", status: :starting, raw: nil })
    install_egress_client(stub)

    # 1) Visite /stage → auto-start → 1 Recording actif créé
    sign_in_as(@host)
    get stage_webinar_path(slug: @webinar.slug)
    assert_response :success
    assert_equal 1, @webinar.recordings.active.composite.count

    active_before = @webinar.recordings.active.composite.first
    egress_id_before = active_before.egress_id

    # 2) Clic « Démarrer le direct » → transition state + réutilisation
    #    de l'actif (jamais 2, jamais flash d'échec).
    assert_no_difference -> { Recording.count }, "ensure_active doit réutiliser l'actif — pas de doublon" do
      post go_live_webinar_path(@webinar)
    end
    @webinar.reload
    assert_equal "live", @webinar.state
    assert_nil flash[:alert], "aucun flash d'échec attendu — vu: #{flash[:alert].inspect}"

    # L'actif reste le MÊME Recording, jamais recréé.
    assert_equal active_before.id, @webinar.recordings.active.composite.first.id
    assert_equal egress_id_before, @webinar.recordings.active.composite.first.egress_id
  end

  test "go_live si déjà live → refus (redirect + flash), state inchangé, aucun Recording créé" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    sign_in_as(@host)

    assert_no_difference -> { Recording.count } do
      post go_live_webinar_path(@webinar)
    end
    # Redirect + flash (plus lisible qu'un 409 muet).
    assert_redirected_to webinar_path(@webinar)
    assert_match(/refusée/i, flash[:alert])
    assert_equal "live", @webinar.reload.state
  end

  test "go_live si ended → refus (redirect + flash)" do
    @webinar.update!(state: "ended", started_at: 2.hours.ago, ended_at: 1.hour.ago)
    sign_in_as(@host)
    post go_live_webinar_path(@webinar)
    assert_redirected_to webinar_path(@webinar)
    assert_match(/refusée/i, flash[:alert])
    assert_equal "ended", @webinar.reload.state
  end

  # Rattrapage : au passage en direct, les
  # pistes publiées avant go_live! doivent être rattrapées. On liste les
  # participants (RoomService) et enqueue StartTrackEgressJob pour chaque
  # piste publiée d'identité autorisée STANDARD.
  test "go_live rattrape les pistes déjà publiées (STANDARD + autorisées)" do
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
      { identity: "EG_recorder", kind: "EGRESS", tracks: [ { sid: "TR_eg", source: "CAMERA" } ] },
      { identity: "host-sub-fantome", kind: "STANDARD", tracks: [ { sid: "TR_f", source: "CAMERA" } ] }
    ]
    sign_in_as(@host)

    assert_enqueued_jobs 2, only: StartTrackEgressJob do
      post go_live_webinar_path(@webinar)
    end
    assert_equal "live", @webinar.reload.state
  ensure
    ENV["TRACK_EGRESS_ENABLED"] = previous
  end

  test "go_live avec échec egress → live QUAND MÊME, Recording failed, flash alert (fail-loud)" do
    stub = StubClient.new(
      start_raise: EgressClient::RemoteError.new("egress start refusé (internal) : nope")
    )
    install_egress_client(stub)

    sign_in_as(@host)
    assert_difference -> { Recording.count }, 1 do
      post go_live_webinar_path(@webinar)
    end
    assert_response :see_other
    assert_match(/nope/, flash[:alert])

    @webinar.reload
    assert_equal "live", @webinar.state
    assert @webinar.started_at.present?

    rec = Recording.order(:id).last
    assert_equal "failed", rec.status
    assert_match(/nope/, rec.error_message)
  end

  # ---- critère 'end_stops_recordings_fail_loud' ----

  test "end_stops_recordings_fail_loud — live → ended + ended_at, tous les Recordings actifs stoppés" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    # Un composite + un track sur le MÊME webinaire : l'invariant
    # « un seul composite actif » n'empêche
    # pas le multi-actif QUAND les kinds diffèrent — stop_all itère
    # toutes les actives (composites + tracks), un pattern testé ici.
    r_recording = Recording.create!(
      webinar: @webinar, status: "recording", egress_id: "EG_a", started_at: 1.minute.ago
    )
    r_starting = Recording.create!(
      webinar: @webinar, status: "starting", kind: "track",
      participant_identity: "speaker-1", track_source: "camera",
      started_at: 30.seconds.ago
    )

    stub = StubClient.new
    install_egress_client(stub)

    sign_in_as(@host)
    freeze = Time.zone.parse("2026-09-21T11:00:00")
    travel_to(freeze) do
      post end_webinar_path(@webinar)
    end

    @webinar.reload
    assert_equal "ended", @webinar.state
    assert_equal freeze.utc, @webinar.ended_at.utc

    assert_equal "done", r_recording.reload.status
    # Piste sans egress_id (démarrage distant pas encore revenu) : l'arrêt
    # reste EN ATTENTE — seul le webhook egress_ended clôt une piste.
    assert_equal "stopping", r_starting.reload.status
    assert_includes stub.calls, [ :stop, "EG_a" ]
    # r_starting n'a pas d'egress_id → client.stop non appelé pour lui
    # (invariant : on ne stoppe pas un egress inconnu côté serveur).
    refute stub.calls.any? { |c| c[0] == :stop && c[1].nil? }

    assert_redirected_to webinar_path(@webinar)
  end

  test "end avec échec partiel → ended appliqué, un Recording failed, un done, flash alert" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    # r_ok = track qui s'arrête proprement, r_bad = composite qui échoue.
    # Deux kinds distincts = 2 actives légitimes sur le même webinaire
    # (invariant unique = kind composite seulement).
    r_ok  = Recording.create!(
      webinar: @webinar, status: "recording", egress_id: "EG_ok",
      kind: "track", participant_identity: "speaker-1", track_source: "camera",
      started_at: 1.minute.ago
    )
    r_bad = Recording.create!(
      webinar: @webinar, status: "recording", egress_id: "EG_bad", started_at: 1.minute.ago
    )

    stub = StubClient.new(
      stop_raises: {
        "EG_bad" => EgressClient::RemoteError.new("egress stop refusé (internal) : twirp500")
      }
    )
    install_egress_client(stub)

    sign_in_as(@host)
    post end_webinar_path(@webinar)

    assert_response :see_other
    assert_match(/twirp500/, flash[:alert])

    @webinar.reload
    assert_equal "ended", @webinar.state
    assert @webinar.ended_at.present?

    # Piste arrêtée : LiveKit répond ENDING, la piste attend egress_ended
    # (fichier final vérifié) avant de passer done — jamais un faux succès.
    assert_equal "stopping", r_ok.reload.status
    assert_includes stub.calls, [ :stop, "EG_ok" ]
    assert_equal "failed", r_bad.reload.status
    assert_match(/twirp500/, r_bad.error_message)
  end

  test "end retire le transcripteur de la salle, et lui seul" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    @room_participants.concat([
      { identity: "host-sub-marc", kind: "STANDARD" },
      { identity: "agent-AJ_testAgent001", kind: "AGENT" },
      { identity: "EG_composite", kind: "EGRESS" },
      { identity: "speaker-7", kind: "STANDARD" }
    ])

    sign_in_as(@host)
    post end_webinar_path(@webinar)

    assert_equal "ended", @webinar.reload.state
    assert_equal [ [ @webinar.room_name, "agent-AJ_testAgent001" ] ], @removed_participants
    assert_equal "Direct terminé.", flash[:notice]
  end

  # Cas réel : direct terminé à 10:30, repris à 10:31 dans la
  # salle restée ouverte, aucun segment archivé pour la reprise : le
  # transcripteur congédié à la fin n'était jamais rappelé.
  test "arrêt puis reprise : le transcripteur est rappelé, la parole des deux périodes est archivée" do
    speaker = @webinar.speakers.create!(name: "Thomas")
    identity = "speaker-#{speaker.id}"
    @room_participants << { identity: identity, kind: "STANDARD" }
    sign_in_as(@host)

    with_transcript_webhook do
      perform_enqueued_jobs(only: TranscriberPresenceJob) { post go_live_webinar_path(@webinar) }
      assert_equal [ "transcriber" ], @dispatches.map { |dispatch| dispatch[:agent_name] }, "dispatché à l'ouverture"
      agent_joins("agent-AJ_ouverture")
      deliver_segment(identity, "Avant la pause.")

      post end_webinar_path(@webinar)
      assert_empty @dispatches, "dispatch supprimé à la fin"
      assert_includes @removed_participants, [ @webinar.room_name, "agent-AJ_ouverture" ]
      @room_participants.reject! { |participant| participant[:kind] == "AGENT" }
      travel 20.seconds
      deliver_segment(identity, "Entre les deux.")

      travel 20.seconds
      # La reprise ouvre un NOUVEAU composite (le stub rendrait le même egress_id).
      install_egress_client(StubClient.new(start_result: { egress_id: "EG_reprise", status: :starting, raw: nil }))
      perform_enqueued_jobs(only: TranscriberPresenceJob) { post resume_webinar_path(@webinar) }
      assert_equal 1, @dispatches.size, "rappelé à la reprise"
      agent_joins("agent-AJ_reprise")
      deliver_segment(identity, "Après la reprise.")
    end

    assert_equal [ "Avant la pause.", "Après la reprise." ], @webinar.transcript_segments.order(:started_at).pluck(:text)
  end

  # Si le rappel du transcripteur échoue (agent arrêté, nom divergent),
  # l'équipe l'apprend pendant le direct : une alerte à 3 min d'absence, une
  # à la clôture, aucune entre les deux (Webinar::TranscriptionOutage).
  test "transcripteur qui ne vient pas : interruption à 3 min, une alerte, close avec le direct" do
    @room_participants << { identity: "host-sub-marc", kind: "STANDARD" }
    sign_in_as(@host)

    with_transcript_webhook do
      perform_enqueued_jobs(only: TranscriberPresenceJob) { post go_live_webinar_path(@webinar) }
      absent_since = @webinar.reload.transcriber_absent_since
      assert absent_since, "absence datée dès la première vérification"

      travel 2.minutes
      assert_no_enqueued_emails { TranscriberPresenceJob.perform_now(@webinar.id) }
      travel 1.minute + 1.second # travel tronque les microsecondes
      assert_enqueued_emails(1) { TranscriberPresenceJob.perform_now(@webinar.id) }
      travel 1.minute
      assert_no_enqueued_emails { TranscriberPresenceJob.perform_now(@webinar.id) }
      assert_equal absent_since, @webinar.reload.transcription_interrupted_since

      ending = { absent_since: absent_since, ended_at: Time.current, reason: "capture_closed" }
      assert_enqueued_email_with TranscriptionOutageMailer, :ended, args: [ @webinar, ending ] do
        post end_webinar_path(@webinar)
      end
    end

    assert_nil @webinar.reload.transcription_interrupted_since
  end

  test "go_live sans personne dans la salle : aucun dispatch, la salle n'est pas créée pour l'agent seul" do
    sign_in_as(@host)

    with_transcript_webhook do
      perform_enqueued_jobs(only: TranscriberPresenceJob) { post go_live_webinar_path(@webinar) }
    end

    assert_equal "live", @webinar.reload.state
    assert_empty @dispatches
  end

  test "end ferme le sondage resté ouvert et en avertit la salle ; sans sondage ouvert, rien n'est diffusé" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    poll = @webinar.polls.create!(position: 1, kind: "choice", label: "A ou B ?", options: %w[A B])
    poll.open!

    sign_in_as(@host)
    post end_webinar_path(@webinar)

    assert_equal "ended", @webinar.reload.state
    assert poll.reload.closed_at
    room, packet, kind = @sent_packets.sole
    assert_equal [ @webinar.room_name, "poll", :reliable ], [ room, packet["topic"], kind ]
    assert_nil packet["poll"], "fermé sans résultat montré : la pop-up disparaît"

    post resume_webinar_path(@webinar)
    post end_webinar_path(@webinar)
    assert_equal 1, @sent_packets.size
  end

  test "end : la fermeture du sondage vient après l'arrêt des enregistrements, et sa panne ne l'empêche pas" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    recording = Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_p", started_at: 1.minute.ago)
    poll = @webinar.polls.create!(position: 1, kind: "choice", label: "A ou B ?", options: %w[A B])
    poll.open!
    stub = StubClient.new
    install_egress_client(stub)
    stopped_before_poll = nil
    failing_close = lambda do |_webinar|
      stopped_before_poll = stub.calls.include?([ :stop, "EG_p" ])
      raise ActiveRecord::StatementInvalid, "base verrouillée (test)"
    end

    sign_in_as(@host)
    original = Poll.method(:close_open_for)
    Poll.define_singleton_method(:close_open_for, &failing_close)
    begin
      post end_webinar_path(@webinar)
    ensure
      Poll.define_singleton_method(:close_open_for, original)
    end

    assert_equal "ended", @webinar.reload.state
    assert stopped_before_poll, "enregistrements arrêtés avant la fermeture du sondage"
    assert_equal "done", recording.reload.status
    assert_equal "Direct terminé.", flash[:notice]
    assert_empty @sent_packets
  end

  test "end : salle sans agent, rien à retirer" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    @room_participants << { identity: "host-sub-marc", kind: "STANDARD" }

    sign_in_as(@host)
    post end_webinar_path(@webinar)

    assert_equal "ended", @webinar.reload.state
    assert_empty @removed_participants
  end

  test "end : LiveKit injoignable au retrait de l'agent → direct terminé quand même, aucune erreur" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    @list_participants_error = RoomServiceClient::RemoteError.new("room list_participants refusé (unavailable)")

    sign_in_as(@host)
    post end_webinar_path(@webinar)

    assert_redirected_to webinar_path(@webinar)
    assert_equal "ended", @webinar.reload.state
    assert_equal "Direct terminé.", flash[:notice]
    assert_empty @removed_participants
  end

  test "end si draft → refus (redirect + flash), aucun changement" do
    sign_in_as(@host)
    post end_webinar_path(@webinar)
    assert_redirected_to webinar_path(@webinar)
    assert_match(/refusée/i, flash[:alert])
    assert_equal "draft", @webinar.reload.state
  end

  test "end si déjà ended → refus (redirect + flash)" do
    @webinar.update!(state: "ended", started_at: 2.hours.ago, ended_at: 1.hour.ago)
    sign_in_as(@host)
    post end_webinar_path(@webinar)
    assert_redirected_to webinar_path(@webinar)
    assert_match(/refusée/i, flash[:alert])
    assert_equal "ended", @webinar.reload.state
  end

  # Sur draft avec un Recording actif orphelin, la
  # transition est vérifiée D'ABORD → aucun stop n'est déclenché avant 409.
  test "end si draft avec Recording actif orphelin → refus SANS toucher aux recordings" do
    orphan = Recording.create!(
      webinar: @webinar, status: "recording", egress_id: "EG_orphan", started_at: 1.minute.ago
    )

    stub = StubClient.new
    install_egress_client(stub)

    sign_in_as(@host)
    post end_webinar_path(@webinar)

    assert_redirected_to webinar_path(@webinar)
    assert_equal "draft", @webinar.reload.state
    # Le Recording orphelin ne doit PAS avoir été stoppé (invariant NB1).
    assert_equal "recording", orphan.reload.status
    assert_empty stub.calls, "aucun appel egress attendu (transition refusée avant stop_all)"
  end

  # ---- Fin par le chemin commun, reprise du direct ----

  test "end planifie la réconciliation différée et le montage des personnes sans piste active" do
    @webinar.update!(state: "live", started_at: 1.hour.ago)
    Recording.create!(webinar: @webinar, kind: "track", status: "done", participant_identity: "speaker-9",
                      track_source: "camera", track_sid: "TR_done", started_at: 1.hour.ago, ended_at: 1.minute.ago)
    Recording.create!(webinar: @webinar, kind: "track", status: "done", participant_identity: "speaker-10",
                      track_source: "camera", track_sid: "TR_done10", started_at: 1.hour.ago, ended_at: 1.minute.ago)
    Recording.create!(webinar: @webinar, kind: "track", status: "recording", participant_identity: "speaker-10",
                      track_source: "microphone", track_sid: "TR_live10", egress_id: "EG_live10", started_at: 1.hour.ago)
    sign_in_as(@host)

    post end_webinar_path(@webinar)

    assert_enqueued_with(job: ReconcileRecordingsJob, args: [ @webinar.id ])
    assert_enqueued_with(job: MuxParticipantJob, args: [ @webinar.id, "speaker-9" ])
    refute enqueued_jobs.any? { |job| job["job_class"] == "MuxParticipantJob" && job["arguments"].last == "speaker-10" },
           "speaker-10 a encore une piste en arrêt : son montage attend son webhook"
  end

  test "resume : ended → live, enregistrements relancés dans un NOUVEAU fichier, ancien intact" do
    @webinar.update!(state: "ended", started_at: 2.hours.ago, ended_at: 10.minutes.ago)
    old = Recording.create!(webinar: @webinar, status: "done", egress_id: "EG_old", path: "#{@webinar.slug}/ancien.mp4",
                            started_at: 2.hours.ago, ended_at: 10.minutes.ago)
    stub = StubClient.new(start_result: { egress_id: "EG_resume", status: :starting, raw: nil })
    install_egress_client(stub)
    sign_in_as(@host)

    assert_difference -> { @webinar.recordings.composite.count }, 1 do
      post resume_webinar_path(@webinar)
    end

    @webinar.reload
    assert_equal "live", @webinar.state
    assert_nil @webinar.ended_at
    fresh = @webinar.recordings.composite.active.sole
    assert_equal "EG_resume", fresh.egress_id
    refute_equal old.path, fresh.path
    assert_equal [ "done", "#{@webinar.slug}/ancien.mp4" ], old.reload.values_at(:status, :path)
    assert_redirected_to webinar_path(@webinar)
    assert_equal "Direct repris.", flash[:notice]
  end

  test "resume rattrape les pistes encore publiées, y compris celles déjà enregistrées avant la fin" do
    previous = ENV["TRACK_EGRESS_ENABLED"]
    ENV["TRACK_EGRESS_ENABLED"] = "true"
    @webinar.update!(state: "ended", started_at: 2.hours.ago, ended_at: 1.minute.ago)
    Recording.create!(webinar: @webinar, kind: "track", status: "done", participant_identity: "host-#{@webinar.host_sub}",
                      track_source: "camera", track_sid: "TR_h_cam", started_at: 2.hours.ago, ended_at: 1.minute.ago)
    @room_participants = [
      { identity: "host-#{@webinar.host_sub}", kind: "STANDARD", tracks: [ { sid: "TR_h_cam", source: "CAMERA" } ] }
    ]
    sign_in_as(@host)

    assert_enqueued_with(job: StartTrackEgressJob, args: [ @webinar.id, "TR_h_cam", "host-#{@webinar.host_sub}", "camera" ]) do
      post resume_webinar_path(@webinar)
    end
  ensure
    ENV["TRACK_EGRESS_ENABLED"] = previous
  end

  test "resume d'un direct en brouillon ou en cours → refus, rien ne démarre" do
    sign_in_as(@host)
    %w[draft live].each do |state|
      @webinar.update!(state: state)
      assert_no_difference -> { Recording.count } do
        post resume_webinar_path(@webinar)
      end
      assert_redirected_to webinar_path(@webinar)
      assert_match(/refusée/i, flash[:alert])
      assert_equal state, @webinar.reload.state
    end
  end

  test "resume : anonyme → sign_in, non-animateur → 404, état inchangé" do
    @webinar.update!(state: "ended", started_at: 2.hours.ago, ended_at: 1.hour.ago)
    post resume_webinar_path(@webinar)
    assert_redirected_to sign_in_path

    sign_in_as(@other)
    post resume_webinar_path(@webinar)
    assert_response :not_found
    assert_equal "ended", @webinar.reload.state
  end

  # ---- critère 'public_state_endpoint' ----

  test "public_state_endpoint — visibility=draft → 404 (aucune fuite)" do
    # visibility default = draft
    get public_webinar_state_path(slug: @webinar.slug)
    assert_response :not_found
  end

  test "public_state_endpoint — published draft (state) → JSON, live_since nil" do
    @webinar.update!(visibility: "published")

    get public_webinar_state_path(slug: @webinar.slug)
    assert_response :success
    assert_match(/application\/json/, response.media_type)

    body = JSON.parse(response.body)
    assert_equal "draft", body["state"]
    assert_equal @webinar.starts_at.iso8601, body["starts_at"]
    assert_nil body["live_since"]
  end

  test "public_state_endpoint — live renvoie live_since iso8601, sans auth" do
    freeze = Time.zone.parse("2026-09-21T10:00:00")
    @webinar.update!(visibility: "published", state: "live", started_at: freeze)

    # Aucune session : la requête doit passer sans redirect.
    get public_webinar_state_path(slug: @webinar.slug)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "live", body["state"]
    assert_equal freeze.iso8601, body["live_since"]
  end

  test "public_state_endpoint — slug inconnu → 404" do
    get public_webinar_state_path(slug: "no-such-webinar")
    assert_response :not_found
  end

  # Non-régression du bug d'ordre `include` /
  # `def self.animateur_browser_policy_options`. Un UA legacy (< :modern)
  # DOIT recevoir 200 sur state.json (endpoint public, hors garde animateur).
  # Test rouge avec l'ancien ordre (allow_browser :modern splaté sans
  # `only:` s'appliquait à `show` → 406) ; vert après le fix.
  test "public_state_endpoint_legacy_user_agent — UA < :modern reçoit 200 JSON" do
    @webinar.update!(visibility: "published", state: "live", started_at: 5.minutes.ago)

    get public_webinar_state_path(slug: @webinar.slug),
        headers: { "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64; rv:78.0) Gecko/20100101 Firefox/78.0" }

    assert_response :success
    assert_match(/application\/json/, response.media_type)
    body = JSON.parse(response.body)
    assert_equal "live", body["state"]
  end

  test "public_state_endpoint — ended renvoie live_since (started_at conservé)" do
    started = Time.zone.parse("2026-09-21T10:00:00")
    @webinar.update!(
      visibility: "published", state: "ended",
      started_at: started, ended_at: started + 1.hour
    )
    get public_webinar_state_path(slug: @webinar.slug)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "ended",           body["state"]
    assert_equal started.iso8601,   body["live_since"]
  end

  private

  def install_egress_client(client)
    Rails.configuration.x.egress_client_factory = -> { client }
  end

  def with_transcript_webhook
    saved = ENV.to_h.slice("TRANSCRIPT_ENABLED", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET")
    ENV.update("TRANSCRIPT_ENABLED" => "true", "LIVEKIT_API_KEY" => LivekitWebhookSigning::WEBHOOK_KEY,
               "LIVEKIT_API_SECRET" => LivekitWebhookSigning::WEBHOOK_SECRET)
    yield
  ensure
    %w[TRANSCRIPT_ENABLED LIVEKIT_API_KEY LIVEKIT_API_SECRET].each { |key| ENV[key] = saved[key] }
  end

  def agent_joins(identity)
    @room_participants << { identity: identity, kind: "AGENT" }
  end

  # Segment tel que l'agent le pousse : parole terminée à l'instant.
  def deliver_segment(identity, text)
    body = { room: @webinar.room_name, segment_id: SecureRandom.uuid, participant: { identity: identity, name: "Thomas" },
             text: text, started_at: 2.seconds.ago.utc.iso8601(3), ended_at: Time.current.utc.iso8601(3) }.to_json
    post "/webhooks/transcripts", params: body,
      headers: { "Content-Type" => "application/json", "Authorization" => signed_authorization(body) }
    assert_response :no_content
  end

  # Identique à RecordingsControllerTest / WebinarsControllerTest#sign_in_as
  # (flow OIDC test_mode, aucun monkey-patch).
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
