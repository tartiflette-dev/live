# Reprise CRM sans gel (re-review) :
# CrmResyncJob espace les nouvelles tentatives jusqu'à 24 h au lieu de geler
# une ligne après un plafond. Il lui faut l'heure de la dernière tentative.
# Le retrait du consentement marketing a son PROPRE compteur et son propre
# code d'erreur : une inscription en échec ne doit jamais bloquer la
# propagation d'un retrait (« le retrait gagne toujours »).
# `*_next_attempt_at` : pas d'essai avant cette heure — posé sur un 429 de
# CRM (quota du lookup), d'après son Retry-After.
class AddCrmRetrySchedule < ActiveRecord::Migration[8.1]
  def change
    add_column :registrations, :crm_last_attempt_at, :datetime
    add_column :registrations, :crm_next_attempt_at, :datetime
    add_column :registrations, :crm_withdrawal_attempts, :integer, null: false, default: 0
    add_column :registrations, :crm_withdrawal_last_attempt_at, :datetime
    add_column :registrations, :crm_withdrawal_next_attempt_at, :datetime
    add_column :registrations, :crm_withdrawal_last_error_code, :integer
    add_column :registration_requests, :crm_last_attempt_at, :datetime
    add_column :registration_requests, :crm_next_attempt_at, :datetime
  end
end
