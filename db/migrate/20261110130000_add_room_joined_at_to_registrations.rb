# Première arrivée d'un inscrit dans la salle du direct (RoomAttendance) :
# en spectateur (`viewer-<id>`) ou en intervenant rattaché à son inscription
# (`speaker-<id>`, Speaker#registration). Relevée par le webhook LiveKit
# `participant_joined` et par la lecture de la salle depuis la régie. Vide =
# jamais vu dans la salle (ou venu avant que la colonne existe).
class AddRoomJoinedAtToRegistrations < ActiveRecord::Migration[8.1]
  def change
    add_column :registrations, :room_joined_at, :datetime
  end
end
