require "test_helper"
require "yaml"
require "fugit"

class RegistrationReminderJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  PARIS = Time.find_zone("Europe/Paris")

  setup do
    @flag = ENV["REMINDERS_ENABLED"]
    webinar = Webinar.create!(title: "Café IA #8", starts_at: PARIS.parse("2026-11-04 09:30"),
                              host_sub: "host", visibility: "published")
    webinar.registrations.create!(name: "Alice", email: "alice@example.test").confirm!
  end

  teardown { ENV["REMINDERS_ENABLED"] = @flag }

  test "REMINDERS_ENABLED=1 : la tournée envoie, journalise ses compteurs sans PII et les enregistre" do
    ENV["REMINDERS_ENABLED"] = "1"
    log = StringIO.new
    previous_logger = Rails.logger
    # Niveau debug : le plus bavard. ActionMailer se charge à la demande et prendrait
    # Rails.logger à ce moment-là, sans le réglage de config/application.rb.
    Rails.logger = ActiveSupport::Logger.new(log, level: :debug)
    travel_to(PARIS.parse("2026-11-03 09:00")) do
      assert_emails(1) { RegistrationReminderJob.perform_now }
    end

    assert_includes log.string, "registration_reminder due=1 sent=1 skipped=0 smtp_retry=0 abandoned=0 failed=0"
    assert_no_match(/alice|example\.test/i, log.string)
    assert_nil ActionMailer::Base.logger, "le journal d'ActionMailer doit rester muet, à tout niveau"
    run = RegistrationReminderRun.sole
    assert_equal [ 1, 1, 0 ], [ run.due, run.sent, run.abandoned ]
  ensure
    Rails.logger = previous_logger
  end

  test "un journal de plus de 30 jours est purgé à la tournée suivante" do
    ENV["REMINDERS_ENABLED"] = "1"
    RegistrationReminderRun.create!(ran_at: PARIS.parse("2026-10-03 08:00"))
    recent = RegistrationReminderRun.create!(ran_at: PARIS.parse("2026-10-05 08:00"))
    travel_to(PARIS.parse("2026-11-03 09:00")) { RegistrationReminderJob.perform_now }

    assert_equal [ recent.id ], RegistrationReminderRun.where(ran_at: ...PARIS.parse("2026-11-01")).pluck(:id)
  end

  test "drapeau absent ou à 0 : aucun envoi" do
    [ nil, "0" ].each do |flag|
      ENV["REMINDERS_ENABLED"] = flag
      travel_to(PARIS.parse("2026-11-03 09:00")) do
        assert_no_emails { RegistrationReminderJob.perform_now }
      end
    end
    assert_equal 0, RegistrationReminderRun.count, "coupé : pas de tournée enregistrée"
  end

  test "câblé en production dans config/recurring.yml, aux heures de SEND_HOURS à Paris" do
    recurring = YAML.safe_load(Rails.root.join("config/recurring.yml").read, aliases: true)
    task = recurring.dig("production", "registration_reminder")
    assert_equal "RegistrationReminderJob", task["class"]
    assert_empty recurring.fetch("test")

    cron = Fugit.parse(task["schedule"], multi: :fail) # comme SolidQueue::RecurringTask
    assert_kind_of Fugit::Cron, cron
    assert_equal RegistrationReminder::SEND_HOURS.to_a, cron.hours
    # Café IA #8 : premier tour le mardi 3 novembre 2026 à 09:00 Paris (CET) = 08:00 UTC.
    first = cron.next_time(EtOrbi.make_time(Time.utc(2026, 11, 2, 20, 0))).to_t.utc
    assert_equal Time.utc(2026, 11, 3, 8, 0), first
    # Heure d'été : 09:00 Paris = 07:00 UTC — le fuseau est celui du cron, pas du conteneur.
    summer = cron.next_time(EtOrbi.make_time(Time.utc(2026, 7, 1, 0, 0))).to_t.utc
    assert_equal Time.utc(2026, 7, 1, 7, 0), summer
  end
end
