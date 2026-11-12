# Envois groupés décidés par un humain depuis l'écran d'envoi
# (WebinarAnnouncementsController, docs/announcements.md). Additive : deux
# tables neuves, aucune colonne existante touchée.
#
# `announcements` = le journal : cible, objet, corps, auteur (et son rôle sur
# le webinaire à l'envoi : quotas, Reply-To, journal), nombre de
# destinataires confirmé, horodatage. `dispatch_token` (unique) rend la
# confirmation idempotente : un double clic ne crée pas un second envoi.
#
# `announcement_deliveries` = un marqueur par destinataire, posé à la
# confirmation : l'empreinte de l'adresse (HMAC, CrmErasure.digest) au lieu de
# l'adresse en clair, et la référence de la fiche qui porte l'adresse
# (`holder`, inscription ou demande). crm:erase supprime les marqueurs de la
# personne avec ses fiches. L'index unique (envoi × empreinte) interdit le
# doublon. États : `enqueued_at` / `scheduled_at` (mis en file, posé avant la
# mise en file, et heure de remise prévue) ; `sending_at` (remise prise par UN
# job, claim conditionnel : un job rejoué ne renvoie pas) ; `delivered_at`
# (accepté par le serveur SMTP) ; `skipped_at` (plus dans la cible).
class CreateAnnouncements < ActiveRecord::Migration[8.1]
  def change
    create_table :announcements do |t|
      t.references :webinar, null: false, foreign_key: true
      t.string :audience, null: false
      t.string :subject, null: false
      t.text :body, null: false
      t.string :author_sub, null: false
      t.string :author_email, null: false
      t.string :author_role, null: false
      t.integer :recipients_count, null: false, default: 0
      t.string :dispatch_token, null: false
      t.timestamps
    end
    add_index :announcements, :dispatch_token, unique: true

    create_table :announcement_deliveries do |t|
      t.references :announcement, null: false, foreign_key: true, index: false
      t.string :recipient_digest, null: false
      t.string :holder_type, null: false
      t.bigint :holder_id, null: false
      t.datetime :enqueued_at
      t.datetime :scheduled_at
      t.datetime :sending_at
      t.datetime :delivered_at
      t.datetime :skipped_at
      t.timestamps
    end
    add_index :announcement_deliveries, [ :announcement_id, :recipient_digest ], unique: true,
                                       name: "index_announcement_deliveries_on_recipient"
  end
end
