# frozen_string_literal: true

require "test_helper"

# Fail-loud et entrelacements : une
# réservation durable par piste (track_sid), aucun verrou tenu pendant le
# réseau, arrêt compensatoire si le direct se termine pendant l'appel.
class TrackRecordingSessionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FakeClient
    attr_reader :calls

    def initialize(start_result: nil, start_raise: nil, stop_result: nil, during_start: nil)
      @start_result = start_result
      @start_raise = start_raise
      @stop_result = stop_result
      @during_start = during_start
      @calls = []
    end

    def start_track_egress(room_name:, track_id:, filepath:)
      @calls << [ :start, room_name, track_id, filepath ]
      @during_start&.call
      raise @start_raise if @start_raise

      @start_result || { egress_id: "EG_#{track_id}", status: :starting, files: [] }
    end

    def stop(egress_id:)
      @calls << [ :stop, egress_id ]
      @stop_result || { egress_id: egress_id, status: :ending, files: [] }
    end
  end

  setup do
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.hour.ago, host_sub: "sub-marc")
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    @speaker = @webinar.speakers.create!(name: "Basile")
    # Ses pistes séparées ne s'enregistrent qu'avec son accord à l'image.
    ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)
    @identity = "speaker-#{@speaker.id}"
  end

  def start(client, sid: "TR_cam1", identity: @identity, source: "camera")
    TrackRecordingSession.start(webinar: @webinar, track_sid: sid, identity: identity, source: source, client: client)
  end

  test "démarrage nominal : Recording track réservé avant l'appel, egress_id persisté" do
    client = FakeClient.new
    recording = start(client)

    assert recording.track?
    assert_equal "recording", recording.reload.status
    assert_equal "EG_TR_cam1", recording.egress_id
    assert_equal @identity, recording.participant_identity
    assert_equal "camera", recording.track_source
    _, room, sid, filepath = client.calls.first
    assert_equal [ @webinar.room_name, "TR_cam1" ], [ room, sid ]
    assert_equal "/data/#{recording.output_prefix}", filepath
    assert_match(%r{\A#{@webinar.slug}/speaker-\d+-camera-[0-9a-f-]{36}\z}, recording.output_prefix)
  end

  test "webhook rejoué pour la même piste → un seul appel distant" do
    client = FakeClient.new
    first = start(client)
    second = start(client)

    assert_equal first.id, second.id
    assert_equal 1, client.calls.count { |c| c[0] == :start }
    assert_equal 1, @webinar.recordings.tracks.count
  end

  # Cas réel : webhook + rattrapage peuvent déclencher
  # start pour la MÊME piste. L'index unique sur track_sid garantit
  # qu'un seul Recording existe et qu'un seul appel distant est fait
  # (le second rescue ActiveRecord::RecordNotUnique).
  # Reprise du direct : une piste toujours publiée,
  # enregistrée avant la fin, repart dans un nouveau fichier.
  test "piste dont l'enregistrement est clos → nouvel enregistrement, l'ancien intact" do
    before = start(FakeClient.new)
    before.update!(status: "done", path: "#{before.output_prefix}.mp4", ended_at: Time.current)
    client = FakeClient.new(start_result: { egress_id: "EG_after_resume", status: :starting, files: [] })

    after = start(client)

    refute_equal before.id, after.id
    assert_equal [ "recording", "EG_after_resume" ], after.reload.values_at(:status, :egress_id)
    refute_equal before.output_prefix, after.output_prefix
    assert_equal "done", before.reload.status
    assert_equal 1, client.calls.count { |c| c[0] == :start }
  end

  test "double déclenchement webhook+rattrapage pour la même piste → un seul egress" do
    client = FakeClient.new
    4.times { start(client, sid: "TR_doublon") }
    assert_equal 1, @webinar.recordings.tracks.where(track_sid: "TR_doublon").count
    assert_equal 1, client.calls.count { |c| c[0] == :start }
  end

  test "échec du démarrage distant → Recording failed lisible, aucune exception" do
    client = FakeClient.new(start_raise: EgressClient::RemoteError.new("egress injoignable"))
    recording = start(client)

    assert_equal "failed", recording.reload.status
    assert_match(/egress injoignable/, recording.error_message)
  end

  test "direct terminé PENDANT l'appel de démarrage → arrêt compensatoire" do
    client = FakeClient.new(during_start: -> { Webinar.find(@webinar.id).update!(state: "ended", ended_at: Time.current) })
    recording = start(client)

    assert_includes client.calls, [ :stop, "EG_TR_cam1" ]
    assert_equal "stopping", recording.reload.status
  end

  test "intervenant révoqué PENDANT l'appel → arrêt compensatoire" do
    client = FakeClient.new(during_start: -> { @speaker.revoke! })
    start(client)

    assert_includes client.calls, [ :stop, "EG_TR_cam1" ]
  end

  test "acteur non autorisé, source inconnue ou direct clos → aucun appel" do
    client = FakeClient.new
    assert_nil start(client, identity: "viewer-999999")
    assert_nil start(client, source: "data")
    assert_nil start(client, sid: "../etc")
    @webinar.update!(state: "ended", ended_at: Time.current)
    assert_nil start(client, sid: "TR_late")

    assert_empty client.calls
    assert_equal 0, Recording.count
  end

  test "accord à l'image : sans accord en cours, aucune piste séparée ; l'animation n'en a pas besoin" do
    ParticipantConsent.current_for(@speaker).withdraw!
    newcomer = @webinar.speakers.create!(name: "Mathilde")
    client = FakeClient.new

    assert_nil start(client, sid: "TR_withdrawn")
    assert_nil start(client, sid: "TR_new", identity: "speaker-#{newcomer.id}")
    assert_equal "recording", start(client, sid: "TR_host", identity: "host-#{@webinar.host_sub}").reload.status

    ParticipantConsent.grant!(newcomer, recording: true, excerpts: false, adult: true)
    assert_equal "recording", start(client, sid: "TR_new2", identity: "speaker-#{newcomer.id}").reload.status
    assert_equal 2, client.calls.count { |c| c[0] == :start }
  end

  test "accord retiré PENDANT l'appel de démarrage → arrêt compensatoire" do
    client = FakeClient.new(during_start: -> { ParticipantConsent.current_for(@speaker).withdraw! })
    recording = start(client)

    assert_equal "stopping", recording.reload.status
    assert_includes client.calls, [ :stop, "EG_TR_cam1" ]
  end

  test "spectateur inscrit confirmé en prise de parole → piste enregistrée ; non confirmé ou autre webinaire → rien" do
    confirmed = @webinar.registrations.create!(name: "Inès", email: "ines@example.com", confirmed_at: Time.current)
    pending = @webinar.registrations.create!(name: "Paul", email: "paul@example.com")
    other = Webinar.create!(title: "Autre", starts_at: 1.hour.ago, host_sub: "sub-eve")
    foreign = other.registrations.create!(name: "Eve", email: "eve@example.com", confirmed_at: Time.current)
    [ confirmed, pending, foreign ].each { |viewer| ParticipantConsent.grant!(viewer, recording: true, excerpts: false, adult: true) }
    client = FakeClient.new

    recording = start(client, sid: "TR_v", identity: "viewer-#{confirmed.id}", source: "microphone")
    assert_equal "recording", recording.reload.status
    assert_nil start(client, sid: "TR_p", identity: "viewer-#{pending.id}")
    assert_nil start(client, sid: "TR_f", identity: "viewer-#{foreign.id}")
    assert_equal 1, client.calls.count { |c| c[0] == :start }
  end

  test "arrêt sans egress_id (démarrage pas revenu) → en attente, aucun appel" do
    recording = @webinar.recordings.create!(kind: :track, status: :starting, track_sid: "TR_x",
      participant_identity: @identity, track_source: "camera", output_prefix: "#{@webinar.slug}/x")
    client = FakeClient.new

    assert_equal :pending, TrackRecordingSession.stop(recording, client: client)
    assert_equal "stopping", recording.reload.status
    assert_empty client.calls
  end

  test "arrêt confirmé ENDING → reste stopping jusqu'à egress_ended" do
    recording = start(FakeClient.new)
    assert_equal :pending, TrackRecordingSession.stop(recording, client: FakeClient.new)
    assert_equal "stopping", recording.reload.status
  end

  # authorized? accepte TOUT animateur (host-<sub>).

  test "authorized_host_proprietaire_fast_path" do
    assert TrackRecordingSession.authorized?(@webinar, "host-#{@webinar.host_sub}")
  end

  test "authorized_host_project_host" do
    admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    assert TrackRecordingSession.authorized?(@webinar, "host-#{admin.oidc_sub}")
  end

  test "authorized_host_guest_host" do
    guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: true, email_verified_for: "jean@partenaire.example.org")
    @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @webinar.host_sub)
    assert TrackRecordingSession.authorized?(@webinar, "host-#{guest.oidc_sub}")
  end

  test "authorized_host_guest_host_refuse_sans_email_verified" do
    guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: false)
    @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @webinar.host_sub)
    assert_not TrackRecordingSession.authorized?(@webinar, "host-#{guest.oidc_sub}")
  end

  test "authorized_host_user_sans_role_refuse" do
    other = User.create!(email: "autre@example.net", oidc_sub: "sub-autre")
    assert_not TrackRecordingSession.authorized?(@webinar, "host-#{other.oidc_sub}")
  end

  test "authorized_host_sub_inconnu_refuse" do
    assert_not TrackRecordingSession.authorized?(@webinar, "host-sub-fantome")
  end

  # ---- Borne d'âge ----

  test "recording_window_open? faux si composite au-delà de RECORDING_WINDOW_MAX_HOURS" do
    @webinar.update!(state: "draft", started_at: nil)
    @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_stale",
                                 started_at: 5.hours.ago)
    assert_not TrackRecordingSession.recording_window_open?(@webinar)
  end

  test "recording_window_open? reste vrai en live même si composite fantôme" do
    @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_stale",
                                 started_at: 5.hours.ago)
    assert TrackRecordingSession.recording_window_open?(@webinar)
  end

  test "RECORDING_WINDOW_MAX_HOURS lu à chaque appel" do
    previous = ENV["RECORDING_WINDOW_MAX_HOURS"]
    @webinar.update!(state: "draft", started_at: nil)
    @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_6h",
                                 started_at: 6.hours.ago)

    ENV["RECORDING_WINDOW_MAX_HOURS"] = "4"
    assert_not TrackRecordingSession.recording_window_open?(@webinar)
    ENV["RECORDING_WINDOW_MAX_HOURS"] = "12"
    assert TrackRecordingSession.recording_window_open?(@webinar)
  ensure
    ENV["RECORDING_WINDOW_MAX_HOURS"] = previous
  end

  test "sweep_stale_composites : no-op quand le direct est en live (jamais marquer failed un composite légitime)" do
    composite = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_live",
                                             started_at: 5.hours.ago)
    client = FakeClient.new

    count = TrackRecordingSession.sweep_stale_composites(@webinar, client: client)

    assert_equal 0, count
    assert_equal "recording", composite.reload.status
    assert_empty client.calls
  end

  test "sweep_stale_composites : hors live, tente stop remote best-effort" do
    @webinar.update!(state: "draft", started_at: nil)
    composite = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_stale_x",
                                             started_at: 5.hours.ago)
    client = FakeClient.new

    TrackRecordingSession.sweep_stale_composites(@webinar, client: client)

    assert_includes client.calls, [ :stop, "EG_stale_x" ]
    assert_equal "failed", composite.reload.status
  end

  test "sweep_stale_composites : erreur distante loguée, composite marqué failed quand même" do
    @webinar.update!(state: "draft", started_at: nil)
    composite = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_boom",
                                             started_at: 5.hours.ago)
    client = FakeClient.new(stop_result: nil)
    # Force une erreur sur stop
    client_err = Class.new do
      def stop(egress_id:); raise EgressClient::Error, "boom"; end
    end.new

    assert_nothing_raised do
      TrackRecordingSession.sweep_stale_composites(@webinar, client: client_err)
    end
    assert_equal "failed", composite.reload.status
    assert_match(/dépassement de durée max/, composite.error_message)
  end

  # Preuve directe : si on autorisait le sweep en
  # live, ensure_active relancerait un second composite en parallèle.
  test "sweep_stale_composites en live : ensure_active NE crée PAS un second egress" do
    composite = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_long",
                                             started_at: 5.hours.ago, path: "#{@webinar.slug}/old.mp4")
    stub_room = Object.new
    def stub_room.create_room(name:); { name: name }; end
    stub_egress = Object.new
    def stub_egress.start_room_composite(**); flunk("ensure_active ne doit PAS redémarrer un egress en live"); end
    def stub_egress.list_egress(egress_id:); { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }; end

    TrackRecordingSession.sweep_stale_composites(@webinar, client: stub_egress)
    result = RecordingSession.ensure_active(@webinar, client: stub_egress, room_client: stub_room)

    assert_equal composite.id, result.id
    assert_equal "recording", composite.reload.status
    assert_equal 1, @webinar.recordings.active.composite.count
  end

  test "sweep_stale_composites marque failed un composite fantôme et cascade l'arrêt des pistes" do
    @webinar.update!(state: "draft", started_at: nil)
    composite = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_stale",
                                              started_at: 5.hours.ago)
    track_client = FakeClient.new
    # Pendant que le composite était « frais » : une piste a été
    # rattrapée. 5 h plus tard, le composite n'a plus confirmé son
    # état → sweep + cascade.
    composite.update!(started_at: Time.current) # tricher pour permettre start
    track = start(track_client, sid: "TR_sw", identity: "host-#{@webinar.host_sub}")
    composite.update!(started_at: 5.hours.ago)
    assert_equal "recording", track.reload.status

    count = TrackRecordingSession.sweep_stale_composites(@webinar, client: track_client)

    assert_equal 1, count
    assert_equal "failed", composite.reload.status
    assert_match(/dépassement de durée max/, composite.error_message)
    assert_equal "stopping", track.reload.status
    assert_includes track_client.calls, [ :stop, track.egress_id ]
  end

  test "webhook track_published : composite depuis 5 h en draft → fenêtre fermée, aucun job" do
    @webinar.update!(state: "draft", started_at: nil)
    @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_stale",
                                 started_at: 5.hours.ago)
    # Note : ce test valide le prédicat ; le test côté
    # Webhooks::LivekitControllerTest valide le chemin complet.
    client = FakeClient.new
    assert_nil start(client, sid: "TR_late", identity: "host-#{@webinar.host_sub}")
    assert_empty client.calls
  end

  # ---- recording_window_open? ----

  test "recording_window_open? vrai en live" do
    assert TrackRecordingSession.recording_window_open?(@webinar)
  end

  test "recording_window_open? vrai en draft si un composite est actif" do
    @webinar.update!(state: "draft", started_at: nil)
    @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_comp", started_at: Time.current)
    assert TrackRecordingSession.recording_window_open?(@webinar)
  end

  test "recording_window_open? faux en draft sans composite" do
    @webinar.update!(state: "draft", started_at: nil)
    assert_not TrackRecordingSession.recording_window_open?(@webinar)
  end

  test "recording_window_open? faux une fois le composite terminé" do
    @webinar.update!(state: "draft", started_at: nil)
    @webinar.recordings.create!(kind: "composite", status: "done", egress_id: "EG_done", ended_at: Time.current)
    assert_not TrackRecordingSession.recording_window_open?(@webinar)
  end

  # ---- start fenêtre composite seule : piste enregistrée en draft ----

  test "start enregistre en draft dès qu'un composite tourne (fenêtre composite seule)" do
    @webinar.update!(state: "draft", started_at: nil)
    @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_comp", started_at: Time.current)
    client = FakeClient.new

    recording = start(client, sid: "TR_bg", identity: "host-#{@webinar.host_sub}")
    assert recording&.track?
    assert_equal "recording", recording.reload.status
  end

  # ---- backfill — rattrapage des pistes publiées avant la fenêtre ----

  class FakeRoomClient
    attr_reader :calls

    def initialize(participants: [], failure: nil)
      @participants = participants
      @failure = failure
      @calls = []
    end

    def list_participants(room:)
      @calls << [ :list, room ]
      raise @failure if @failure
      @participants
    end
  end

  test "backfill enqueue un StartTrackEgressJob par piste publiée d'identité autorisée" do
    previous = ENV["TRACK_EGRESS_ENABLED"]
    ENV["TRACK_EGRESS_ENABLED"] = "true"
    room_client = FakeRoomClient.new(participants: [
      { identity: "host-#{@webinar.host_sub}", kind: "STANDARD", tracks: [
        { sid: "TR_h_cam", source: "CAMERA" },
        { sid: "TR_h_mic", source: "MICROPHONE" }
      ] },
      { identity: "speaker-#{@speaker.id}", kind: "STANDARD", tracks: [
        { sid: "TR_sp_cam", source: "CAMERA" }
      ] }
    ])

    assert_enqueued_jobs 3, only: StartTrackEgressJob do
      TrackRecordingSession.backfill(@webinar, room_client: room_client)
    end
  ensure
    ENV["TRACK_EGRESS_ENABLED"] = previous
  end

  test "backfill ignore EGRESS / AGENT (participants techniques)" do
    previous = ENV["TRACK_EGRESS_ENABLED"]
    ENV["TRACK_EGRESS_ENABLED"] = "true"
    room_client = FakeRoomClient.new(participants: [
      { identity: "EG_recording", kind: "EGRESS",  tracks: [ { sid: "TR_eg", source: "CAMERA" } ] },
      { identity: "agent-whisper", kind: "AGENT",  tracks: [ { sid: "TR_ag", source: "MICROPHONE" } ] },
      { identity: "svc-ingress",   kind: "INGRESS", tracks: [ { sid: "TR_in", source: "CAMERA" } ] }
    ])

    assert_no_enqueued_jobs only: StartTrackEgressJob do
      TrackRecordingSession.backfill(@webinar, room_client: room_client)
    end
  ensure
    ENV["TRACK_EGRESS_ENABLED"] = previous
  end

  test "backfill ignore un intervenant sans accord à l'image" do
    previous = ENV["TRACK_EGRESS_ENABLED"]
    ENV["TRACK_EGRESS_ENABLED"] = "true"
    newcomer = @webinar.speakers.create!(name: "Mathilde")
    room_client = FakeRoomClient.new(participants: [
      { identity: "speaker-#{newcomer.id}", kind: "STANDARD", tracks: [ { sid: "TR_nc", source: "CAMERA" } ] }
    ])

    assert_no_enqueued_jobs only: StartTrackEgressJob do
      TrackRecordingSession.backfill(@webinar, room_client: room_client)
    end
  ensure
    ENV["TRACK_EGRESS_ENABLED"] = previous
  end

  test "backfill ignore une identité non autorisée" do
    previous = ENV["TRACK_EGRESS_ENABLED"]
    ENV["TRACK_EGRESS_ENABLED"] = "true"
    room_client = FakeRoomClient.new(participants: [
      { identity: "host-sub-fantome", kind: "STANDARD", tracks: [ { sid: "TR_x", source: "CAMERA" } ] },
      { identity: "viewer-999999",    kind: "STANDARD", tracks: [ { sid: "TR_y", source: "MICROPHONE" } ] }
    ])

    assert_no_enqueued_jobs only: StartTrackEgressJob do
      TrackRecordingSession.backfill(@webinar, room_client: room_client)
    end
  ensure
    ENV["TRACK_EGRESS_ENABLED"] = previous
  end

  test "backfill no-op quand la fenêtre d'enregistrement est fermée (draft sans composite)" do
    previous = ENV["TRACK_EGRESS_ENABLED"]
    ENV["TRACK_EGRESS_ENABLED"] = "true"
    @webinar.update!(state: "draft", started_at: nil)
    room_client = FakeRoomClient.new(participants: [
      { identity: "host-#{@webinar.host_sub}", kind: "STANDARD", tracks: [ { sid: "TR_h", source: "CAMERA" } ] }
    ])

    assert_no_enqueued_jobs only: StartTrackEgressJob do
      TrackRecordingSession.backfill(@webinar, room_client: room_client)
    end
    assert_empty room_client.calls
  ensure
    ENV["TRACK_EGRESS_ENABLED"] = previous
  end

  test "backfill tolère un échec distant (best-effort, aucune exception)" do
    previous = ENV["TRACK_EGRESS_ENABLED"]
    ENV["TRACK_EGRESS_ENABLED"] = "true"
    room_client = FakeRoomClient.new(failure: RoomServiceClient::Error.new("boom"))

    assert_nothing_raised do
      TrackRecordingSession.backfill(@webinar, room_client: room_client)
    end
  ensure
    ENV["TRACK_EGRESS_ENABLED"] = previous
  end

  # ---- Fermeture de la fenêtre d'enregistrement ----
  #
  # Avec `recording_window_open? = live? OU composite actif`, l'arrêt du
  # composite en draft DOIT fermer la fenêtre côté piste — sinon une
  # piste rattrapée en draft tournerait jusqu'à `end_live`, qui peut
  # ne jamais venir.

  test "cascade — arrêt du composite en draft stoppe les pistes en cours" do
    @webinar.update!(state: "draft", started_at: nil)
    composite = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_comp", started_at: Time.current)
    track_client = FakeClient.new
    track = start(track_client, sid: "TR_cascade", identity: "host-#{@webinar.host_sub}")
    assert_equal "recording", track.reload.status

    composite_client = FakeClient.new(stop_result: { egress_id: "EG_comp", status: :ending, files: [] })
    RecordingSession.stop(composite, client: composite_client)

    assert_equal "stopping", track.reload.status
    assert_includes composite_client.calls, [ :stop, "EG_comp" ]
    # La cascade a bien demandé l'arrêt remote de la piste.
    assert_includes composite_client.calls, [ :stop, track.egress_id ]
  end

  test "cascade — pas d'arrêt des pistes si le webinaire est encore live après stop composite" do
    composite = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_comp", started_at: Time.current)
    track_client = FakeClient.new
    track = start(track_client, sid: "TR_live", identity: "host-#{@webinar.host_sub}")

    composite_client = FakeClient.new
    RecordingSession.stop(composite, client: composite_client)

    # Direct toujours en cours → fenêtre encore ouverte → piste intacte.
    assert_equal "recording", track.reload.status
    refute composite_client.calls.any? { |c| c[0] == :stop && c[1] == track.egress_id }
  end

  # Course : StartTrackEgressJob/rattrapage en vol pendant l'arrêt. Le
  # pattern existant « Démarrage annulé avant appel distant » + arrêt
  # compensatoire après l'appel distant doit couvrir ces interleavings.

  test "race — fenêtre fermée PENDANT l'appel remote → arrêt compensatoire" do
    @webinar.update!(state: "draft", started_at: nil)
    composite = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_comp", started_at: Time.current)
    # Entre l'appel remote et la re-vérification, le composite s'arrête :
    # l'arrêt compensatoire DOIT être demandé (nouvelle preuve, libellé
    # corrigé — l'ancienne « AVANT l'appel » testait en réalité l'après).
    client = FakeClient.new(during_start: -> {
      composite.update!(status: :done, ended_at: Time.current)
    })

    recording = start(client, sid: "TR_mid", identity: "host-#{@webinar.host_sub}")

    assert recording.persisted?
    assert_includes client.calls, [ :stop, "EG_TR_mid" ]
    assert_equal "stopping", recording.reload.status
  end

  test "race — fenêtre fermée AVANT le claim DB → aucun Recording, aucun appel" do
    @webinar.update!(state: "draft", started_at: nil)
    # Pas de composite actif : fenêtre déjà fermée au moment où le
    # job rattrapage s'exécute (classe de bug : start en concurrence
    # avec un stop qui a déjà convergé).
    client = FakeClient.new

    assert_nil start(client, sid: "TR_too_late", identity: "host-#{@webinar.host_sub}")
    assert_empty client.calls
    assert_equal 0, @webinar.recordings.tracks.count
  end

  # Non-régression : révocation / main baissée pendant la vie d'un
  # egress → l'arrêt côté direct (end_live/stop_all) continue de
  # stopper la piste.

  test "non-régression — stop_all stoppe la piste d'un intervenant révoqué" do
    client = FakeClient.new
    track = start(client, sid: "TR_rev", identity: "speaker-#{@speaker.id}", source: "camera")
    assert_equal "recording", track.reload.status

    @speaker.revoke!
    results = RecordingSession.stop_all(@webinar, client: client)

    stopped = results.find { |r| r[:recording].id == track.id }
    assert_includes [ :ok, :pending ], stopped[:result]
    assert_includes [ "stopping", "done" ], track.reload.status
    assert client.calls.any? { |c| c[0] == :stop && c[1] == track.egress_id }
  end

  test "non-régression — stop_all stoppe la piste d'un spectateur dont la main a été baissée" do
    confirmed = @webinar.registrations.create!(name: "Inès", email: "ines@example.com", confirmed_at: Time.current)
    ParticipantConsent.grant!(confirmed, recording: true, excerpts: false, adult: true)
    client = FakeClient.new
    track = start(client, sid: "TR_vlow", identity: "viewer-#{confirmed.id}", source: "microphone")
    assert_equal "recording", track.reload.status

    results = RecordingSession.stop_all(@webinar, client: client)
    stopped = results.find { |r| r[:recording].id == track.id }
    assert_includes [ :ok, :pending ], stopped[:result]
    assert client.calls.any? { |c| c[0] == :stop && c[1] == track.egress_id }
  end

  # Non-régression : TrackRecordingSession.stop idempotent (cascade +
  # stop_all peuvent se recouper sans doubler l'ordre remote).

  test "non-régression — second stop ne rappelle pas client.stop (idempotence)" do
    client = FakeClient.new
    track = start(client, sid: "TR_idem", identity: "host-#{@webinar.host_sub}")

    TrackRecordingSession.stop(track, client: client)
    stop_calls_after_first = client.calls.count { |c| c[0] == :stop }
    TrackRecordingSession.stop(track, client: client)
    assert_equal stop_calls_after_first, client.calls.count { |c| c[0] == :stop }
  end

  test "backfill désactivé si TRACK_EGRESS_ENABLED absent" do
    previous = ENV["TRACK_EGRESS_ENABLED"]
    ENV["TRACK_EGRESS_ENABLED"] = nil
    room_client = FakeRoomClient.new(participants: [
      { identity: "host-#{@webinar.host_sub}", kind: "STANDARD", tracks: [ { sid: "TR_h", source: "CAMERA" } ] }
    ])

    assert_no_enqueued_jobs only: StartTrackEgressJob do
      TrackRecordingSession.backfill(@webinar, room_client: room_client)
    end
  ensure
    ENV["TRACK_EGRESS_ENABLED"] = previous
  end
end
