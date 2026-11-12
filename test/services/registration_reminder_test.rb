require "test_helper"

# Rappel de la veille (docs/registration-reminders.md). Heures à Paris :
# le Café IA #8 commence le mercredi 4 novembre 2026 à 9 h 30, son rappel
# part le mardi 3 à partir de 9 h.
class RegistrationReminderTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  # Transport de test qui échoue avec l'erreur demandée.
  class FailingDelivery
    class << self
      attr_accessor :error
    end

    def initialize(_settings) = nil

    def deliver!(_mail)
      raise self.class.error
    end
  end
  ActionMailer::Base.add_delivery_method :failing_for_reminder_test, FailingDelivery

  PARIS = Time.find_zone("Europe/Paris")
  CAFE_STARTS_AT = PARIS.parse("2026-11-04 09:30")
  VEILLE_9H = PARIS.parse("2026-11-03 09:00")

  setup do
    ActionMailer::Base.deliveries.clear
    @webinar = Webinar.create!(title: "Café IA #8", starts_at: CAFE_STARTS_AT, host_sub: "host", visibility: "published")
    @registration = confirmed_registration(@webinar, "alice@example.test")
  end

  test "la veille à 9 h : un rappel par inscription confirmée, avec le jeton d'accès" do
    other = confirmed_registration(@webinar, "bob@example.test")

    run = RegistrationReminder.deliver_due(VEILLE_9H)

    assert_equal({ due: 2, outcomes: { sent: 2 } }, run)
    assert_equal %w[alice@example.test bob@example.test], ActionMailer::Base.deliveries.flat_map(&:to).sort
    state = @registration.reload.reminder_sent_at
    assert_equal "2026-11-04T08:30:00Z", state["j1_starts_at"]
    assert_equal "2026-11-03T08:00:00Z", state["j1_attempted_at"]
    assert_predicate state["j1"], :present?
    assert_nil state["j1_error"]
    assert_predicate other.reload.reminder_sent_at["j1"], :present?
  end

  test "exactement une fois : les tours suivants et un rejeu n'envoient plus rien" do
    RegistrationReminder.deliver_due(VEILLE_9H)

    assert_no_emails do
      assert_equal({ due: 1, outcomes: { skipped: 1 } }, RegistrationReminder.deliver_due(VEILLE_9H + 1.hour))
      assert_equal :skipped, RegistrationReminder.new(@registration.reload).deliver(VEILLE_9H + 2.hours)
    end
  end

  test "deux exécutions concurrentes : le verrou en base n'en laisse passer qu'une" do
    stale_a = Registration.find(@registration.id)
    stale_b = Registration.find(@registration.id)

    assert_emails 1 do
      assert_equal :sent, RegistrationReminder.new(stale_a).deliver(VEILLE_9H)
      assert_equal :skipped, RegistrationReminder.new(stale_b).deliver(VEILLE_9H)
    end
  end

  test "jamais la nuit, ni avant la veille, ni le jour même" do
    [ PARIS.parse("2026-11-03 08:59"), PARIS.parse("2026-11-03 21:00"),
      PARIS.parse("2026-11-02 12:00"), PARIS.parse("2026-11-04 08:00") ].each do |now|
      assert_no_emails { assert_equal({ due: 0, outcomes: {} }, RegistrationReminder.deliver_due(now), now.to_s) }
    end
    assert_emails(1) { RegistrationReminder.deliver_due(PARIS.parse("2026-11-03 20:59")) }
  end

  test "un instant donné en UTC se lit à l'heure de Paris" do
    assert_no_emails { RegistrationReminder.deliver_due(Time.utc(2026, 11, 3, 7, 59)) }
    assert_emails(1) { RegistrationReminder.deliver_due(Time.utc(2026, 11, 3, 8, 0)) }
  end

  test "confirmée dans la journée de la veille : servie au tour suivant" do
    late = @webinar.registrations.create!(name: "Lou", email: "lou@example.test")
    RegistrationReminder.deliver_due(VEILLE_9H)
    late.confirm!

    assert_emails(1) { RegistrationReminder.deliver_due(VEILLE_9H + 1.hour) }
    assert_equal [ "lou@example.test" ], ActionMailer::Base.deliveries.last.to
  end

  test "rien pour une inscription non confirmée, ou effacée par crm:erase" do
    @webinar.registrations.create!(name: "Pending", email: "pending@example.test")
    CrmErasure.erase!("alice@example.test")

    assert_no_emails { assert_equal 0, RegistrationReminder.deliver_due(VEILLE_9H)[:due] }
  end

  test "rien pour un webinaire dépublié, déjà lancé ou terminé" do
    %w[unpublished live ended].each_with_index do |variant, index|
      webinar = Webinar.create!(title: "Variante #{variant}", starts_at: CAFE_STARTS_AT + index.minutes,
                                host_sub: "host", visibility: "published")
      confirmed_registration(webinar, "#{variant}@example.test")
      variant == "unpublished" ? webinar.update!(visibility: "draft") : webinar.update!(state: variant)
    end

    RegistrationReminder.deliver_due(VEILLE_9H)

    assert_equal [ "alice@example.test" ], ActionMailer::Base.deliveries.flat_map(&:to)
  end

  test "le verrou revérifie le webinaire : dépublié entre la sélection et l'envoi, rien ne part" do
    reminder = RegistrationReminder.new(@registration)
    @webinar.update!(visibility: "draft")

    assert_no_emails { assert_equal :skipped, reminder.deliver(VEILLE_9H) }
    assert_empty @registration.reload.reminder_sent_at
  end

  test "webinaire déplacé à une autre date après le rappel : un rappel pour la nouvelle date" do
    RegistrationReminder.deliver_due(VEILLE_9H)
    @webinar.update!(starts_at: CAFE_STARTS_AT + 7.days)

    assert_emails(1) { RegistrationReminder.deliver_due(VEILLE_9H + 7.days) }
    assert_equal "2026-11-11T08:30:00Z", @registration.reload.reminder_sent_at["j1_starts_at"]
  end

  test "refus SMTP temporaire : verrou rendu, nouvel essai au tour suivant" do
    with_failing_delivery(Net::SMTPServerBusy.new("451 try again later")) do
      assert_equal :smtp_retry, RegistrationReminder.new(@registration).deliver(VEILLE_9H)
    end
    state = @registration.reload.reminder_sent_at
    assert_equal "Net::SMTPServerBusy", state["j1_error"]
    assert_nil state["j1_starts_at"]

    assert_emails(1) { RegistrationReminder.deliver_due(VEILLE_9H + 1.hour) }
    assert_nil @registration.reload.reminder_sent_at["j1_error"]
  end

  test "refus temporaires répétés : au plus MAX_ATTEMPTS tentatives, puis abandon définitif" do
    with_failing_delivery(Net::SMTPServerBusy.new("451 try again later")) do
      outcomes = 4.times.map { |round| RegistrationReminder.deliver_due(VEILLE_9H + round.hours)[:outcomes] }
      assert_equal [ { smtp_retry: 1 }, { abandoned: 1 }, { skipped: 1 }, { skipped: 1 } ], outcomes
    end
    state = @registration.reload.reminder_sent_at
    assert_equal RegistrationReminder::MAX_ATTEMPTS, state["j1_attempts"]
    assert_predicate state["j1_abandoned_at"], :present?
    assert_equal "2026-11-04T08:30:00Z", state["j1_starts_at"], "verrou gardé après l'abandon"

    assert_no_emails { RegistrationReminder.deliver_due(VEILLE_9H + 5.hours) }
  end

  # Net::SMTP#start appelle QUIT dans un ensure ; un
  # 421 au QUIT lève Net::SMTPServerBusy alors que le DATA a été accepté.
  test "QUIT 421 après un DATA accepté : au plus MAX_ATTEMPTS remises" do
    server = QuitBusySmtpServer.new
    with_smtp_server(server) do
      6.times { |round| RegistrationReminder.deliver_due(VEILLE_9H + round.hours) }
    end

    assert_equal 2, server.accepted, "6 passages, 2 remises au plus (sans plafond : 6)"
    state = @registration.reload.reminder_sent_at
    assert_equal "Net::SMTPServerBusy", state["j1_error"]
    assert_predicate state["j1_abandoned_at"], :present?
  ensure
    server&.stop
  end

  test "le compteur de tentatives repart à zéro pour une nouvelle date" do
    with_failing_delivery(Net::SMTPServerBusy.new("451 try again later")) do
      2.times { |round| RegistrationReminder.deliver_due(VEILLE_9H + round.hours) }
    end
    @webinar.update!(starts_at: CAFE_STARTS_AT + 7.days)

    assert_emails(1) { RegistrationReminder.deliver_due(VEILLE_9H + 7.days) }
    state = @registration.reload.reminder_sent_at
    assert_equal 1, state["j1_attempts"]
    assert_nil state["j1_abandoned_at"]
  end

  test "issue SMTP incertaine : verrou gardé, jamais de second envoi" do
    with_failing_delivery(Net::ReadTimeout.new) do
      assert_equal :failed, RegistrationReminder.new(@registration).deliver(VEILLE_9H)
    end
    state = @registration.reload.reminder_sent_at
    assert_equal "Net::ReadTimeout", state["j1_error"]
    assert_equal "2026-11-04T08:30:00Z", state["j1_starts_at"]
    assert_nil state["j1"]

    assert_no_emails { RegistrationReminder.deliver_due(VEILLE_9H + 1.hour) }
  end

  test "une erreur d'envoi n'arrête pas la tournée" do
    confirmed_registration(@webinar, "bob@example.test")
    with_failing_delivery(Net::ReadTimeout.new) do
      assert_equal({ due: 2, outcomes: { failed: 2 } }, RegistrationReminder.deliver_due(VEILLE_9H))
    end

    assert_equal 2, Registration.where("json_extract(reminder_sent_at, '$.j1_error') IS NOT NULL").count
  end

  test "un rendu impossible ne prend pas le verrou" do
    RegistrationMailer.define_singleton_method(:reminder) { |_registration| raise ArgumentError, "vue cassée" }
    begin
      assert_equal :failed, RegistrationReminder.new(@registration).deliver(VEILLE_9H)
    ensure
      RegistrationMailer.singleton_class.remove_method(:reminder)
    end

    assert_empty @registration.reload.reminder_sent_at
  end

  private

  def confirmed_registration(webinar, email)
    webinar.registrations.create!(name: email.split("@").first.capitalize, email: email).tap(&:confirm!)
  end

  # Serveur SMTP minimal : accepte le message (250 après DATA) puis répond
  # 421 au QUIT. Compte les messages acceptés.
  class QuitBusySmtpServer
    attr_reader :accepted, :port

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @accepted = 0
      @thread = Thread.new { loop { serve(@server.accept) } }
    end

    def stop
      @thread.kill
      @server.close
    end

    private

    def serve(client)
      client.write "220 test\r\n"
      while (line = client.gets)
        case line
        when /\AQUIT/i then client.write("421 busy\r\n") && break
        when /\ADATA/i
          client.write "354 go\r\n"
          nil until client.gets == ".\r\n"
          @accepted += 1
          client.write "250 queued\r\n"
        else client.write "250 ok\r\n"
        end
      end
    ensure
      client.close
    end
  end

  def with_smtp_server(server)
    previous_method = ActionMailer::Base.delivery_method
    previous_settings = ActionMailer::Base.smtp_settings
    ActionMailer::Base.delivery_method = :smtp
    ActionMailer::Base.smtp_settings = { address: "127.0.0.1", port: server.port, enable_starttls_auto: false }
    yield
  ensure
    ActionMailer::Base.delivery_method = previous_method
    ActionMailer::Base.smtp_settings = previous_settings
  end

  def with_failing_delivery(error)
    FailingDelivery.error = error
    previous = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :failing_for_reminder_test
    yield
  ensure
    ActionMailer::Base.delivery_method = previous
  end
end
