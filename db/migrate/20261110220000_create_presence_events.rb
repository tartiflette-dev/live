# Journal de présence d'un webinaire (PresenceEvent) : arrivées et départs
# dans la salle LiveKit, connexions interrompues, refus de la garde, fin de
# salle, et tentatives vues par l'app (page ouverte, accès à la salle
# délivré). Aucun nom ni adresse : l'identité LiveKit opaque (`viewer-<id>`,
# `speaker-<id>`, `host-<sub>`) désigne la personne, résolue à la lecture.
# Même terme que les inscriptions (RetentionPurgeJob).
#
# `livekit_event_id` : identifiant du webhook LiveKit (EV_…), unique — un
# webhook rejoué, ou réimporté depuis le journal du serveur, ne compte
# qu'une fois.
class CreatePresenceEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :presence_events do |t|
      t.references :webinar, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :kind, null: false
      t.string :identity
      t.datetime :occurred_at, null: false
      t.string :source, null: false
      t.string :livekit_event_id
      t.datetime :created_at, null: false
    end
    add_index :presence_events, %i[webinar_id occurred_at]
    add_index :presence_events, %i[webinar_id identity kind occurred_at], name: "index_presence_events_on_attempts"
    add_index :presence_events, :livekit_event_id, unique: true, where: "livekit_event_id IS NOT NULL"
  end
end
