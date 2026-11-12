# Instant où l'egress d'une piste a écrit son premier échantillon (horloge du
# serveur egress, passage EGRESS_ACTIVE). L'egress de piste rebase le fichier
# à 0 sur ce premier échantillon : pour une caméra, c'est la première image
# clé, jusqu'à 1,6 s après le démarrage demandé. `started_at` (heure de la
# demande) ne dit donc pas où commence le fichier ; ParticipantMux recale les
# pistes sur cette colonne. Vide pour les pistes antérieures (sauf reprise par
# `recordings:activations`) et si le webhook egress_updated n'est pas parvenu.
class AddMediaStartedAtToRecordings < ActiveRecord::Migration[8.1]
  def change
    add_column :recordings, :media_started_at, :datetime
  end
end
