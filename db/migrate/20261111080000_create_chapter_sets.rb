# Chapitres d'un café : une proposition du LLM local,
# relue par l'animation avant d'être montrée aux spectateurs du replay.
#
# `chapter_sets` = l'état de la proposition, un par webinaire : issue du
# dernier passage du LLM, empreinte de la transcription qu'il a lue (une
# transcription qui change relance une proposition non validée), validation.
# `chapters` = titre court, instant de début (heure réelle, comme les
# segments de transcription : le replay le recale sur sa vidéo) et thèmes.
class CreateChapterSets < ActiveRecord::Migration[8.1]
  def change
    create_table :chapter_sets do |t|
      t.references :webinar, null: false, foreign_key: true, index: { unique: true }
      t.string :llm_outcome, limit: 40
      t.string :llm_model, limit: 120
      t.datetime :generated_at
      t.string :transcript_digest, limit: 80
      t.datetime :validated_at
      t.references :validated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end

    create_table :chapters do |t|
      t.references :chapter_set, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.datetime :starts_at, null: false
      t.string :title, null: false, limit: 120
      t.json :themes, null: false, default: []
      t.timestamps
    end
    add_index :chapters, %i[chapter_set_id starts_at]
  end
end
