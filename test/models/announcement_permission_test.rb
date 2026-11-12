require "test_helper"

# Qui peut viser quelle cible, et les quotas (audit sécurité E1, E2).
class AnnouncementPermissionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @owner = User.create!(email: "owner@example.test", oidc_sub: "sub-owner")
    @project = project_host_user
    @webinar = announcement_webinar(host_sub: @owner.oidc_sub, starts_at: Time.zone.parse("2026-11-12 9:30"))
    @guest = guest_user(@webinar)
    confirmed_registration(@webinar, "ana@example.test")
    consenting_request("liste@example.test")
  end

  def permission(user, now: Time.zone.parse("2026-11-12 10:00"))
    AnnouncementPermission.new(@webinar, user, now: now)
  end

  def sent(audience, author_role:, author_sub: "sub-projet", at: Time.current)
    announcement = build_announcement(@webinar, audience, author_sub: author_sub, author_role: author_role)
    announcement.dispatch!(announcement.recipients, now: at)
    announcement.update_columns(created_at: at)
    announcement
  end

  test "listes : animateurs du projet seulement, jamais le seul propriétaire d'un café" do
    assert_equal Announcement::AUDIENCES, permission(@project).audiences
    assert_equal %w[webinar_registrants], permission(@owner).audiences
  end

  test "un propriétaire sorti du groupe des animateurs perd les listes" do
    @project.update!(admin: false)
    other = announcement_webinar(host_sub: @project.oidc_sub)

    assert_equal %w[webinar_registrants], AnnouncementPermission.new(other, @project).audiences
  end

  test "co-animateur : inscrits le jour du café seulement, de 0:00 à la fin prévue + 2 h" do
    assert_empty permission(@guest, now: Time.zone.parse("2026-11-11 23:59")).audiences
    assert_equal %w[webinar_registrants], permission(@guest, now: Time.zone.parse("2026-11-12 0:00")).audiences
    assert_equal %w[webinar_registrants], permission(@guest, now: Time.zone.parse("2026-11-12 12:30")).audiences
    assert_empty permission(@guest, now: Time.zone.parse("2026-11-12 12:31")).audiences
  end

  test "propriétaire et animateur du projet : les inscrits sans fenêtre" do
    later = Time.zone.parse("2027-01-01 10:00")
    assert_includes permission(@owner, now: later).audiences, "webinar_registrants"
    assert_includes permission(@project, now: later).audiences, "webinar_registrants"
  end

  test "listes : un envoi par 24 h glissantes, toutes listes confondues" do
    first = sent("marketing_list", author_role: "project_host", at: 23.hours.ago)
    first.deliveries.update_all(delivered_at: 23.hours.ago)

    assert_match(/un seul par 24 h/, permission(@project, now: Time.current).refusal("notify_next"))
    assert_nil permission(@project, now: 25.hours.from_now).refusal("marketing_list")
  end

  test "listes : aucun nouvel envoi ni reprise tant qu'un autre envoi aux listes est en cours" do
    running = sent("marketing_list", author_role: "project_host", at: 2.days.ago)
    running.deliveries.update_all(scheduled_at: Time.current)
    interrupted = sent("notify_next", author_role: "project_host", at: 3.days.ago)
    interrupted.update_columns(created_at: 3.days.ago)

    assert_match(/encore en cours/, permission(@project, now: Time.current).refusal("notify_next"))
    assert_match(/encore en cours/, permission(@project, now: Time.current).resume_refusal(interrupted))
    assert_nil permission(@project, now: Time.current).resume_refusal(running)
    running.deliveries.update_all(delivered_at: Time.current)
    assert_nil permission(@project, now: Time.current).refusal("notify_next")
  end

  test "co-animateur : au plus 3 envois par jour" do
    now = Time.zone.parse("2026-11-12 10:00")
    travel_to(now) do
      2.times { sent("webinar_registrants", author_role: "guest_host", author_sub: @guest.oidc_sub, at: now) }
      assert_nil permission(@guest, now: now).refusal("webinar_registrants")
      sent("webinar_registrants", author_role: "guest_host", author_sub: @guest.oidc_sub, at: now)
      assert_match(/3 envois/, permission(@guest, now: now).refusal("webinar_registrants"))
      assert_nil permission(@owner, now: now).refusal("webinar_registrants")
    end
  end
end
