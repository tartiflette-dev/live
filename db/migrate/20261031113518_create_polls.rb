# Sondages du direct. Format de question : type choice | scale |
# short_text, options ; `multiple` est propre au direct.
class CreatePolls < ActiveRecord::Migration[8.1]
  def change
    create_table :polls do |t|
      t.references :webinar, null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.string :kind, null: false
      t.boolean :multiple, null: false, default: false
      t.string :label, null: false
      t.json :options
      t.integer :planned_minute
      t.text :note
      t.datetime :opened_at
      t.datetime :closed_at
      t.datetime :results_shown_at
      t.timestamps
    end
    add_index :polls, [ :webinar_id, :position ]
    add_index :polls, :webinar_id, unique: true, name: "index_polls_one_open_per_webinar",
      where: "opened_at IS NOT NULL AND closed_at IS NULL"

    create_table :poll_responses do |t|
      t.references :poll, null: false, foreign_key: true, index: false
      t.string :respondent_identity, null: false
      t.references :registration, foreign_key: true
      t.string :name, null: false
      t.json :value, null: false
      t.timestamps
    end
    add_index :poll_responses, [ :poll_id, :respondent_identity ], unique: true
  end
end
