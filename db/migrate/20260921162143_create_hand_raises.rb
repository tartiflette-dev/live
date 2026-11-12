class CreateHandRaises < ActiveRecord::Migration[8.1]
  def change
    create_table :hand_raises do |t|
      t.references :webinar, null: false, foreign_key: true
      t.references :registration, null: false, foreign_key: true
      t.datetime :raised_at, null: false
      t.datetime :granted_at
      t.datetime :revoked_at
      t.string :state, null: false, default: "waiting"
      t.string :last_error
      t.timestamps
    end
    add_index :hand_raises, :registration_id, unique: true, where: "revoked_at IS NULL", name: "one_active_hand_per_registration"
  end
end
