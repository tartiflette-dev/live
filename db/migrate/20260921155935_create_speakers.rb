class CreateSpeakers < ActiveRecord::Migration[8.1]
  def change
    create_table :speakers do |t|
      t.references :webinar, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :speakers, :token, unique: true
  end
end
