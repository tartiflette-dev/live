# Journal des tournées du rappel de la veille (RegistrationReminderJob) :
# compteurs seulement, aucune donnée personnelle. Lu par la sonde
# /internal/crm_status (bloc `reminders`), conservé 30 jours.
class CreateRegistrationReminderRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :registration_reminder_runs do |t|
      t.datetime :ran_at, null: false
      t.integer :due, null: false, default: 0
      t.integer :sent, null: false, default: 0
      t.integer :skipped, null: false, default: 0
      t.integer :smtp_retry, null: false, default: 0
      t.integer :abandoned, null: false, default: 0
      t.integer :failed, null: false, default: 0
    end
    add_index :registration_reminder_runs, :ran_at
  end
end
