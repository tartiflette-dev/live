# Changement de date ou dépublication d'un webinaire publié : ce que ses
# inscrits confirmés savent (dernier état annoncé) et à qui chaque annonce
# est déjà partie (WebinarChangeNotice). Les deux tables suivent la vie du
# webinaire et des inscriptions : effacer l'un ou l'autre efface la trace.
class CreateWebinarChangeNotices < ActiveRecord::Migration[8.1]
  def change
    create_table :webinar_change_notices do |t|
      t.references :webinar, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.datetime :starts_at, null: false
      t.boolean :published, null: false
      t.integer :revision, null: false, default: 0
      t.datetime :changed_at, null: false
      t.datetime :notified_at
      t.timestamps
    end

    create_table :webinar_change_deliveries do |t|
      t.references :webinar_change_notice, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :registration, null: false, foreign_key: { on_delete: :cascade }
      t.integer :revision, null: false
      t.string :kind, null: false
      t.datetime :created_at, null: false
    end
    add_index :webinar_change_deliveries, %i[webinar_change_notice_id revision registration_id], unique: true,
              name: "index_webinar_change_deliveries_once"
  end
end
