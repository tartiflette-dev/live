# Montage par personne : une identité peut recevoir
# plusieurs montages, un par lot de pistes terminées. Cas rencontré en direct :
# l'intervenant `speaker-9` avait un montage de la répétition ; le montage
# de la séance n'a jamais été produit parce que le job, idempotent par
# (webinaire, identité), voyait « déjà fait ».
#
# `source_track_ids` = ids triés des pistes (`kind='track'`, `done`) que le
# montage COUVRE ; il en assemble au plus une caméra et un micro. L'unicité
# passe de (webinaire, identité) à (webinaire, identité, lot) : deux jobs
# concurrents sur le même lot restent arrêtés par la base, un nouveau lot
# obtient sa propre ligne.
#
# Lignes existantes : leur lot = les pistes terminées de la personne qui
# l'étaient AVANT le dernier démarrage du montage (`started_at`), c'est-à-
# dire celles que le job a pu voir. Les pistes terminées après (la séance
# de speaker-9) ne sont couvertes par aucun montage : un prochain passage
# du job en fait un nouveau, sans toucher à l'ancien fichier.
class AllowSeveralParticipantMuxes < ActiveRecord::Migration[8.1]
  def up
    remove_index :recordings, name: "index_recordings_on_participant_identity"
    add_column :recordings, :source_track_ids, :json
    backfill_source_track_ids!
    add_index :recordings, %i[webinar_id participant_identity source_track_ids],
              unique: true,
              where: "kind = 'participant'",
              name: "index_recordings_on_participant_sources"
  end

  def down
    remove_index :recordings, name: "index_recordings_on_participant_sources"
    remove_column :recordings, :source_track_ids
    # Échoue (contrainte) si une identité a déjà plusieurs montages : les
    # fichiers existent, la base ne doit pas en oublier un en silence.
    add_index :recordings, %i[webinar_id participant_identity],
              unique: true,
              where: "kind = 'participant'",
              name: "index_recordings_on_participant_identity"
  end

  private

  # Modèle de migration : indépendant de Recording, qui évoluera.
  class MuxRecording < ActiveRecord::Base
    self.table_name = "recordings"
  end

  # Dates comparées en Ruby, relues par le type datetime : sous SQLite une
  # borne SQL compare du texte, et une ligne écrite hors ActiveRecord
  # (« 2026-10-30T09:09:00Z ») tomberait du mauvais côté.
  def backfill_source_track_ids!
    MuxRecording.reset_column_information
    MuxRecording.where(kind: "participant").find_each do |mux|
      tracks = MuxRecording.where(kind: "track", status: "done", webinar_id: mux.webinar_id,
                                  participant_identity: mux.participant_identity).order(:id).to_a
      tracks = tracks.select { |track| track.ended_at && track.ended_at <= mux.started_at } if mux.started_at
      mux.update_columns(source_track_ids: tracks.map(&:id))
    end
  end
end
