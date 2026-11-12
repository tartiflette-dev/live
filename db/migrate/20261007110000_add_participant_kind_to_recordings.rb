class AddParticipantKindToRecordings < ActiveRecord::Migration[8.1]
  # Mux par personne — un Recording synthétique `kind='participant'`
  # agrège la caméra H.264 et le micro Opus d'un participant, recalés sur
  # leurs started_at, pour produire UN .mp4 ou .m4a prêt au montage.
  #
  # Choix : étendre `kind` plutôt que créer un modèle dédié. Les tracks
  # et le participant partagent le même acteur (l'animateur qui veut un
  # fichier téléchargeable) et le même contrat d'accès disque
  # (`absolute_path`, défense traversal, `recordings_root`) : même acteur,
  # donc pas une duplication accidentelle à séparer.
  #
  # Invariant : au plus UN Recording participant par (webinar, identity).
  # Un relancement remplace le précédent (status=failed ou re-done après
  # update) — l'unicité DB double la garde applicative, comme pour le
  # composite actif (cf. migration 20260924143739).
  def change
    add_index :recordings, %i[webinar_id participant_identity],
              unique: true,
              where: "kind = 'participant'",
              name: "index_recordings_on_participant_identity"
  end
end
