# frozen_string_literal: true

# Ajoute les colonnes qui portent le consentement marketing optionnel
# (RGPD art. 6.1.a, distinct du consentement d'inscription) et l'état
# d'idempotence de la poussée au CRM.
#
# Migration ADDITIVE — aucune colonne existante touchée, aucun default
# nouveau sur une colonne existante : rollback trivial.
class AddCrmSyncToRegistrations < ActiveRecord::Migration[8.1]
  def change
    change_table :registrations, bulk: true do |t|
      t.boolean  :marketing_consent,     null: false, default: false
      t.datetime :marketing_consent_at
      t.datetime :pushed_to_crm_at
      t.integer  :crm_sync_attempts,     null: false, default: 0
      t.string   :crm_contact_id
      t.string   :crm_last_error
    end
  end
end
