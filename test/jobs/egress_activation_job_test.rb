# frozen_string_literal: true

require "test_helper"

# Passage EGRESS_ACTIVE d'une piste : l'instant du premier échantillon écrit
# (EgressInfo.updated_at, en nanosecondes) devient media_started_at, sur
# lequel ParticipantMux recale caméra et micro.
class EgressActivationJobTest < ActiveJob::TestCase
  ACTIVATED_NS = "1793781217172051234" # 2026-11-04 08:33:37.172051234 UTC

  setup do
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.hour.ago, host_sub: "sub-marc")
    @prefix = "#{@webinar.slug}/host-camera-0b7c"
    @track = @webinar.recordings.create!(kind: :track, status: :recording, egress_id: "EG_cam", track_sid: "TR_cam",
      participant_identity: "host-sub-marc", track_source: "camera", output_prefix: @prefix,
      started_at: Time.utc(2026, 11, 4, 8, 33, 35))
  end

  def info(status: "EGRESS_ACTIVE", egress_id: "EG_cam", updated_at: ACTIVATED_NS, track: nil)
    { "egress_id" => egress_id, "room_name" => @webinar.room_name, "status" => status,
      "updated_at" => updated_at, "track" => track }.compact
  end

  test "ACTIVE : media_started_at = updated_at, à la microseconde" do
    EgressActivationJob.perform_now(info)

    assert_equal Time.utc(2026, 11, 4, 8, 33, 37, 172_051), @track.reload.media_started_at
  end

  test "le plus tôt l'emporte : un webhook rejoué ou plus tardif ne recule pas le début, un plus tôt le corrige" do
    EgressActivationJob.perform_now(info)
    EgressActivationJob.perform_now(info(updated_at: "1793781299000000000"))
    assert_equal Time.utc(2026, 11, 4, 8, 33, 37, 172_051), @track.reload.media_started_at

    EgressActivationJob.perform_now(info(updated_at: "1793781217000000000"))
    assert_equal Time.utc(2026, 11, 4, 8, 33, 37), @track.reload.media_started_at
  end

  test "ENDING, horodatage absent ou illisible : rien n'est retenu" do
    EgressActivationJob.perform_now(info(status: "EGRESS_ENDING"))
    EgressActivationJob.perform_now(info(updated_at: nil))
    EgressActivationJob.perform_now(info(updated_at: "0"))
    EgressActivationJob.perform_now(info(updated_at: "bientôt"))

    assert_nil @track.reload.media_started_at
  end

  test "réponse de démarrage perdue : rattachement par piste et préfixe exact" do
    orphan = @webinar.recordings.create!(kind: :track, status: :starting, track_sid: "TR_mic",
      participant_identity: "host-sub-marc", track_source: "microphone", output_prefix: "#{@webinar.slug}/mic")
    track = { "track_id" => "TR_mic", "file" => { "filepath" => "/data/#{@webinar.slug}/mic" } }

    EgressActivationJob.perform_now(info(egress_id: "EG_mic", track: track))

    assert orphan.reload.media_started_at
    assert_nil orphan.egress_id, "l'egress_id reste posé par le démarrage ou la clôture"
  end

  test "egress composite : ignoré, seul le fichier d'une piste est recalé" do
    composite = @webinar.recordings.create!(kind: :composite, status: :recording, egress_id: "EG_room",
      path: "#{@webinar.slug}/room.mp4", started_at: 1.minute.ago)

    EgressActivationJob.perform_now(info(egress_id: "EG_room"))

    assert_nil composite.reload.media_started_at
  end
end
