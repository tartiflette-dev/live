# Transcript multi-locuteur en direct (archive segments).
#
# Un segment = résultat STT final d'une tranche de parole d'UNE piste micro
# distante. L'agent LiveKit (transcriber/) renvoie ces segments en direct
# dans la salle (text stream topic lk.transcription) ET les archive ici.
#
# Idempotence : (webinar_id, segment_id) unique — un double envoi
# accidentel ou un rejeu ne doit jamais créer deux lignes (l'agent, lui,
# ne retente pas un POST échoué). segment_id est le UUID produit par l'agent (jamais
# re-généré pour une même tranche).
class CreateTranscriptSegments < ActiveRecord::Migration[8.1]
  def change
    create_table :transcript_segments do |t|
      t.references :webinar, null: false, foreign_key: true, index: true
      t.string  :participant_identity, null: false, limit: 128
      t.string  :speaker_name,         null: true,  limit: 128
      t.text    :text,                 null: false
      t.datetime :started_at,          null: false
      t.datetime :ended_at,            null: false
      t.string :segment_id,           null: false, limit: 128
      t.timestamps
    end

    add_index :transcript_segments, [ :webinar_id, :segment_id ], unique: true
    add_index :transcript_segments, [ :webinar_id, :started_at ]
  end
end
