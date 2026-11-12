# Inscription cross-origin (docs/registrations-api.md) : une soumission
# d'un site partenaire porte
# 0..3 cafés, un « préviens-moi du suivant », un profil et un message.
# La demande regroupe les inscriptions créées ensemble : UN mail, UN lien
# de confirmation. Sans café, elle porte seule le « préviens-moi » — d'où
# ses propres colonnes de synchro CRM.
#
# `crm_marketing_consent_pushed_at` : le consentement marketing devient
# une poussée CRM distincte de l'entrée du participant. Les inscriptions
# déjà poussées sous l'ancienne règle (consentement exigé) portaient le
# consentement dans la note de leur interaction : on les marque poussées.
#
# `crm_enrolled_at` : moment où un acte de la personne (confirmation POST,
# consentement /mc) a valu entrée au CRM. AUCUN remplissage des lignes
# existantes : les inscrits confirmés quand le CRM n'était annoncé qu'avec
# consentement n'entrent pas au CRM après coup.
class CreateRegistrationRequests < ActiveRecord::Migration[8.1]
  def up
    create_table :registration_requests do |t|
      t.string   :name, null: false
      t.string   :email, null: false, limit: 254
      t.string   :token, null: false
      t.string   :source
      t.string   :profile
      t.text     :message
      t.boolean  :notify_next, null: false, default: false
      t.datetime :confirmed_at
      t.datetime :pushed_to_crm_at
      t.string   :crm_contact_id
      t.integer  :crm_sync_attempts, null: false, default: 0
      t.integer  :crm_last_error_code
      t.timestamps
    end
    add_index :registration_requests, :token, unique: true

    add_reference :registrations, :registration_request, foreign_key: true
    add_column :registrations, :crm_marketing_consent_pushed_at, :datetime
    add_column :registrations, :crm_enrolled_at, :datetime

    execute <<~SQL.squish
      UPDATE registrations SET crm_marketing_consent_pushed_at = pushed_to_crm_at
      WHERE pushed_to_crm_at IS NOT NULL AND marketing_consent = 1
    SQL
  end

  def down
    remove_column :registrations, :crm_enrolled_at
    remove_column :registrations, :crm_marketing_consent_pushed_at
    remove_reference :registrations, :registration_request, foreign_key: true
    drop_table :registration_requests
  end
end
