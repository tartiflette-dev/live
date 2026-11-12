# Une tournée du rappel de la veille : compteurs par issue, sans donnée
# personnelle (docs/registration-reminders.md §Supervision).
class RegistrationReminderRun < ApplicationRecord
  OUTCOMES = %i[sent skipped smtp_retry abandoned failed].freeze
  RETENTION = 30.days

  def self.record!(due:, outcomes:, now: Time.current)
    where(ran_at: ...(now - RETENTION)).delete_all
    create!(ran_at: now, due: due, **OUTCOMES.index_with { |outcome| outcomes.fetch(outcome, 0) })
  end

  # Bloc `reminders` de la sonde : dernier passage et cumuls du jour (Paris).
  def self.status(now = Time.current)
    last = order(ran_at: :desc).first
    today = where(ran_at: now.in_time_zone.all_day)
    {
      last_run_at: last&.ran_at&.iso8601,
      last_run: last&.slice(:due, *OUTCOMES),
      today: OUTCOMES.index_with { |outcome| today.sum(outcome) }
    }
  end

  def to_log_line
    "registration_reminder due=#{due} " + OUTCOMES.map { |outcome| "#{outcome}=#{self[outcome]}" }.join(" ")
  end
end
