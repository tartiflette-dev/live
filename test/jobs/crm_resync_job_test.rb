# frozen_string_literal: true

require "test_helper"

class CrmResyncJobTest < ActiveJob::TestCase
  setup do
    @prev_flag = ENV["CRM_SYNC_ENABLED"]
    ENV["CRM_SYNC_ENABLED"] = "1"
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.day.from_now, host_sub: "h", visibility: "published")
    # Publier demande la présence des animateurs (HostAttendanceRequestJob) :
    # hors sujet ici, la file repart vide.
    clear_enqueued_jobs
  end

  teardown { ENV["CRM_SYNC_ENABLED"] = @prev_flag }

  test "ré-enqueue les inscriptions, « préviens-moi » et retraits DUS (passé le délai de grâce)" do
    pending = enrolled("a@example.org", crm_enrolled_at: 1.hour.ago)
    enrolled("b@example.org", pushed_to_crm_at: Time.current)
    request = RegistrationRequest.create!(name: "Lou", email: "lou@example.org", notify_next: true, confirmed_at: 1.hour.ago)
    RegistrationRequest.create!(name: "Max", email: "max@example.org", notify_next: true)
    withdrawn = enrolled("c@example.org", pushed_to_crm_at: 1.day.ago, crm_contact_id: "9",
                                   marketing_consent_withdrawn_at: 1.hour.ago)

    CrmResyncJob.perform_now

    assert_enqueued_with(job: CrmSyncJob, args: [ pending.id ])
    assert_enqueued_with(job: CrmNotifyNextJob, args: [ request.id ])
    assert_enqueued_with(job: CrmMarketingWithdrawalJob, args: [ withdrawn.id ])
    assert_enqueued_jobs 3
  end

  test "délai de grâce : une confirmation récente est laissée au job lancé à la confirmation" do
    enrolled("frais@example.org", crm_enrolled_at: 2.minutes.ago)
    CrmResyncJob.perform_now
    assert_no_enqueued_jobs
  end

  test "un enqueue de la reprise n'est pas répété au tour suivant (31 min), seulement à celui d'après (46 min+)" do
    registration = enrolled("a@example.org", crm_enrolled_at: 1.hour.ago)
    CrmResyncJob.perform_now
    assert_enqueued_jobs 1
    assert_not_nil registration.reload.crm_last_attempt_at
    clear_enqueued_jobs

    travel 31.minutes do
      CrmResyncJob.perform_now
      assert_no_enqueued_jobs # le job peut encore être en file ou dans sa chaîne de retry
    end
    travel 46.minutes do
      CrmResyncJob.perform_now
      assert_enqueued_with(job: CrmSyncJob, args: [ registration.id ])
    end
  end

  test "SÉCURITÉ : aucune reprise des confirmés v1.0 (pas de rétroactivité)" do
    @webinar.registrations.create!(name: "Old", email: "old@example.org", confirmed_at: 1.month.ago)
    CrmResyncJob.perform_now
    assert_no_enqueued_jobs
  end

  test "pas de gel — après des dizaines d'échecs, encore retenté, au plus tard toutes les 24 h" do
    stuck = enrolled("stuck@example.org", crm_enrolled_at: 1.week.ago, crm_sync_attempts: 60,
                                   crm_last_error_code: 503, crm_last_attempt_at: 23.hours.ago)
    CrmResyncJob.perform_now
    assert_no_enqueued_jobs # moins de 24 h depuis le dernier essai : on attend

    stuck.update_columns(crm_last_attempt_at: 25.hours.ago)
    CrmResyncJob.perform_now
    assert_enqueued_with(job: CrmSyncJob, args: [ stuck.id ])
  end

  test "l'attente double après chaque échec, à partir de 15 min" do
    registration = enrolled("a@example.org", crm_enrolled_at: 1.day.ago, crm_sync_attempts: 3,
                                      crm_last_error_code: 502, crm_last_attempt_at: 59.minutes.ago)
    CrmResyncJob.perform_now
    assert_no_enqueued_jobs # 3 échecs : 15 min × 2² = 1 h

    registration.update_columns(crm_last_attempt_at: 61.minutes.ago)
    CrmResyncJob.perform_now
    assert_enqueued_jobs 1
  end

  test "le retrait a son PROPRE compteur — une inscription en échec ne le retarde pas" do
    registration = enrolled("a@example.org", crm_enrolled_at: 1.week.ago, crm_sync_attempts: 60, crm_last_error_code: 422,
                                      crm_last_attempt_at: 1.hour.ago, crm_contact_id: "9",
                                      marketing_consent_withdrawn_at: 1.hour.ago)
    CrmResyncJob.perform_now
    assert_enqueued_with(job: CrmMarketingWithdrawalJob, args: [ registration.id ])
    # Seul le retrait est dû ; la poussée du participant attend son espacement.
    assert_enqueued_jobs 1
  end

  test "force (crm:requeue) : tout ce qui est en attente, sans espacement ni délai de grâce" do
    enrolled("frais@example.org", crm_enrolled_at: 1.minute.ago)
    enrolled("stuck@example.org", crm_enrolled_at: 1.week.ago, crm_sync_attempts: 9, crm_last_attempt_at: 1.minute.ago)
    CrmResyncJob.perform_now(force: true)
    assert_enqueued_jobs 2
  end

  test "journal lisible sans PII, warn dès qu'une ligne échoue" do
    enrolled("retry@example.org", crm_enrolled_at: 1.day.ago, crm_sync_attempts: 3, crm_last_error_code: 404)
    enrolled("ok@example.org", crm_enrolled_at: 1.day.ago)
    io = StringIO.new
    original = Rails.logger
    Rails.logger = Logger.new(io)
    begin
      CrmResyncJob.perform_now
    ensure
      Rails.logger = original
    end
    assert_match(/WARN .*crm_resync pending=2 enqueued=2 failing=1 permanent_failures=1/, io.string)
    assert_no_match(/retry@|ok@/, io.string)
  end

  test "drapeau off : rien" do
    ENV["CRM_SYNC_ENABLED"] = "0"
    enrolled("a@example.org", crm_enrolled_at: 1.day.ago)
    CrmResyncJob.perform_now
    assert_no_enqueued_jobs
  end

  test "une ContractError est un échec permanent compté, daté, visible de la sonde" do
    registration = enrolled("a@example.org")
    failing = FakeCrmClient.new(raise_on: :search, raise_class: Crm::ContractError)
    stub = Module.new { define_method(:build_client) { failing } }
    CrmSyncJob.prepend(stub)
    begin
      CrmSyncJob.perform_now(registration.id)
    ensure
      stub.module_eval { define_method(:build_client) { super() } }
    end
    registration.reload
    assert_equal [ 1, 422 ], [ registration.crm_sync_attempts, registration.crm_last_error_code ]
    assert_not_nil registration.crm_last_attempt_at
    assert Crm::Backlog.new.items.first.permanent_failure?
  end

  test "une erreur permanente compte comme une tentative et date l'essai" do
    registration = enrolled("a@example.org")
    failing = FakeCrmClient.new(raise_on: :search, raise_class: Crm::PermanentError, http_status: 422)
    stub = Module.new { define_method(:build_client) { failing } }
    CrmSyncJob.prepend(stub)
    begin
      CrmSyncJob.perform_now(registration.id)
    ensure
      stub.module_eval { define_method(:build_client) { super() } }
    end
    registration.reload
    assert_equal 1, registration.crm_sync_attempts
    assert_equal 422, registration.crm_last_error_code
    assert_not_nil registration.crm_last_attempt_at
  end

  test "câblé en production dans config/recurring.yml" do
    yaml = YAML.safe_load(Rails.root.join("config/recurring.yml").read, aliases: true)
    assert_equal "CrmResyncJob", yaml.dig("production", "crm_resync", "class")
  end

  private

  def enrolled(email, **attrs)
    @webinar.registrations.create!(name: "P", email: email, confirmed_at: Time.current,
                                   crm_enrolled_at: Time.current, **attrs)
  end
end
