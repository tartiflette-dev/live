# frozen_string_literal: true

require "test_helper"

# Vérification minute par minute du transcripteur : chaque captation ouverte,
# jamais un direct terminé.
class TranscriberSweepJobTest < ActiveJob::TestCase
  test "direct en cours et scène captée avant le go_live vérifiés ; direct terminé, brouillon inerte et composite fantôme ignorés" do
    live = Webinar.create!(title: "En direct", starts_at: 1.hour.ago, host_sub: "sub-a", state: "live", started_at: 1.hour.ago)
    stage = Webinar.create!(title: "Scène", starts_at: 1.hour.from_now, host_sub: "sub-a")
    stage.recordings.create!(status: "recording", egress_id: "EG_stage", started_at: 1.minute.ago)
    ended = Webinar.create!(title: "Fini", starts_at: 2.hours.ago, host_sub: "sub-a", state: "ended",
                            started_at: 2.hours.ago, ended_at: 1.minute.ago)
    ended.recordings.create!(status: "stopping", egress_id: "EG_fin", started_at: 1.hour.ago)
    Webinar.create!(title: "Brouillon", starts_at: 1.day.from_now, host_sub: "sub-a")
    phantom = Webinar.create!(title: "Fantôme", starts_at: 2.days.ago, host_sub: "sub-a")
    phantom.recordings.create!(status: "recording", egress_id: "EG_fantome", started_at: 2.days.ago)

    TranscriberSweepJob.perform_now

    checked = enqueued_jobs.select { |job| job["job_class"] == "TranscriberPresenceJob" }.map { |job| job["arguments"].first }
    assert_equal [ live.id, stage.id ].sort, checked.sort
  end
end
