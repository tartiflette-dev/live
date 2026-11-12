require "test_helper"

# Mails de changement d'un webinaire publié à venir : nouvelle date ou
# annulation, aux inscrits confirmés, après un délai d'apaisement, une fois.
class WebinarChangeNoticeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    travel_to Time.zone.local(2026, 11, 2, 10, 0)
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.zone.local(2026, 11, 10, 9, 30),
                               host_sub: "sub-marc", visibility: "published", kind: "cafe_ia")
    @alice = confirmed("alice@example.test")
    @bob = confirmed("bob@example.test")
    @pending = @webinar.registrations.create!(name: "Pas confirmée", email: "pending@example.test")
    @removed = confirmed("removed@example.test")
    @removed.update!(room_removed_at: Time.current)
    clear_enqueued_jobs
  end

  def confirmed(email)
    @webinar.registrations.create!(name: email.split("@").first.capitalize, email: email).tap(&:confirm!)
  end

  def change_mails
    enqueued_jobs.select { |job| job[:job] == ActionMailer::MailDeliveryJob && job[:args].first == "WebinarChangeMailer" }
  end

  def change_mail_recipients
    change_mails.map do |job|
      _mailer, action, _delivery, params = ActiveJob::Arguments.deserialize(job[:args])
      [ action, params[:args].first.email ]
    end
  end

  def assert_announced_now
    job = enqueued_jobs.select { |enqueued| enqueued[:job] == WebinarChangeNoticeJob }.sole
    assert job[:at].nil? || job[:at] <= Time.current.to_f, "job immédiat attendu, planifié à #{job[:at].inspect}"
  end

  # Fait passer le délai d'apaisement : les jobs de changement en file
  # tournent, les mails restent en file.
  def after_quiet_period
    travel WebinarChangeNotice::QUIET_PERIOD + 1.second
    perform_enqueued_jobs(only: WebinarChangeNoticeJob)
  end

  test "date déplacée : « nouvelle date » aux seuls inscrits confirmés et présents, après dix minutes" do
    @webinar.update!(starts_at: Time.zone.local(2026, 11, 12, 9, 30))

    assert_enqueued_with(job: WebinarChangeNoticeJob, at: WebinarChangeNotice::QUIET_PERIOD.from_now)
    assert_empty change_mails

    after_quiet_period

    assert_equal [ [ "rescheduled", "alice@example.test" ], [ "rescheduled", "bob@example.test" ] ], change_mail_recipients
    notice = WebinarChangeNotice.sole
    assert_equal Time.zone.local(2026, 11, 12, 9, 30), notice.starts_at
    assert_equal 2, notice.deliveries.where(kind: "rescheduled").count
  end

  test "dépublication : « annulé », avec la date qui était annoncée" do
    @webinar.update!(starts_at: Time.zone.local(2026, 11, 12, 9, 30))
    @webinar.update!(visibility: "draft")

    after_quiet_period

    assert_equal [ [ "cancelled", "alice@example.test" ], [ "cancelled", "bob@example.test" ] ], change_mail_recipients
    assert_enqueued_email_with WebinarChangeMailer, :cancelled,
                               args: [ @alice, { starts_at: Time.zone.local(2026, 11, 10, 9, 30) } ]
  end

  # Cas de la revue du lot D : un café de 18:00 dépublié à 17:55 doit être
  # annoncé, même si le job ne passe qu'après 18:00.
  test "annulation à H-5 min : annonce sans attendre, jugée à l'heure du changement, même si le job passe après le début" do
    travel_to @webinar.starts_at - 5.minutes
    @webinar.update!(visibility: "draft")

    assert_announced_now
    travel 6.minutes
    perform_enqueued_jobs(only: WebinarChangeNoticeJob)

    assert_equal [ [ "cancelled", "alice@example.test" ], [ "cancelled", "bob@example.test" ] ], change_mail_recipients
  end

  test "changement à H-20 min : annonce immédiate, sans délai d'apaisement" do
    travel_to @webinar.starts_at - 20.minutes
    @webinar.update!(starts_at: @webinar.starts_at + 1.hour)

    assert_announced_now
    perform_enqueued_jobs(only: WebinarChangeNoticeJob)

    assert_equal [ [ "rescheduled", "alice@example.test" ], [ "rescheduled", "bob@example.test" ] ], change_mail_recipients
  end

  test "changement à J-2 : délai d'apaisement de dix minutes inchangé" do
    travel_to @webinar.starts_at - 2.days
    @webinar.update!(starts_at: @webinar.starts_at + 1.day)

    assert_enqueued_with(job: WebinarChangeNoticeJob, at: WebinarChangeNotice::QUIET_PERIOD.from_now)
    perform_enqueued_jobs(only: WebinarChangeNoticeJob, at: Time.current)
    assert_empty change_mails
  end

  test "urgence redoublée : un job immédiat rejoué après le délai n'envoie rien de plus" do
    travel_to @webinar.starts_at - 5.minutes
    @webinar.update!(visibility: "draft")
    notice = WebinarChangeNotice.sole
    perform_enqueued_jobs(only: WebinarChangeNoticeJob)

    assert_equal 0, notice.reload.announce!(notice.revision)
    assert_equal 2, change_mails.size
  end

  test "anti-rafale : plusieurs retouches en dix minutes, un seul mail, pour le dernier état" do
    @webinar.update!(starts_at: Time.zone.local(2026, 11, 11, 9, 30))
    travel 3.minutes
    @webinar.update!(starts_at: Time.zone.local(2026, 11, 12, 9, 30))
    travel 3.minutes
    @webinar.update!(starts_at: Time.zone.local(2026, 11, 13, 9, 30))

    travel WebinarChangeNotice::QUIET_PERIOD + 1.second
    perform_enqueued_jobs(only: WebinarChangeNoticeJob)

    assert_equal 2, change_mails.size
    assert_equal Time.zone.local(2026, 11, 13, 9, 30), WebinarChangeNotice.sole.starts_at
  end

  test "date remise, dépublication annulée dans le délai : rien ne part" do
    @webinar.update!(starts_at: Time.zone.local(2026, 11, 12, 9, 30))
    @webinar.update!(starts_at: Time.zone.local(2026, 11, 10, 9, 30))
    @webinar.update!(visibility: "draft")
    @webinar.update!(visibility: "published")

    after_quiet_period

    assert_empty change_mails
  end

  test "idempotent : un job rejoué n'envoie rien de plus" do
    @webinar.update!(starts_at: Time.zone.local(2026, 11, 12, 9, 30))
    notice = WebinarChangeNotice.sole
    after_quiet_period

    assert_equal 0, notice.reload.announce!(notice.revision)
    assert_equal 2, change_mails.size
  end

  test "reprise après coupure : seuls ceux qui n'ont rien reçu reçoivent le mail" do
    @webinar.update!(starts_at: Time.zone.local(2026, 11, 12, 9, 30))
    notice = WebinarChangeNotice.sole
    # Coupure simulée : Alice marquée, puis la base garde l'état annoncé ancien.
    WebinarChangeDelivery.create!(webinar_change_notice: notice, registration: @alice, revision: notice.revision,
                                  kind: "rescheduled", created_at: Time.current)

    after_quiet_period

    assert_equal [ [ "rescheduled", "bob@example.test" ] ], change_mail_recipients
  end

  test "annulée puis republiée plus tard : l'annulation, puis la date, chacune une fois" do
    @webinar.update!(visibility: "draft")
    after_quiet_period
    @webinar.update!(visibility: "published")
    after_quiet_period

    assert_equal %w[cancelled cancelled rescheduled rescheduled], change_mails.map { |job| job[:args].second }
  end

  test "webinaire jamais publié, passé ou lancé : aucun mail" do
    draft = Webinar.create!(title: "Brouillon", starts_at: 5.days.from_now, host_sub: "sub-marc", visibility: "draft")
    draft.update!(starts_at: 6.days.from_now)
    assert_not WebinarChangeNotice.exists?(webinar_id: draft.id)

    @webinar.update!(starts_at: 1.day.ago)
    after_quiet_period
    assert_empty change_mails

    @webinar.update!(starts_at: 1.day.from_now, state: "live")
    after_quiet_period
    assert_empty change_mails
  end

  test "première publication d'un brouillon qui a déjà des inscrits confirmés : aucun mail, aucune ligne" do
    draft = Webinar.create!(title: "Café préparé", starts_at: 5.days.from_now, host_sub: "sub-marc",
                            visibility: "draft", kind: "cafe_ia")
    draft.registrations.create!(name: "Lien privé", email: "prive@example.test").confirm!
    clear_enqueued_jobs

    draft.update!(visibility: "published")
    after_quiet_period

    assert_empty change_mails
    assert_not WebinarChangeNotice.exists?(webinar_id: draft.id)
    assert_no_enqueued_jobs(only: WebinarChangeNoticeJob)
  end

  test "un webinaire changé sans inscrit confirmé : l'état est annoncé, sans mail" do
    lonely = Webinar.create!(title: "Seul", starts_at: 5.days.from_now, host_sub: "sub-marc", visibility: "published")
    lonely.update!(starts_at: 6.days.from_now)

    after_quiet_period

    assert_empty change_mails
    assert_not_nil WebinarChangeNotice.find_by!(webinar_id: lonely.id).notified_at
  end

  test "un webinaire supprimé emporte sa trace ; son job en attente n'échoue pas" do
    @webinar.update!(starts_at: Time.zone.local(2026, 11, 12, 9, 30))
    Registration.where(webinar_id: @webinar.id).delete_all
    Webinar.find(@webinar.id).destroy!

    assert_not WebinarChangeNotice.exists?
    assert_nothing_raised { after_quiet_period }
  end
end
