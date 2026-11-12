# Discussion du direct. Additive : une table
# neuve, aucune colonne existante touchée. `author_identity` reprend le
# format des identités LiveKit (host-<sub>, speaker-<id>, viewer-<id>),
# comme transcript_segments.participant_identity, pour aligner fil et
# transcript au montage. L'index composite sert le curseur de rattrapage
# (updated_at, id) et, par son préfixe, toute lecture par webinaire.
class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.references :webinar, null: false, foreign_key: true, index: false
      t.string :author_identity, limit: 128, null: false
      t.string :name, limit: 120, null: false
      t.text :body, null: false
      t.string :kind, null: false, default: "chat"
      t.datetime :answered_at
      t.datetime :pinned_at
      t.timestamps
    end
    add_index :messages, [ :webinar_id, :updated_at, :id ]
  end
end
