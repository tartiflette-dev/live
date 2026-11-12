# Case « Ok pour que l'organisation me recontacte » du formulaire
# d'inscription cross-origin. `marketing_box_checked` : la case a été cochée lors de la demande
# — par la personne ou par un tiers, l'API n'est pas authentifiée. Seul le
# bouton « Confirmer et accepter d'être recontacté·e » vaut accord.
#
# Accord porté par la demande elle-même quand elle n'a aucun café (le
# « préviens-moi » seul) ; sinon il est posé sur ses inscriptions. Marqueurs
# CRM propres, poussés par CrmNotifyNextJob.
class AddMarketingConsentToRegistrationRequests < ActiveRecord::Migration[8.1]
  def change
    change_table :registration_requests, bulk: true do |t|
      t.boolean :marketing_box_checked, default: false, null: false
      t.boolean :marketing_consent, default: false, null: false
      t.datetime :marketing_consent_at
      t.string :marketing_consent_policy_version
      t.string :marketing_withdrawal_token
      t.datetime :marketing_consent_withdrawn_at
      t.datetime :crm_marketing_consent_pushed_at
      t.datetime :crm_withdrawal_pushed_at
      t.index :marketing_withdrawal_token, unique: true
    end
  end
end
