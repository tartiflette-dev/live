# Accord à l'image d'un participant qui n'anime pas de droit :
# intervenant, co-animateur invité ou
# spectateur à qui la parole est donnée. La preuve, figée au moment où la
# personne allume caméra ou micro, de ce qu'elle a accepté, sous quel libellé
# et quelle version de /confidentialite, et de l'identité LiveKit sous
# laquelle elle apparaît dans les enregistrements.
#
# Une ligne par accord donné, jamais modifiée sauf `withdrawn_at` : un
# nouvel accord après un retrait est une nouvelle ligne. L'index unique
# partiel garde au plus un accord en cours par personne et par webinaire
# (deux onglets ; un co-animateur anime plusieurs webinaires).
#
# Porteur polymorphe sans clé étrangère (Speaker, Registration ou User) : la
# preuve survit à la purge des inscriptions (12 mois) tant que les
# enregistrements qu'elle couvre existent (3 ans, RetentionPurgeJob).
# Additive : aucune table existante ne change.
class CreateParticipantConsents < ActiveRecord::Migration[8.1]
  def change
    create_table :participant_consents do |t|
      t.references :webinar, null: false, foreign_key: true
      t.string :holder_type, null: false
      t.integer :holder_id, null: false
      t.string :participant_identity, null: false, limit: 128
      t.boolean :recording_accepted, null: false
      t.boolean :excerpts_accepted, null: false
      t.boolean :adult_declared, null: false
      t.string :policy_version, null: false
      t.string :recording_label, null: false
      t.string :excerpts_label, null: false
      t.string :adult_label, null: false
      t.datetime :consented_at, null: false
      t.datetime :withdrawn_at
      t.timestamps
    end
    add_index :participant_consents, [ :holder_type, :holder_id ]
    add_index :participant_consents, [ :webinar_id, :participant_identity ], name: "index_participant_consents_on_webinar_and_identity"
    add_index :participant_consents, [ :webinar_id, :holder_type, :holder_id ], unique: true, where: "withdrawn_at IS NULL",
              name: "one_current_participant_consent_per_holder"
  end
end
