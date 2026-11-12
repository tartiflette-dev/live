# frozen_string_literal: true

require "test_helper"
require "rake"

# `bin/rails registrations:notify_team_backlog` — rattrapage du mail d'équipe
# (docs/registrations-api.md §Inscriptions transmises à l'équipe et à la communauté).
class RegistrationsNotifyTeamBacklogTaskTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "registrations:notify_team_backlog" }
    @task = Rake::Task["registrations:notify_team_backlog"]
    @task.reenable
    @saved_env = ENV.to_h.slice("CO_ORGANIZERS_NOTIFY_TO", "CONFIRM")
    ENV["CO_ORGANIZERS_NOTIFY_TO"] = "orga@tartiflette.test"
    ENV.delete("CONFIRM")
    @unread = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", source: "tartiflette.dev",
                                          message: "Je propose une présentation.", confirmed_at: 1.week.ago)
    @already_sent = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", source: "tartiflette.dev",
                                                message: "Déjà lu.", confirmed_at: 1.week.ago, team_notified_at: 1.day.ago)
  end

  teardown { %w[CO_ORGANIZERS_NOTIFY_TO CONFIRM].each { |key| ENV[key] = @saved_env[key] } }

  test "par défaut, simulation : liste les identifiants, n'envoie rien, sans PII à l'écran" do
    output = nil
    assert_no_enqueued_emails { output = capture_stdout { @task.invoke } }
    assert_match(/simulation \(destinataire configuré\) : 1 message\(s\) à transmettre/, output)
    assert_match(/##{@unread.id} reçue le/, output)
    assert_no_match(/##{@already_sent.id} /, output)
    assert_no_match(/camille|présentation/i, output)
    assert_nil @unread.reload.team_notified_at
  end

  test "CONFIRM=1 : envoie les messages jamais transmis, une fois ; rejouée, rien" do
    ENV["CONFIRM"] = "1"
    output = nil
    assert_enqueued_emails(1) { output = capture_stdout { @task.invoke } }
    assert_match(/1 message\(s\) transmis/, output)
    assert_not_nil @unread.reload.team_notified_at

    @task.reenable
    assert_no_enqueued_emails do
      assert_match(/0 message\(s\) transmis/, capture_stdout { @task.invoke })
    end
  end

  test "CONFIRM=1 sans CO_ORGANIZERS_NOTIFY_TO : abandon, rien de marqué" do
    ENV["CONFIRM"] = "1"
    ENV.delete("CO_ORGANIZERS_NOTIFY_TO")
    assert_raises(SystemExit) { capture_stderr { @task.invoke } }
    assert_nil @unread.reload.team_notified_at
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

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end
end
