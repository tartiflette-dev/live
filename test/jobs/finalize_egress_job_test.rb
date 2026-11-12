# frozen_string_literal: true

require "test_helper"

# Seul un état terminal SERVEUR clôt un enregistrement, et le
# chemin final est celui que LiveKit a écrit — borné au préfixe réservé.
class FinalizeEgressJobTest < ActiveJob::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.hour.ago, host_sub: "sub-marc")
    @prefix = "#{@webinar.slug}/speaker-1-camera-0b7c"
    @track = @webinar.recordings.create!(kind: :track, status: :stopping, egress_id: "EG_t", track_sid: "TR_c",
      participant_identity: "speaker-1", track_source: "camera", output_prefix: @prefix)
  end

  def info(egress_id: "EG_t", status: "EGRESS_COMPLETE", files: [ "/data/#{@prefix}.webm" ], room: @webinar.room_name, track: nil)
    { "egress_id" => egress_id, "room_name" => room, "status" => status,
      "file_results" => files.map { |f| { "filename" => f } }, "track" => track }.compact
  end

  test "egress terminé avec le fichier attendu → done + chemin natif (.webm)" do
    FinalizeEgressJob.perform_now(info)

    @track.reload
    assert_equal "done", @track.status
    assert_equal "#{@prefix}.webm", @track.path
    assert @track.completion_received_at
  end

  test "fichier hors du préfixe réservé → failed, chemin jamais adopté" do
    FinalizeEgressJob.perform_now(info(files: [ "/data/autre-webinaire/vol.mp4" ]))

    @track.reload
    assert_equal "failed", @track.status
    assert_nil @track.path
  end

  test "egress en échec côté serveur → failed avec motif" do
    FinalizeEgressJob.perform_now(info(status: "EGRESS_FAILED", files: []))

    assert_equal "failed", @track.reload.status
    assert_match(/failed/, @track.error_message)
  end

  test "réponse de démarrage perdue : rattachement par track_sid + préfixe exact" do
    orphan = @webinar.recordings.create!(kind: :track, status: :starting, track_sid: "TR_m",
      participant_identity: "speaker-1", track_source: "microphone", output_prefix: "#{@webinar.slug}/m")
    track = { "track_id" => "TR_m", "file" => { "filepath" => "/data/#{@webinar.slug}/m" } }

    FinalizeEgressJob.perform_now(info(egress_id: "EG_m", files: [ "/data/#{@webinar.slug}/m.ogg" ], track: track))

    orphan.reload
    assert_equal "EG_m", orphan.egress_id
    assert_equal "done", orphan.status
    assert_equal "#{@webinar.slug}/m.ogg", orphan.path
  end

  # Après une reprise, une piste a un Recording par
  # tentative. La fin tardive de la PREMIÈRE (réponse de démarrage perdue)
  # lui revient, avec son fichier — la plus récente ne la masque pas.
  test "réponse de démarrage perdue sur une piste enregistrée de nouveau : la fin tardive revient à sa tentative" do
    first = @webinar.recordings.create!(kind: :track, status: :failed, track_sid: "TR_m", started_at: 1.hour.ago,
      participant_identity: "speaker-1", track_source: "microphone", output_prefix: "#{@webinar.slug}/m-1")
    retry_rec = @webinar.recordings.create!(kind: :track, status: :starting, track_sid: "TR_m", started_at: 1.minute.ago,
      participant_identity: "speaker-1", track_source: "microphone", output_prefix: "#{@webinar.slug}/m-2")
    track = { "track_id" => "TR_m", "file" => { "filepath" => "/data/#{@webinar.slug}/m-1" } }

    FinalizeEgressJob.perform_now(info(egress_id: "EG_m1", files: [ "/data/#{@webinar.slug}/m-1.ogg" ], track: track))

    assert_equal [ "EG_m1", "done", "#{@webinar.slug}/m-1.ogg" ], first.reload.values_at(:egress_id, :status, :path)
    assert_equal [ nil, "starting" ], retry_rec.reload.values_at(:egress_id, :status)
  end

  test "préfixe divergent sur un orphelin → ignoré" do
    orphan = @webinar.recordings.create!(kind: :track, status: :starting, track_sid: "TR_m",
      participant_identity: "speaker-1", track_source: "microphone", output_prefix: "#{@webinar.slug}/m")
    track = { "track_id" => "TR_m", "file" => { "filepath" => "/data/ailleurs/m" } }

    FinalizeEgressJob.perform_now(info(egress_id: "EG_m", track: track))

    assert_equal "starting", orphan.reload.status
    assert_nil orphan.egress_id
  end

  # Fin de composite côté
  # LiveKit (EGRESS_COMPLETE / FAILED / ABORTED) → cascade des pistes
  # si la fenêtre est fermée. Sans ça, un composite en draft qui
  # expire ou plante côté serveur laisserait tourner les pistes
  # jusqu'à `end_live`, qui peut ne jamais venir.
  class FakeTrackClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def stop(egress_id:)
      @calls << [ :stop, egress_id ]
      { egress_id: egress_id, status: :ending, files: [] }
    end
  end

  test "composite EGRESS_FAILED en draft avec pistes actives → pistes cascade en stopping" do
    @webinar.update!(state: "draft", started_at: nil)
    composite = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_comp",
                                             started_at: Time.current, path: "#{@webinar.slug}/c.mp4")
    @track.update!(status: :recording)
    previous_factory = Rails.configuration.x.egress_client_factory
    fake = FakeTrackClient.new
    Rails.configuration.x.egress_client_factory = -> { fake }

    FinalizeEgressJob.perform_now(
      "egress_id" => composite.egress_id, "room_name" => @webinar.room_name,
      "status" => "EGRESS_FAILED", "file_results" => []
    )

    assert_equal "failed", composite.reload.status
    assert_equal "stopping", @track.reload.status
    assert_includes fake.calls, [ :stop, "EG_t" ]
  ensure
    Rails.configuration.x.egress_client_factory = previous_factory
  end

  test "composite EGRESS_COMPLETE en live → pistes intactes (fenêtre encore ouverte)" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    composite = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_comp",
                                             started_at: Time.current, path: "#{@webinar.slug}/c.mp4")
    @track.update!(status: :recording)
    previous_factory = Rails.configuration.x.egress_client_factory
    fake = FakeTrackClient.new
    Rails.configuration.x.egress_client_factory = -> { fake }

    FinalizeEgressJob.perform_now(
      "egress_id" => composite.egress_id, "room_name" => @webinar.room_name,
      "status" => "EGRESS_COMPLETE", "file_results" => [ { "filename" => "/data/#{composite.path}" } ]
    )

    assert_equal "done", composite.reload.status
    assert_equal "recording", @track.reload.status
    refute fake.calls.any? { |c| c[0] == :stop && c[1] == "EG_t" }
  ensure
    Rails.configuration.x.egress_client_factory = previous_factory
  end

  test "room inconnue ou rejeu après clôture → aucun effet" do
    FinalizeEgressJob.perform_now(info(room: "inconnue"))
    assert_equal "stopping", @track.reload.status

    FinalizeEgressJob.perform_now(info)
    completed_at = @track.reload.completion_received_at
    FinalizeEgressJob.perform_now(info(status: "EGRESS_FAILED", files: []))

    assert_equal "done", @track.reload.status
    assert_equal completed_at, @track.completion_received_at
  end
end
