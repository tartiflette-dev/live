# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261031090100_enroll_legacy_marketing_consents")

# Reprise au CRM des inscrits confirmés sans entrée au CRM, au
# consentement marketing validé et non retiré. Étape de données de la
# migration, testée sans changement de schéma.
class EnrollLegacyMarketingConsentsTest < ActiveSupport::TestCase
  Step = EnrollLegacyMarketingConsents::Registration

  setup do
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.day.from_now, host_sub: "h", visibility: "published")
    @consent_at = 3.weeks.ago.change(usec: 0)
    @legacy = registration("legacy@example.org", confirmed_at: 1.month.ago, marketing_consent: true,
                                          marketing_consent_at: @consent_at)
    @no_consent = registration("noconsent@example.org", confirmed_at: 1.month.ago)
    @withdrawn = registration("withdrawn@example.org", confirmed_at: 1.month.ago, marketing_consent: true,
                                                marketing_consent_at: @consent_at,
                                                marketing_consent_withdrawn_at: 1.week.ago)
    @unconfirmed = registration("unconfirmed@example.org", marketing_consent: true, marketing_consent_at: @consent_at)
    @v11 = registration("v11@example.org", confirmed_at: 2.days.ago, crm_enrolled_at: 2.days.ago,
                                    marketing_consent: true, marketing_consent_at: 1.day.ago)
  end

  test "sélection exacte : seul le confirmé au consentement validé et non retiré entre, à la date du consentement" do
    assert_equal 1, Step.enroll_legacy!

    assert_equal @consent_at, @legacy.reload.crm_enrolled_at
    assert_not_nil @legacy.crm_backfilled_at
    assert_includes ::Registration.crm_pending, @legacy, "repris par CrmResyncJob à l'activation"
    [ @no_consent, @withdrawn, @unconfirmed ].each do |row|
      assert_nil row.reload.crm_enrolled_at, row.email
      assert_nil row.crm_backfilled_at
    end
    assert_nil @v11.reload.crm_backfilled_at, "une ligne v1.1 garde son entrée d'origine"
  end

  test "idempotente : un second passage ne touche rien" do
    Step.enroll_legacy!
    stamp = @legacy.reload.crm_backfilled_at
    assert_equal 0, Step.enroll_legacy!(1.hour.from_now)
    assert_equal stamp, @legacy.reload.crm_backfilled_at
  end

  test "réversible : défait la reprise et elle seule" do
    Step.enroll_legacy!
    Step.unenroll_backfilled!
    assert_nil @legacy.reload.crm_enrolled_at
    assert_nil @legacy.crm_backfilled_at
    assert_not_nil @v11.reload.crm_enrolled_at
  end

  private

  def registration(email, **attrs)
    @webinar.registrations.create!(name: "P", email: email, **attrs)
  end
end
