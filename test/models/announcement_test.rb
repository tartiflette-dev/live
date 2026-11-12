require "test_helper"

# Envoi groupé : marqueur par destinataire, mise en file étalée, reprise sans
# doublon (jamais partis et sans nouvelles), avis aux superviseurs.
class AnnouncementTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @owner = User.create!(email: "owner@example.test", oidc_sub: "sub-owner")
    @webinar = announcement_webinar(host_sub: @owner.oidc_sub)
    @guest = guest_user(@webinar)
    %w[ana bob carol].each { |name| confirmed_registration(@webinar, "#{name}@example.test") }
    # Les fabriques publient un café et lui ajoutent un co-animateur : les
    # demandes de présence (HostAttendanceRequestJob) ne sont pas l'objet ici.
    clear_enqueued_jobs
  end

  def recipient_jobs
    enqueued_jobs.select { |job| job["arguments"].first == "AnnouncementMailer" }
  end

  test "objet sur une ligne, sans caractère de contrôle (en-tête de mail)" do
    announcement = build_announcement(@webinar, "webinar_registrants")
    announcement.subject = "Infos\r\nBcc: x@example.test"

    assert_equal "Infos Bcc: x@example.test", announcement.subject
  end

  test "dispatch! : un marqueur par destinataire, empreinte sans adresse, mails étalés" do
    announcement = build_announcement(@webinar, "webinar_registrants")

    assert_equal 3, announcement.dispatch!(announcement.recipients)

    assert_equal 3, announcement.reload.recipients_count
    deliveries = announcement.deliveries.order(:id)
    assert deliveries.all?(&:enqueued_at)
    assert_equal AnnouncementDelivery.digest("ana@example.test"), deliveries.first.recipient_digest
    assert_not_includes AnnouncementDelivery.column_names, "email"
    scheduled = recipient_jobs.map { |job| job[:at] }
    assert_in_delta Time.current.to_f, scheduled.first, 2
    assert_in_delta (Time.current + 2 * Announcement::SPACING).to_f, scheduled.last, 2
    assert_in_delta deliveries.last.scheduled_at.to_f, scheduled.last, 1
  end

  test "reprise : seuls les jamais partis repartent, jamais deux fois" do
    announcement = build_announcement(@webinar, "webinar_registrants")
    announcement.dispatch!(announcement.recipients)
    announcement.deliveries.order(:id).last.update_columns(enqueued_at: nil, scheduled_at: nil)
    clear_enqueued_jobs

    assert_equal 1, announcement.enqueue_pending!
    assert_equal 0, announcement.enqueue_pending!
    assert_equal 1, recipient_jobs.size
  end

  test "reprise pendant l'envoi : l'étalement continue après le dernier mail programmé" do
    announcement = build_announcement(@webinar, "webinar_registrants")
    announcement.dispatch!(announcement.recipients)
    last_slot = announcement.deliveries.maximum(:scheduled_at)
    announcement.deliveries.order(:id).first.update_columns(enqueued_at: nil, scheduled_at: nil)
    clear_enqueued_jobs

    announcement.enqueue_pending!

    assert_in_delta (last_slot + Announcement::SPACING).to_f, recipient_jobs.sole[:at], 1
  end

  test "reprise : relance un mail sans nouvelles, pas un mail encore attendu ni un mail remis" do
    announcement = build_announcement(@webinar, "webinar_registrants")
    announcement.dispatch!(announcement.recipients)
    silent, waiting, delivered = announcement.deliveries.order(:id).to_a
    stale = (AnnouncementDelivery::SILENT_AFTER + 1.minute).ago
    silent.update_columns(scheduled_at: stale, sending_at: stale)
    delivered.update_columns(scheduled_at: stale, delivered_at: stale)
    clear_enqueued_jobs

    assert_equal 1, announcement.enqueue_pending!
    assert_nil silent.reload.sending_at, "la prise de remise du job mort est rendue"
    assert silent.scheduled_at > Time.current - 1.minute
    assert_equal 1, recipient_jobs.size
    assert waiting.reload.enqueued_at
  end

  test "un marqueur pris par un autre passage n'est pas remis en file" do
    announcement = build_announcement(@webinar, "webinar_registrants")
    announcement.dispatch!([])
    delivery = announcement.deliveries.create!(recipient_digest: "d", holder: Registration.first)

    assert delivery.claim!(now: Time.current, scheduled_at: Time.current)
    assert_not delivery.claim!(now: Time.current, scheduled_at: Time.current)
  end

  test "échec de mise en file : le marqueur est rendu, la reprise repartira de là" do
    announcement = build_announcement(@webinar, "webinar_registrants")
    failing = Class.new(StandardError)
    mail = Object.new
    mail.define_singleton_method(:deliver_later) { |**| raise failing }
    AnnouncementMailer.define_singleton_method(:announcement) { |*| mail }

    assert_raises(failing) { announcement.dispatch!(announcement.recipients) }
    assert_equal 3, announcement.deliveries.pending.count
  ensure
    AnnouncementMailer.singleton_class.remove_method :announcement
  end

  test "dispatch_token unique en base : un second envoi au même jeton ne met rien en file" do
    first = build_announcement(@webinar, "webinar_registrants")
    first.dispatch!(first.recipients)
    clear_enqueued_jobs
    second = build_announcement(@webinar, "webinar_registrants")
    second.dispatch_token = first.dispatch_token

    assert_raises(ActiveRecord::RecordNotUnique) { second.dispatch!(second.recipients) }
    assert_empty enqueued_jobs
  end

  test "dispatch! : le bloc de garde lève Refused, rien n'est enregistré ni mis en file" do
    announcement = build_announcement(@webinar, "webinar_registrants")

    assert_raises(Announcement::Refused) { announcement.dispatch!(announcement.recipients) { raise Announcement::Refused } }
    assert_equal 0, Announcement.count
    assert_empty enqueued_jobs
  end

  test "avis : envoi aux listes → animateurs du projet ; envoi d'un co-animateur → propriétaire" do
    consenting_request("liste@example.test")
    build_announcement(@webinar, "marketing_list", author_role: "project_host").tap { |a| a.dispatch!(a.recipients) }
    assert_enqueued_email_with AnnouncementNoticeMailer, :list_sent, args: [ Announcement.last ]

    guest = build_announcement(@webinar, "webinar_registrants", author: @guest.email, author_sub: @guest.oidc_sub,
                                                               author_role: "guest_host")
    guest.dispatch!(guest.recipients)
    assert_enqueued_email_with AnnouncementNoticeMailer, :guest_sent, args: [ guest ]

    clear_enqueued_jobs
    build_announcement(@webinar, "webinar_registrants").tap { |a| a.dispatch!(a.recipients) }
    assert_empty enqueued_jobs.select { |job| job["arguments"].first == "AnnouncementNoticeMailer" }
  end

  test "Reply-To : l'auteur, ou le propriétaire quand l'auteur est co-animateur" do
    assert_equal "owner@example.test", build_announcement(@webinar, "webinar_registrants").reply_to_email
    guest = build_announcement(@webinar, "webinar_registrants", author: @guest.email, author_role: "guest_host")
    assert_equal "owner@example.test", guest.reply_to_email
    project = build_announcement(@webinar, "marketing_list", author: "projet@example.test", author_role: "project_host")
    assert_equal "projet@example.test", project.reply_to_email
  end

  test "visible_to : listes aux animateurs du projet ; propriétaire et co-animateur, les envois aux inscrits" do
    build_announcement(@webinar, "webinar_registrants").save!
    build_announcement(@webinar, "marketing_list", author_role: "project_host").save!

    assert_equal 2, Announcement.visible_to(@webinar, project_host_user).count
    assert_equal %w[webinar_registrants], Announcement.visible_to(@webinar, @owner).pluck(:audience)
    assert_equal %w[webinar_registrants], Announcement.visible_to(@webinar, @guest).pluck(:audience)
    assert_empty Announcement.visible_to(@webinar, User.create!(email: "x@example.test", oidc_sub: "sub-x"))
  end

  test "avancement par envoi, en une requête : remis, écartés, en cours, sans nouvelles, jamais partis" do
    announcement = build_announcement(@webinar, "webinar_registrants")
    announcement.dispatch!(announcement.recipients)
    delivered, silent, pending = announcement.deliveries.order(:id).to_a
    delivered.mark_delivered!
    silent.update_columns(scheduled_at: 1.hour.ago)
    pending.update_columns(enqueued_at: nil, scheduled_at: nil)

    progress = Announcement.progress_of([ announcement ]).fetch(announcement.id)
    assert_equal [ 1, 0, 0, 1, 1 ], progress.to_h.values_at(:delivered, :skipped, :in_flight, :silent, :pending)
    assert progress.resumable?
  end
end
