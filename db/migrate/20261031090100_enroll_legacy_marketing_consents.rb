# Les inscrits d'avant l'entrée au CRM à la confirmation
# (`crm_enrolled_at` nul) qui ont une inscription CONFIRMÉE avec un consentement
# marketing VALIDÉ et NON retiré entrent au CRM. On leur pose
# `crm_enrolled_at = marketing_consent_at` ; CrmResyncJob les pousse quand
# CRM_SYNC_ENABLED=1. Ni les confirmés sans consentement, ni les retraits.
#
# Idempotente : seules les lignes sans `crm_enrolled_at` sont touchées (une
# ligne confirmée depuis en a toujours un). `crm_backfilled_at` marque les lignes
# reprises ici, pour que `down` défasse exactement cela et rien d'autre.
class EnrollLegacyMarketingConsents < ActiveRecord::Migration[8.1]
  class Registration < ActiveRecord::Base
    self.table_name = "registrations"

    scope :legacy_marketing_consents, -> {
      where.not(confirmed_at: nil).where.not(marketing_consent_at: nil)
                                  .where(marketing_consent: true, marketing_consent_withdrawn_at: nil, crm_enrolled_at: nil)
    }

    def self.enroll_legacy!(now = Time.current)
      legacy_marketing_consents.update_all([ "crm_enrolled_at = marketing_consent_at, crm_backfilled_at = ?", now ])
    end

    def self.unenroll_backfilled!
      where.not(crm_backfilled_at: nil).update_all(crm_enrolled_at: nil, crm_backfilled_at: nil)
    end
  end

  def up
    add_column :registrations, :crm_backfilled_at, :datetime
    Registration.reset_column_information
    Registration.enroll_legacy!
  end

  def down
    Registration.unenroll_backfilled!
    remove_column :registrations, :crm_backfilled_at
  end
end
