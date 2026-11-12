# Journal des recherches dans les replays : chaque requête, même sans
# résultat, avec son auteur (compte utilisateur OU inscription) et le nombre de
# résultats — la demande des spectateurs. Part avec l'inscription
# (effacement, rétention) ou le compte ; au plus 12 mois (RetentionPurgeJob).
class CreateReplaySearches < ActiveRecord::Migration[8.1]
  def change
    create_table :replay_searches do |t|
      t.string :query, null: false, limit: 100
      t.string :normalized_query, null: false, limit: 100
      t.integer :results_count, null: false
      t.references :registration, foreign_key: { on_delete: :cascade }
      t.references :user, foreign_key: { on_delete: :cascade }
      t.datetime :created_at, null: false
    end
    add_index :replay_searches, :created_at
    add_index :replay_searches, :normalized_query
    add_check_constraint :replay_searches, "(registration_id IS NULL) <> (user_id IS NULL)",
                         name: "replay_searches_one_author"
  end
end
