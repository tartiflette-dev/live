# frozen_string_literal: true

require "test_helper"
require "rake"

# `bin/rails crm:requeue` — remise en file documentée (docs/registrations-api.md).
class CrmRequeueTaskTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "crm:requeue" }
    @task = Rake::Task["crm:requeue"]
    @task.reenable
    @prev_flag = ENV["CRM_SYNC_ENABLED"]
    ENV["CRM_SYNC_ENABLED"] = "1"
    webinar = Webinar.create!(title: "Café IA", starts_at: 1.day.from_now, host_sub: "h", visibility: "published")
    # Publier demande la présence des animateurs (HostAttendanceRequestJob) :
    # hors sujet ici, la file repart vide.
    clear_enqueued_jobs
    @stuck = webinar.registrations.create!(name: "P", email: "stuck@example.org", confirmed_at: 2.days.ago,
                                           crm_enrolled_at: 2.days.ago, crm_sync_attempts: 40,
                                           crm_last_error_code: 404, crm_last_attempt_at: 1.minute.ago)
  end

  teardown { ENV["CRM_SYNC_ENABLED"] = @prev_flag }

  test "remet à zéro l'attente et enqueue tout de suite, sans PII à l'écran" do
    output = capture_stdout { @task.invoke }
    assert_enqueued_with(job: CrmSyncJob, args: [ @stuck.id ])
    assert_equal 0, @stuck.reload.crm_sync_attempts
    assert_match(/1 élément\(s\) remis en file/, output)
    assert_no_match(/stuck@/, output)
  end

  test "drapeau off : rien n'est enqueué ni modifié" do
    ENV["CRM_SYNC_ENABLED"] = "0"
    output = capture_stdout { @task.invoke }
    assert_no_enqueued_jobs
    assert_equal 40, @stuck.reload.crm_sync_attempts
    assert_match(/CRM_SYNC_ENABLED != 1/, output)
  end

  private

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
