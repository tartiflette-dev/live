# frozen_string_literal: true

require "test_helper"

# Filet planifié par LiveEnding juste après la fin du direct :
# un egress relancé par un démarrage en vol est arrêté.
class ReconcileRecordingsJobTest < ActiveJob::TestCase
  test "arrête un composite relancé après la fin du direct ; webinaire disparu → rien" do
    webinar = Webinar.create!(title: "Café IA #7", starts_at: 2.hours.ago, host_sub: "sub-marc",
                              state: "ended", started_at: 1.hour.ago, ended_at: 1.minute.ago)
    leftover = webinar.recordings.create!(status: "recording", egress_id: "EG_74", started_at: 30.seconds.ago)
    stopped = []
    client = Object.new
    client.define_singleton_method(:list_egress) { |egress_id:| { egress_id: egress_id, status: :active } }
    client.define_singleton_method(:stop) { |egress_id:| stopped << egress_id; { egress_id: egress_id, status: :ending } }
    previous = Rails.configuration.x.egress_client_factory
    Rails.configuration.x.egress_client_factory = -> { client }

    ReconcileRecordingsJob.perform_now(webinar.id)
    ReconcileRecordingsJob.perform_now(0)

    assert_equal "done", leftover.reload.status
    assert_equal [ "EG_74" ], stopped
  ensure
    Rails.configuration.x.egress_client_factory = previous
  end
end
