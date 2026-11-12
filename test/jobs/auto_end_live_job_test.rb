# frozen_string_literal: true

require "test_helper"

# Fin automatique du direct. Chronologie d'un direct réel : tous
# quittent la salle à 10:27:43, LiveKit la ferme à
# 10:28:03 (`room_finished`). Sans « Terminer le direct », le direct restait
# `live` indéfiniment ; un retour dans les 15 min ne doit rien terminer.
class AutoEndLiveJobTest < ActiveJob::TestCase
  class EgressStub
    attr_reader :stopped

    def initialize
      @stopped = []
    end

    def stop(egress_id:)
      @stopped << egress_id
      { egress_id: egress_id, status: :ending, raw: nil }
    end

    def list_egress(egress_id:)
      { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
  end

  class RoomStub
    attr_accessor :participants, :error

    def initialize
      @participants = []
    end

    def list_participants(room:)
      raise error if error

      participants
    end

    def remove_participant(room:, identity:) = {}

    def list_agent_dispatches(room:) = []
  end

  setup do
    @webinar = Webinar.create!(title: "Café IA #7", starts_at: 2.hours.ago, host_sub: "sub-marc",
                               state: "live", started_at: 1.hour.ago)
    @composite = @webinar.recordings.create!(status: "recording", egress_id: "EG_composite", started_at: 1.hour.ago)
    @egress = EgressStub.new
    @room = RoomStub.new
    @prev_egress = Rails.configuration.x.egress_client_factory
    @prev_room = Rails.configuration.x.room_service_client_factory
    egress, room = @egress, @room
    Rails.configuration.x.egress_client_factory = -> { egress }
    Rails.configuration.x.room_service_client_factory = -> { room }
  end

  teardown do
    Rails.configuration.x.egress_client_factory = @prev_egress
    Rails.configuration.x.room_service_client_factory = @prev_room
  end

  test "salle vide depuis 15 min : le direct se termine par le chemin de « Terminer le direct »" do
    @webinar.mark_room_empty!(16.minutes.ago)

    assert_enqueued_with(job: ReconcileRecordingsJob, args: [ @webinar.id ]) do
      AutoEndLiveJob.perform_now(@webinar.id)
    end
    assert_enqueued_with(job: ChapterProposalJob, args: [ @webinar.id ])

    assert_equal "ended", @webinar.reload.state
    assert_equal "done", @composite.reload.status
    assert_equal [ "EG_composite" ], @egress.stopped
  end

  test "un participant revenu dans les 15 min : rien n'est terminé" do
    @webinar.mark_room_empty!(16.minutes.ago)
    @webinar.mark_room_occupied!

    AutoEndLiveJob.perform_now(@webinar.id)

    assert_equal "live", @webinar.reload.state
    assert_equal "recording", @composite.reload.status
  end

  test "revenu puis reparti : seule la dernière vacance compte, l'ancien job ne termine rien" do
    @webinar.mark_room_empty!(16.minutes.ago)
    @webinar.mark_room_occupied!
    @webinar.mark_room_empty!(3.minutes.ago)

    AutoEndLiveJob.perform_now(@webinar.id)

    assert_equal "live", @webinar.reload.state
  end

  test "LiveKit compte encore un humain dans la salle : rien n'est terminé" do
    @webinar.mark_room_empty!(16.minutes.ago)
    @room.participants = [ { identity: "host-sub-marc", kind: "STANDARD" } ]

    AutoEndLiveJob.perform_now(@webinar.id)

    assert_equal "live", @webinar.reload.state
  end

  test "seuls l'enregistreur et le transcripteur restent : le direct se termine" do
    @webinar.mark_room_empty!(16.minutes.ago)
    @room.participants = [ { identity: "EG_composite", kind: "EGRESS" }, { identity: "agent-AJ_1", kind: "AGENT" } ]

    AutoEndLiveJob.perform_now(@webinar.id)

    assert_equal "ended", @webinar.reload.state
  end

  test "refus not_found de LiveKit : la vacance relevée par webhook fait foi" do
    @webinar.mark_room_empty!(16.minutes.ago)
    @room.error = RoomServiceClient::RemoteError.new("room list_participants refusé (not_found)", code: "not_found")

    AutoEndLiveJob.perform_now(@webinar.id)

    assert_equal "ended", @webinar.reload.state
  end

  test "LiveKit injoignable : rien n'est terminé, une seconde vérification est programmée" do
    @webinar.mark_room_empty!(16.minutes.ago)
    @room.error = RoomServiceClient::Error.new("room list_participants échoué (Errno::ECONNREFUSED)")

    freeze_time do
      assert_enqueued_with(job: AutoEndLiveJob, args: [ @webinar.id, true ], at: 5.minutes.from_now) do
        AutoEndLiveJob.perform_now(@webinar.id)
      end
    end
    assert_equal "live", @webinar.reload.state
    assert_equal "recording", @composite.reload.status
  end

  test "LiveKit répond en erreur (unavailable) : présence inconnue, seconde vérification" do
    @webinar.mark_room_empty!(16.minutes.ago)
    @room.error = RoomServiceClient::RemoteError.new("room list_participants refusé (unavailable)", code: "unavailable")

    assert_enqueued_with(job: AutoEndLiveJob, args: [ @webinar.id, true ]) { AutoEndLiveJob.perform_now(@webinar.id) }
    assert_equal "live", @webinar.reload.state
  end

  test "LiveKit toujours injoignable à la seconde vérification : la vacance fait foi" do
    @webinar.mark_room_empty!(21.minutes.ago)
    @room.error = RoomServiceClient::Error.new("room list_participants échoué (Errno::ECONNREFUSED)")

    assert_no_enqueued_jobs(only: AutoEndLiveJob) { AutoEndLiveJob.perform_now(@webinar.id, true) }
    assert_equal "ended", @webinar.reload.state
  end

  test "direct déjà terminé par l'animateur : aucun effet" do
    @webinar.mark_room_empty!(16.minutes.ago)
    @webinar.end!

    assert_no_enqueued_jobs(only: ReconcileRecordingsJob) { AutoEndLiveJob.perform_now(@webinar.id) }
    assert_equal "ended", @webinar.reload.state
  end

  test "schedule programme la vérification 15 min plus tard" do
    freeze_time do
      assert_enqueued_with(job: AutoEndLiveJob, args: [ @webinar.id ], at: 15.minutes.from_now) do
        AutoEndLiveJob.schedule(@webinar)
      end
    end
  end
end
