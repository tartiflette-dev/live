# frozen_string_literal: true

require "test_helper"

class Crm::BacklogTest < ActiveSupport::TestCase
  Item = Crm::Backlog::Item

  setup do
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.day.from_now, host_sub: "h", visibility: "published")
  end

  test "attente : grâce de 15 min avant tout essai ; après un enqueue ou un échec, au moins un tour + marge (45 min), puis 15 min doublées, plafonnée à 24 h" do
    assert_equal 15.minutes, item(attempts: 0).wait
    expected = { 0 => 45.minutes, 1 => 45.minutes, 2 => 45.minutes, 3 => 1.hour, 5 => 4.hours,
                 7 => 16.hours, 8 => 24.hours, 500 => 24.hours }
    expected.each do |attempts, wait|
      assert_equal wait, item(attempts: attempts, last_attempt_at: 1.minute.ago).wait, "#{attempts} tentatives"
    end
  end

  test "B1 : la garde après enqueue couvre le tour de reprise suivant" do
    assert_operator Crm::Backlog::REQUEUE_HOLD, :>, Crm::Backlog::RESYNC_PERIOD
    yaml = YAML.safe_load(Rails.root.join("config/recurring.yml").read, aliases: true)
    assert_equal "every #{Crm::Backlog::RESYNC_PERIOD.in_minutes.to_i} minutes",
                 yaml.dig("production", "crm_resync", "schedule"), "RESYNC_PERIOD suit config/recurring.yml"
  end

  test "next_attempt_at (429) : jamais dû avant, même si l'espacement est écoulé" do
    now = Time.current
    assert_not item(pending_since: 2.days.ago, next_attempt_at: 10.minutes.from_now).due?(now)
    assert item(pending_since: 2.days.ago, next_attempt_at: 1.minute.ago).due?(now)
  end

  test "defer : date, code 429, report, sans tentative comptée" do
    registration = registration("a@example.org", crm_sync_attempts: 2)
    freeze_time do
      Crm::Backlog.defer(:registrations, registration.id, Crm::RateLimitedError.new(retry_after: 7200), job: CrmSyncJob)
      registration.reload
      assert_equal [ 2, 429, Time.current, 2.hours.from_now ],
                   [ registration.crm_sync_attempts, registration.crm_last_error_code,
                     registration.crm_last_attempt_at, registration.crm_next_attempt_at ]
    end
  end

  test "dû selon la dernière tentative, ou à défaut le début de l'attente" do
    now = Time.current
    assert item(attempts: 0, pending_since: 20.minutes.ago).due?(now)
    assert_not item(attempts: 0, pending_since: 5.minutes.ago).due?(now)
    assert_not item(attempts: 3, pending_since: 2.days.ago, last_attempt_at: 30.minutes.ago).due?(now)
    assert item(attempts: 3, pending_since: 2.days.ago, last_attempt_at: 2.hours.ago).due?(now)
    assert_not item(attempts: 0, pending_since: 2.days.ago, last_attempt_at: 31.minutes.ago).due?(now)
    assert item(attempts: 0, pending_since: 2.days.ago, last_attempt_at: 46.minutes.ago).due?(now)
  end

  test "échec permanent = 4xx hors 429" do
    assert item(error_code: 422).permanent_failure?
    assert item(error_code: 404).permanent_failure?
    assert_not item(error_code: 429).permanent_failure?
    assert_not item(error_code: 503).permanent_failure?
    assert_not item(error_code: nil).permanent_failure?
  end

  test "items : trois files, attente datée par l'événement qui l'a ouverte" do
    participant = registration("a@example.org", crm_enrolled_at: 3.hours.ago)
    consent = registration("b@example.org", crm_enrolled_at: 9.days.ago, pushed_to_crm_at: 9.days.ago,
                                     marketing_consent: true, marketing_consent_at: 2.hours.ago)
    withdrawal = registration("c@example.org", pushed_to_crm_at: 1.day.ago, crm_contact_id: "4",
                                        marketing_consent_withdrawn_at: 1.hour.ago, crm_withdrawal_attempts: 2)
    request = RegistrationRequest.create!(name: "L", email: "l@example.org", notify_next: true, confirmed_at: 4.hours.ago)

    items = Crm::Backlog.new.items.index_by { |item| [ item.queue, item.id ] }

    assert_in_delta 3.hours.ago, items[[ :registrations, participant.id ]].pending_since, 2
    assert_in_delta 2.hours.ago, items[[ :registrations, consent.id ]].pending_since, 2
    assert_equal 2, items[[ :withdrawals, withdrawal.id ]].attempts
    assert_equal CrmNotifyNextJob, items[[ :notify_next, request.id ]].job_class
  end

  test "« préviens-moi » : datée par l'étape due — confirmation, accord, puis retrait" do
    request = RegistrationRequest.create!(name: "L", email: "l@example.org", notify_next: true, confirmed_at: 9.days.ago)
    since = -> { Crm::Backlog.new.items.find { |item| item.queue == :notify_next && item.id == request.id }&.pending_since }
    assert_in_delta 9.days.ago, since.call, 2

    request.update!(pushed_to_crm_at: 9.days.ago, marketing_consent: true, marketing_consent_at: 2.hours.ago)
    assert_in_delta 2.hours.ago, since.call, 2

    request.update!(crm_marketing_consent_pushed_at: 2.hours.ago, marketing_consent: false,
                    marketing_consent_withdrawn_at: 1.hour.ago)
    assert_in_delta 1.hour.ago, since.call, 2, "pas de faux 503 de la sonde (> 24 h) sur un retrait récent"
  end

  test "reset_schedule : tout redevient dû, compteurs à zéro" do
    stuck = registration("a@example.org", crm_sync_attempts: 9, crm_last_attempt_at: 1.minute.ago,
                                   crm_next_attempt_at: 1.hour.from_now,
                                   crm_contact_id: "4", marketing_consent_withdrawn_at: 1.hour.ago,
                                   crm_withdrawal_attempts: 4, crm_withdrawal_last_attempt_at: 1.minute.ago,
                                   crm_withdrawal_next_attempt_at: 1.hour.from_now)
    Crm::Backlog.new.reset_schedule
    stuck.reload
    assert_equal [ 0, nil, nil, 0, nil, nil ],
                 [ stuck.crm_sync_attempts, stuck.crm_last_attempt_at, stuck.crm_next_attempt_at,
                   stuck.crm_withdrawal_attempts, stuck.crm_withdrawal_last_attempt_at,
                   stuck.crm_withdrawal_next_attempt_at ]
  end

  private

  def item(attempts: 0, pending_since: 1.hour.ago, last_attempt_at: nil, next_attempt_at: nil, error_code: nil)
    Item.new(queue: :registrations, job_class: CrmSyncJob, id: 1, pending_since: pending_since, attempts: attempts,
             last_attempt_at: last_attempt_at, next_attempt_at: next_attempt_at, error_code: error_code)
  end

  def registration(email, **attrs)
    @webinar.registrations.create!(name: "P", email: email, confirmed_at: Time.current,
                                   crm_enrolled_at: Time.current, **attrs)
  end
end
