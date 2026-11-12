# Fin automatique du direct : la
# salle LiveKit d'un direct en cours s'est vidée (`room_finished`). Posé à
# ce moment, effacé dès qu'un participant revient ou que l'état du direct
# change. Le job de fin automatique ne termine le direct que si la salle
# est restée vide depuis au moins 15 min (AutoEndLiveJob).
class AddRoomEmptySinceToWebinars < ActiveRecord::Migration[8.1]
  def change
    add_column :webinars, :room_empty_since, :datetime
  end
end
