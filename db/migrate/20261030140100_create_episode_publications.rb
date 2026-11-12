# Publication des épisodes dans Nextcloud :
# une ligne par webinaire, l'état de son dernier dépôt. Additive.
#
# `files` = fichiers déposés ET vérifiés (nom relatif au dossier
# d'épisode, taille en octets, zone : partagé ou relecture) ; `folder` et
# `review_folder` = dossiers partagé et de relecture de l'épisode ;
# `notified_emails` = intervenants déjà prévenus pour cette liste de
# fichiers, pour qu'une relance n'envoie jamais deux fois le même mail.
class CreateEpisodePublications < ActiveRecord::Migration[8.1]
  def change
    create_table :episode_publications do |t|
      t.references :webinar, null: false, foreign_key: true, index: { unique: true }
      t.string :status, null: false
      t.string :folder
      t.string :folder_url
      t.string :review_folder
      t.string :review_folder_url
      t.json :files, null: false, default: []
      t.json :notified_emails, null: false, default: []
      t.string :error_message
      t.integer :attempts, null: false, default: 0
      t.datetime :queued_at
      t.datetime :started_at
      t.datetime :published_at
      t.datetime :notified_at
      t.timestamps
    end
  end
end
