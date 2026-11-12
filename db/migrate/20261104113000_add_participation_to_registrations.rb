# Lien participants : à l'inscription, la personne choisit
# d'être spectatrice (regarder, discussion, main levée) ou participante
# (intervenir en caméra et micro). Additive, avec défaut : toute inscription
# existante reste ce qu'elle était, une spectatrice.
class AddParticipationToRegistrations < ActiveRecord::Migration[8.1]
  def change
    add_column :registrations, :participation, :string, null: false, default: "spectator"
  end
end
