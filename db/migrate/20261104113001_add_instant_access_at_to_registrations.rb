# Accès immédiat pendant le direct : une inscription créée
# pendant le direct, ou le quart d'heure qui le précède, ouvre la salle avant
# la confirmation du mail. Additive et nullable : nul = accès par la seule
# confirmation, comme avant.
class AddInstantAccessAtToRegistrations < ActiveRecord::Migration[8.1]
  def change
    add_column :registrations, :instant_access_at, :datetime
  end
end
