# Présence des animateurs (docs/host-presence.md) : une ligne par animateur ×
# webinaire — le propriétaire (`webinar_host_id` nul, une seule par webinaire)
# et chaque co-animateur (une seule par WebinarHost). Retirer un co-animateur
# ou supprimer le webinaire efface sa ligne, et son jeton cesse de résoudre.
class CreateHostAttendances < ActiveRecord::Migration[8.1]
  def change
    create_table :host_attendances do |t|
      t.references :webinar, null: false, foreign_key: { on_delete: :cascade }
      t.references :webinar_host, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :token, null: false, index: { unique: true }
      t.string :answer
      t.datetime :answered_at
      t.datetime :answered_for_starts_at
      t.datetime :requested_at
      t.datetime :requested_for_starts_at
      t.datetime :reminded_for_starts_at
      t.timestamps
    end
    add_index :host_attendances, :webinar_id, unique: true, where: "webinar_host_id IS NULL",
                                               name: "index_host_attendances_on_owner"
  end
end
