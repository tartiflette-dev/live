# Version de chaque assemblage dont le dépôt vient d'être vérifié, notée
# aussitôt (EpisodePublication#record_deposited_version!) : une reprise après
# un échec ne renvoie plus un assemblage déjà déposé à la bonne version.
# Vidée à la fin d'un dépôt abouti, où les versions passent dans `files`.
class AddDepositedVersionsToEpisodePublications < ActiveRecord::Migration[8.1]
  def change
    add_column :episode_publications, :deposited_versions, :json, default: {}, null: false
  end
end
