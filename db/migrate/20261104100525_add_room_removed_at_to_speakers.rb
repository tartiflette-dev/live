# Retirer ≠ révoquer : `speakers.revoked_at` = le lien est mort
# (révocation par le propriétaire ou par la régie) ; `room_removed_at` = la
# personne a été retirée de la salle depuis la régie, son navigateur avec.
# Seule la régie le pose. Additive et nullable : aucune ligne existante ne
# change de sens.
class AddRoomRemovedAtToSpeakers < ActiveRecord::Migration[8.1]
  def change
    add_column :speakers, :room_removed_at, :datetime
  end
end
