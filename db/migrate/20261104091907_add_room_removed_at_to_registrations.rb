# Modération du direct : un spectateur retiré de la
# salle par l'animation l'est durablement, comme un intervenant révoqué
# (`speakers.revoked_at`). Additive et nullable : aucune ligne existante ne
# change de sens (nul = jamais retiré).
class AddRoomRemovedAtToRegistrations < ActiveRecord::Migration[8.1]
  def change
    add_column :registrations, :room_removed_at, :datetime
  end
end
