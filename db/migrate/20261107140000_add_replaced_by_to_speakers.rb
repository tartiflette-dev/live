# Marque un intervenant dont le lien a été régénéré : la ligne reste
# (capacité, historique) mais l'admin doit la lire « remplacé », pas
# comme un second intervenant révoqué au même nom.
class AddReplacedByToSpeakers < ActiveRecord::Migration[8.1]
  def change
    add_reference :speakers, :replaced_by, foreign_key: { to_table: :speakers, on_delete: :nullify }, null: true
  end
end
