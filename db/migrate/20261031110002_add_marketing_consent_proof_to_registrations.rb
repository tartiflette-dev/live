# Preuve du consentement marketing figée au moment de l'accord : la
# poussée CRM la relit telle quelle, sans la
# recalculer. `marketing_consent_at` en porte l'horodatage. Lignes
# antérieures : colonnes nulles, preuve historique `/mc`.
class AddMarketingConsentProofToRegistrations < ActiveRecord::Migration[8.1]
  def change
    add_column :registrations, :marketing_consent_source, :string
    add_column :registrations, :marketing_consent_path, :string
    add_column :registrations, :marketing_consent_policy_version, :string
    add_column :registrations, :marketing_consent_request_id, :integer
  end
end
