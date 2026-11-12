# Lien participants privé (successeur de /i) : l'intervenant
# est rattaché à l'inscription de son adresse pour ce webinaire — un contact
# unique pour ses interventions. Nullable : les intervenants existants, sans
# adresse, restent valides. Une inscription effacée (purge, `crm:erase`)
# détache l'intervenant au lieu de bloquer la suppression.
class AddRegistrationToSpeakers < ActiveRecord::Migration[8.1]
  def change
    add_reference :speakers, :registration, null: true, index: true, foreign_key: { on_delete: :nullify }
  end
end
