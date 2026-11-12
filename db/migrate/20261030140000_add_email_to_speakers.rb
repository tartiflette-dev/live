# Publication des épisodes : une fois les
# fichiers du direct déposés dans Nextcloud, les intervenants reçoivent un
# mail (lien du dossier, liste des fichiers, durée). Un intervenant n'avait
# qu'un nom ; l'animation saisit désormais son adresse sur la page du
# webinaire. Facultative : sans adresse, pas de mail, rien d'autre ne change.
class AddEmailToSpeakers < ActiveRecord::Migration[8.1]
  def change
    add_column :speakers, :email, :string, limit: 254
  end
end
