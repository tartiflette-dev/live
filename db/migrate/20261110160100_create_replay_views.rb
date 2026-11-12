# Une séance de visionnage d'un replay : un onglet, une personne (inscription
# OU compte), alimentée par les battements du lecteur. `intervals` = passages
# vus, en secondes de la vidéo, fusionnés ([[début, fin], …]) ;
# `watched_seconds` = temps de lecture cumulé (un passage revu compte deux
# fois). Supprimée avec l'inscription ou le compte (effacement, rétention).
class CreateReplayViews < ActiveRecord::Migration[8.1]
  def change
    create_table :replay_views do |t|
      t.references :replay, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :registration, foreign_key: { on_delete: :cascade }
      t.references :user, foreign_key: { on_delete: :cascade }
      t.string :session_key, null: false
      t.datetime :started_at, null: false
      t.datetime :last_seen_at, null: false
      t.float :last_position, null: false, default: 0.0
      t.boolean :playing, null: false, default: false
      t.float :watched_seconds, null: false, default: 0.0
      t.json :intervals, null: false, default: []
      t.integer :beats_count, null: false, default: 0
      t.timestamps
    end
    add_index :replay_views, %i[replay_id session_key], unique: true
    add_check_constraint :replay_views, "(registration_id IS NULL) <> (user_id IS NULL)", name: "replay_views_one_viewer"
  end
end
