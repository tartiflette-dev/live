# Journal des mises en avant du direct (RoomSpotlight) : l'état vit dans les
# métadonnées de la salle LiveKit, sans historique. Chaque changement posé
# par l'animation est horodaté ici pour que le montage du replay respecte
# un choix explicite (MontagePlan). `identity` vide = mise en avant retirée.
class CreateSpotlightChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :spotlight_changes do |t|
      t.references :webinar, null: false, foreign_key: true, index: false
      t.string :identity, limit: 256
      t.datetime :changed_at, null: false
      t.timestamps
    end
    add_index :spotlight_changes, [ :webinar_id, :changed_at ]
  end
end
