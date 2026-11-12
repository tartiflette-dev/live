# Instant où la personne a choisi « J'observe » ou « Je participe » pour ce
# webinaire : au formulaire qui le demande (inscription publique, lien
# participants privé, API qui transmet le choix) ou à l'entrée de la salle
# (ParticipationsController). Vide = jamais choisi (inscription venue d'un
# site qui n'envoie pas le choix, ou antérieure) : la salle le demande
# avant d'entrer, une fois.
class AddParticipationChosenAtToRegistrations < ActiveRecord::Migration[8.1]
  def change
    add_column :registrations, :participation_chosen_at, :datetime
  end
end
