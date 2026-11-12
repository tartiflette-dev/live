# frozen_string_literal: true

# Le consentement marketing ne
# peut PAS être validé par le `/r/:token` d'inscription (le propriétaire
# de l'adresse clique alors pour s'inscrire, pas pour autoriser la
# prospection). On remplace `pending_marketing_consent` (bool appliqué
# au clic du lien d'inscription) par un JETON DÉDIÉ à usage unique,
# expirable, envoyé par mail au propriétaire de l'adresse ET à lui seul.
#
# Ajouts :
# - `marketing_consent_token` : opaque (SecureRandom.urlsafe_base64),
#   unique en index partiel (seuls les tokens non-NULL sont contraints).
# - `marketing_consent_token_expires_at` : 14 jours après émission.
# - `marketing_withdrawal_token` : jeton distinct, persistant, qui permet
#   le retrait du consentement « à tout moment » promis par /confidentialite.
# - `marketing_consent_withdrawn_at` : traçabilité du retrait (RGPD).
class ReplacePendingMarketingConsentWithToken < ActiveRecord::Migration[8.1]
  def change
    change_table :registrations, bulk: true do |t|
      t.string   :marketing_consent_token
      t.datetime :marketing_consent_token_expires_at
      t.string   :marketing_withdrawal_token
      t.datetime :marketing_consent_withdrawn_at
      t.remove   :pending_marketing_consent, type: :boolean, null: false, default: false
    end
    add_index :registrations, :marketing_consent_token,
              unique: true, where: "marketing_consent_token IS NOT NULL"
    add_index :registrations, :marketing_withdrawal_token,
              unique: true, where: "marketing_withdrawal_token IS NOT NULL"
  end
end
