# Replay d'un direct terminé, réservé aux personnes identifiées : la vidéo
# de référence (le composite de la séance, dont l'horloge cale les
# sous-titres), une copie de diffusion facultative qui la remplace à la
# lecture (`derived_path`, relatif à RECORDINGS_ROOT), et la date de
# publication (vide = non publié). Supprimé avec sa vidéo de référence
# (purge de rétention des enregistrements).
class CreateReplays < ActiveRecord::Migration[8.1]
  def change
    create_table :replays do |t|
      t.references :webinar, null: false, foreign_key: true, index: { unique: true }
      t.references :recording, null: false, foreign_key: { on_delete: :cascade }
      t.string :derived_path
      t.datetime :published_at
      t.timestamps
    end
  end
end
