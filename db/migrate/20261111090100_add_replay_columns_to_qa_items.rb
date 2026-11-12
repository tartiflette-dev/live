# Questions posées depuis le replay (source "replay") : instant de la vidéo
# de référence (`video_position`, en secondes) et auteur — inscription OU
# compte undust, jamais les deux. Elles partent avec l'inscription
# (effacement, rétention) ou le compte.
class AddReplayColumnsToQaItems < ActiveRecord::Migration[8.1]
  def change
    add_column :qa_items, :video_position, :float
    add_reference :qa_items, :registration, foreign_key: { on_delete: :cascade }
    add_reference :qa_items, :user, foreign_key: { on_delete: :cascade }
    add_check_constraint :qa_items,
                         "source <> 'replay' OR (video_position IS NOT NULL AND (registration_id IS NULL) <> (user_id IS NULL))",
                         name: "qa_items_replay_author"
    add_check_constraint :qa_items, "source = 'replay' OR (registration_id IS NULL AND user_id IS NULL)",
                         name: "qa_items_live_without_replay_author"
    add_index :qa_items, %i[source status]
  end
end
