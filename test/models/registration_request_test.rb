require "test_helper"

class RegistrationRequestTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.day.from_now, host_sub: "h", visibility: "published")
    @request = RegistrationRequest.create!(name: "Camille", email: " Camille@Example.TEST ", source: "tartiflette.dev")
  end

  test "normalise l'email et pose un jeton opaque unique" do
    assert_equal "camille@example.test", @request.email
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, @request.token)
    assert_not_equal @request.token, RegistrationRequest.create!(name: "B", email: "b@example.org").token
  end

  test "confirm! confirme la demande et ses inscriptions, vrai à la PREMIÈRE fois seulement" do
    registration, = Registration.find_or_create_for(@webinar, email: @request.email, name: @request.name,
                                                    registration_request: @request)
    assert @request.confirm!
    assert registration.reload.confirmed?
    first = @request.reload.confirmed_at
    assert_not @request.confirm!, "second clic : rien ne découle à nouveau"
    assert_equal first, @request.reload.confirmed_at
  end

  test "confirm! : case de recontact accordée seulement sur choix explicite, jamais après un retrait" do
    @request.update!(marketing_box_checked: true)
    registration, = Registration.find_or_create_for(@webinar, email: @request.email, name: @request.name,
                                                    registration_request: @request)
    assert @request.marketing_choice_offered?
    other = RegistrationRequest.create!(name: "Camille", email: @request.email, marketing_box_checked: true)
    other_registration, = Registration.find_or_create_for(
      Webinar.create!(title: "Autre", starts_at: 2.days.from_now, host_sub: "h", visibility: "published"),
      email: other.email, name: other.name, registration_request: other
    )
    assert other.confirm!, "défaut : confirme"
    assert_not other_registration.reload.marketing_consent?, "défaut false : aucun accord sans choix explicite (B1)"

    assert @request.confirm!(marketing_consent: true)
    assert registration.reload.marketing_consent?

    assert_equal [ registration ], Registration.withdraw_marketing_consent_of(@request.email)
    assert_not registration.reload.grant_marketing_consent!(source: "tartiflette.dev", path: "/confirmer"),
               "garantie 3 : pas de re-consentement après retrait"
    assert_empty Registration.withdraw_marketing_consent_of(@request.email), "retrait idempotent"
  end

  test "« préviens-moi » seul, case cochée — choix offert, accord porté par la demande" do
    @request.update!(marketing_box_checked: true, notify_next: true)
    assert @request.marketing_choice_offered?
    freeze_time do
      assert @request.confirm!(marketing_consent: true)
      assert @request.reload.marketing_consent?
      assert_equal [ Time.current, PrivacyPolicy::VERSION ], @request.values_at(:marketing_consent_at, :marketing_consent_policy_version)
      assert_equal "Je confirme, et Studio Exemple peut me recontacter", @request.marketing_consent_label,
                   "libellé du bouton affiché (« préviens-moi » = Café IA), figé à l'accord"
    end
    assert @request.marketing_withdrawal_token.present?
    assert_equal @request.marketing_withdrawal_token, @request.marketing_withdrawal_token_for_page
    assert_includes RegistrationRequest.crm_pending, @request

    assert_equal [ @request ], RegistrationRequest.withdraw_marketing_consent_of(@request.email)
    assert_not @request.reload.grant_marketing_consent!, "jamais après un retrait"
  end

  test "choix offert d'après les cafés affichés ; sans café publié ni « préviens-moi », rien" do
    draft = Webinar.create!(title: "Brouillon", starts_at: 2.days.from_now, host_sub: "h", visibility: "draft")
    registration, = Registration.find_or_create_for(draft, email: @request.email, name: @request.name,
                                                    registration_request: @request)
    @request.update!(marketing_box_checked: true)
    assert_not @request.marketing_choice_offered?
    @request.confirm!(marketing_consent: true)
    assert_not registration.reload.marketing_consent?, "un café non affiché ne reçoit pas l'accord"
    assert_not @request.reload.marketing_consent?
  end

  test "listes blanches : source et profil" do
    assert_not RegistrationRequest.new(name: "A", email: "a@example.org", source: "evil.example").valid?
    assert_not RegistrationRequest.new(name: "A", email: "a@example.org", profile: "astronaute").valid?
    RegistrationRequest::PROFILES.each do |profile|
      assert RegistrationRequest.new(name: "A", email: "a@example.org", profile: profile).valid?, profile
    end
  end

  test "message borné à 2000 caractères" do
    assert RegistrationRequest.new(name: "A", email: "a@example.org", message: "x" * 2000).valid?
    assert_not RegistrationRequest.new(name: "A", email: "a@example.org", message: "x" * 2001).valid?
  end

  test "find_by_token défensif" do
    assert_nil RegistrationRequest.find_by_token(nil)
    assert_nil RegistrationRequest.find_by_token("")
    assert_nil RegistrationRequest.find_by_token("inconnu")
    assert_equal @request, RegistrationRequest.find_by_token(@request.token)
  end

  test "SÉCURITÉ : inspect masque le jeton" do
    assert_no_match(/#{Regexp.escape(@request.token)}/, @request.inspect)
  end

  test "published_registrations : cafés publiés seulement, par date" do
    later = Webinar.create!(title: "Plus tard", starts_at: 9.days.from_now, host_sub: "h", visibility: "published")
    hidden = Webinar.create!(title: "Retiré", starts_at: 2.days.from_now, host_sub: "h", visibility: "draft")
    [ later, hidden, @webinar ].each do |webinar|
      Registration.find_or_create_for(webinar, email: @request.email, name: "Camille", registration_request: @request)
    end
    assert_equal [ @webinar, later ], @request.published_registrations.map(&:webinar)
  end

  test "detail_lines : provenance, profil, message s'ils sont renseignés" do
    @request.update!(profile: "dev", message: "Bonjour")
    assert_equal [ "Provenance : tartiflette.dev", "Profil : dev", "Message : Bonjour" ], @request.detail_lines
    assert_empty RegistrationRequest.new(name: "A", email: "a@example.org").detail_lines
  end
end
