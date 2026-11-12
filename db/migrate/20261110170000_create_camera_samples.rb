# Mesures de l'émetteur caméra relevées par le navigateur de chaque personne
# qui publie (rooms/camera_health.jsx), toutes les 10 s : couche la plus haute
# réellement émise, raison de la limite, encodeur, couches. Lues par la régie
# (alerte < 720p) et gardées CameraSample::RETENTION pour un diagnostic après
# coup (cas observé : une caméra émise en 320x180 tout le direct, cause
# invisible côté serveur).
class CreateCameraSamples < ActiveRecord::Migration[8.1]
  def change
    create_table :camera_samples do |t|
      t.references :webinar, null: false, foreign_key: true, index: false
      t.string :participant_identity, null: false
      t.string :publication_sid
      t.string :event, null: false, default: "sample"
      t.integer :top_width
      t.integer :top_height
      t.float :frames_per_second
      t.string :quality_limitation_reason
      t.string :encoder_implementation
      t.integer :capture_width
      t.integer :capture_height
      t.integer :paused_layers, null: false, default: 0
      t.json :layers, null: false, default: []
      t.datetime :created_at, null: false
    end
    add_index :camera_samples, [ :webinar_id, :participant_identity, :created_at ],
              name: "index_camera_samples_on_webinar_identity_time"
    add_index :camera_samples, :created_at
  end
end
