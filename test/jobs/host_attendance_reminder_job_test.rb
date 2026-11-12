require "test_helper"

# Tournée quotidienne : demandes jamais faites, relance J-3 des co-animateurs.
class HostAttendanceReminderJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    travel_to Time.zone.local(2026, 11, 10, 10, 0, 5)
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
  end

  test "rattrape un café publié sans demande (co-animateurs seulement), puis ne renvoie rien" do
    webinar = Webinar.create!(title: "Café", starts_at: 10.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    Webinar.create!(title: "Seul", starts_at: 10.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    Webinar.create!(title: "Brouillon", starts_at: 10.days.from_now, host_sub: @owner.oidc_sub)
    clear_enqueued_jobs

    assert_enqueued_emails(1) { HostAttendanceReminderJob.perform_now }
    clear_enqueued_jobs
    assert_no_enqueued_emails { HostAttendanceReminderJob.perform_now }
  end

  test "relance J-3 les co-animateurs sans réponse, une seule fois" do
    webinar = Webinar.create!(title: "Café", starts_at: Time.zone.local(2026, 11, 20, 19, 0), host_sub: @owner.oidc_sub,
                              visibility: "published")
    webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    webinar.request_host_attendances!
    clear_enqueued_jobs

    j3 = Time.zone.local(2026, 11, 17, 10, 0, 2)
    assert_enqueued_emails(1) { HostAttendanceReminderJob.perform_now(j3) }
    assert_enqueued_email_with HostAttendanceMailer, :presence_reminder, args: [ webinar.webinar_hosts.sole.host_attendance ]
    clear_enqueued_jobs
    assert_no_enqueued_emails { HostAttendanceReminderJob.perform_now(j3 + 1.hour) }
  end

  test "programmée chaque jour à 10:00, heure de Paris, en production" do
    task = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "host_attendance_reminder")

    assert_equal "HostAttendanceReminderJob", task["class"]
    assert_equal "0 10 * * * Europe/Paris", task["schedule"]
  end
end
