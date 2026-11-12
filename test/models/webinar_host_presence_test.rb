require "test_helper"

# Webinar::HostPresence : quand les demandes de présence partent, et qui a une
# présence à donner.
class WebinarHostPresenceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
  end

  test "un café créé publié demande la présence tout de suite ; un brouillon, non" do
    assert_no_enqueued_jobs(only: HostAttendanceRequestJob) do
      Webinar.create!(title: "Brouillon", starts_at: 5.days.from_now, host_sub: @owner.oidc_sub)
    end

    webinar = nil
    assert_enqueued_jobs 1, only: HostAttendanceRequestJob do
      webinar = Webinar.create!(title: "Publié", starts_at: 5.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    end
    assert_enqueued_with(job: HostAttendanceRequestJob, args: [ webinar ])
  end

  test "publier un brouillon demande la présence ; dépublier, non" do
    webinar = Webinar.create!(title: "Café", starts_at: 5.days.from_now, host_sub: @owner.oidc_sub)

    assert_enqueued_jobs(1, only: HostAttendanceRequestJob) { webinar.update!(visibility: "published") }
    assert_no_enqueued_jobs(only: HostAttendanceRequestJob) { webinar.update!(visibility: "draft") }
  end

  test "date déplacée : demande différée, plusieurs retouches font une seule tournée utile" do
    webinar = Webinar.create!(title: "Café", starts_at: 5.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    clear_enqueued_jobs

    freeze_time do
      webinar.update!(starts_at: 6.days.from_now)
      assert_enqueued_with(job: HostAttendanceRequestJob, args: [ webinar ],
                           at: Webinar::HostPresence::RESCHEDULE_REQUEST_DELAY.from_now)
    end
    assert_no_enqueued_jobs(only: HostAttendanceRequestJob) { webinar.update!(title: "Café renommé") }
  end

  test "café passé ou commencé : aucune demande" do
    assert_no_enqueued_jobs(only: HostAttendanceRequestJob) do
      Webinar.create!(title: "Passé", starts_at: 1.day.ago, host_sub: @owner.oidc_sub, visibility: "published")
    end
    webinar = Webinar.create!(title: "Direct", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    webinar.go_live!

    assert_equal 0, webinar.request_host_attendances!
  end

  test "ajout d'un co-animateur, par toutes les voies : sa présence est demandée" do
    webinar = Webinar.create!(title: "Café", starts_at: 5.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")

    assert_enqueued_jobs(1, only: HostAttendanceRequestJob) do
      webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    end
  end

  test "tournée de demandes : présomption du propriétaire enregistrée, chaque co-animateur demandé une fois" do
    webinar = Webinar.create!(title: "Café", starts_at: 5.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    webinar.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: @owner.oidc_sub)

    assert_equal 2, webinar.request_host_attendances!
    assert_equal 0, webinar.request_host_attendances!
    owner_row = webinar.host_attendances.find_by(webinar_host: nil)
    assert_equal [ "present", nil ], [ owner_row.answer, owner_row.requested_at ]
    assert_equal 3, webinar.host_attendances.count
  end

  test "présence de qui ? propriétaire, co-animateur à l'adresse vérifiée ; pas un animateur du projet ni un inconnu" do
    webinar = Webinar.create!(title: "Café", starts_at: 5.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    host = webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean",
                         email_verified: true, email_verified_for: "jean@partenaire.example.org")
    webinar.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    unverified = User.create!(email: "paul@partenaire.example.org", oidc_sub: "sub-paul")
    admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)

    owner_row = webinar.host_attendance_for(@owner)
    assert owner_row.new_record?
    assert owner_row.owner?
    assert_equal host, webinar.host_attendance_for(guest).webinar_host
    assert_nil webinar.host_attendance_for(unverified)
    assert_nil webinar.host_attendance_for(admin)
    assert_nil webinar.host_attendance_for(nil)

    webinar.save!
    assert_equal 0, webinar.host_attendances.count, "lire la présence n'écrit rien, même au save du webinaire"
  end

  test "statut : café sans co-animateur confirmé d'office ; un direct en cours a sa date confirmée" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.hour.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    assert_equal "confirmed", webinar.date_status
    webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    assert_equal "to_confirm", webinar.reload.date_status

    webinar.go_live!
    assert_equal "confirmed", webinar.date_status
  end
end
