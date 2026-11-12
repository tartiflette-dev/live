# frozen_string_literal: true

# Sécurité : le consentement marketing saisi au POST n'est plus directement
# effectif. Il est stocké en « intention » (`pending_marketing_consent`) sur
# la CRÉATION d'une inscription uniquement, et devient effectif
# (`marketing_consent = true`, horodaté) au clic sur /r/:token qui PROUVE
# la possession de l'adresse email (double opt-in appliqué AUSSI au
# consentement marketing, pas uniquement à l'inscription).
#
# Supprime aussi `crm_last_error` : les messages d'erreur CRM pouvaient
# contenir des bribes de corps de réponse (nom/email) ; on ne persiste
# plus que le code HTTP via `crm_last_error_code` (entier ou nil).
class AddPendingMarketingConsentToRegistrations < ActiveRecord::Migration[8.1]
  def change
    change_table :registrations, bulk: true do |t|
      t.boolean :pending_marketing_consent, null: false, default: false
      t.integer :crm_last_error_code
      t.remove  :crm_last_error, type: :string
    end
  end
end
