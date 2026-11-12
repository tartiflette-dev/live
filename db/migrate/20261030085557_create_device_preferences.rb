# Préférences de périphériques par participant identifié :
# une ligne par animateur (User) ou
# intervenant (Speaker). Colonnes nullables : « jamais choisi » se
# distingue d'un choix.
class CreateDevicePreferences < ActiveRecord::Migration[8.1]
  def change
    create_table :device_preferences do |t|
      t.references :owner, polymorphic: true, null: false, index: { unique: true }
      t.string :audio_input_device_id
      t.string :audio_input_label
      t.string :video_input_device_id
      t.string :video_input_label
      t.boolean :audio_enabled
      t.boolean :video_enabled
      t.timestamps
    end
  end
end
