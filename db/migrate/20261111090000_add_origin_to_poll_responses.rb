# Réponses aux sondages données depuis le replay : `origin` = "live" (le
# direct, défaut des lignes existantes) ou "replay". Une réponse du replay
# vient d'une inscription (identité viewer-<id>, comme au direct) ou d'un
# compte undust (`user_id`, identité account-<id>), jamais des deux ; elle
# part avec le compte.
class AddOriginToPollResponses < ActiveRecord::Migration[8.1]
  def change
    add_column :poll_responses, :origin, :string, null: false, default: "live"
    add_reference :poll_responses, :user, foreign_key: { on_delete: :cascade }
    add_check_constraint :poll_responses, "origin IN ('live', 'replay')", name: "poll_responses_origin"
    add_check_constraint :poll_responses,
                         "origin = 'live' OR ((registration_id IS NULL) <> (user_id IS NULL))",
                         name: "poll_responses_replay_one_viewer"
  end
end
