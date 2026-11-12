require "test_helper"

class HostAttendanceRequestJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @webinar = Webinar.create!(title: "Café", starts_at: 10.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
  end

  test "demande la présence au co-animateur ; rejoué, n'envoie rien de plus" do
    @webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    clear_enqueued_jobs

    assert_enqueued_emails(1) { HostAttendanceRequestJob.perform_now(@webinar) }
    assert_enqueued_email_with HostAttendanceMailer, :presence_request,
                               args: [ @webinar.webinar_hosts.sole.host_attendance ]
    clear_enqueued_jobs
    assert_no_enqueued_emails { HostAttendanceRequestJob.perform_now(@webinar) }
  end

  test "café sans co-animateur : le propriétaire ne se mail pas lui-même" do
    clear_enqueued_jobs

    assert_no_enqueued_emails { HostAttendanceRequestJob.perform_now(@webinar) }
    assert_equal "present", @webinar.host_attendances.sole.answer
  end
end
