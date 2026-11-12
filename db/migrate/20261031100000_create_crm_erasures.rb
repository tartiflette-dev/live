# Fiches CRM effacées ou disparues :
# - `crm_erasures` : effacements EXPLICITES (`bin/rails crm:erase`), seule
#   source d'autorisation d'une recréation. Empreinte HMAC-SHA256 de l'email
#   (clé dérivée dédiée, jamais l'email en clair), date du DERNIER effacement.
# - `crm_disappearances` : disparitions DÉDUITES (404 de preuve + lookup
#   vide), par id CRM, pour la visibilité. N'autorisent jamais rien.
# - État terminal PAR FILE d'une ligne dont la fiche est partie :
#   `registrations.crm_sync_contact_gone_at` (inscription / consentement) et
#   `registration_requests.crm_contact_gone_at` (« préviens-moi »). Le
#   retrait n'en a pas : fiche introuvable = alerte.
class CreateCrmErasures < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_erasures do |t|
      t.string :email_digest, null: false
      t.datetime :erased_at, null: false
      t.timestamps
    end
    add_index :crm_erasures, :email_digest, unique: true

    create_table :crm_disappearances do |t|
      t.string :contact_id, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
    end
    add_index :crm_disappearances, :contact_id, unique: true

    add_column :registrations, :crm_sync_contact_gone_at, :datetime
    add_column :registration_requests, :crm_contact_gone_at, :datetime
  end
end
