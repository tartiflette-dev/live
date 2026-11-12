require "application_system_test_case"

class PublicRegistrationTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @privacy_url = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/privacy"
    # Bootcamp : tonalité par défaut (vouvoiement). Le
    # parcours d'un Café IA, à sa tonalité propre, est le dernier test.
    @webinar = Webinar.create!(title: "Inscription publique", starts_at: 1.day.from_now,
      host_sub: "host", visibility: "published", kind: "bootcamp")
  end

  teardown do
    ENV["REGISTRATION_PRIVACY_URL"] = @privacy_url
  end

  test "public visitor registers then follows confirmation link" do
    visit public_webinar_path(@webinar.slug)
    assert_link "Politique de confidentialité", href: "https://example.test/privacy"
    fill_in "Nom", with: "Alice"
    fill_in "Adresse email", with: "alice@example.test"
    # Plus de case d'inscription, seule la case marketing reste.
    assert_no_field "registration_consent"
    # Case marketing : NON cochée par défaut, FACULTATIVE (pas required).
    refute find_field("registration_marketing_consent")[:required]
    refute find_field("registration_marketing_consent").checked?
    assert_enqueued_jobs 1 do
      click_button "M'inscrire"
    end
    assert_text "Inscription en mode essai"
    visit confirm_registration_path(Registration.last.token)
    assert_text "Confirmer votre inscription"
    refute Registration.last.confirmed?, "le GET du lien de mail est sans effet"
    click_button "Confirmer mon inscription"
    assert_current_path public_webinar_path(@webinar.slug)
    assert_text "Vous êtes inscrit·e, Alice"
    assert_no_button "M'inscrire"
  end

  test "visitor who ticks marketing consent : jeton stocké, effectif APRÈS POST /mc" do
    visit public_webinar_path(@webinar.slug)
    fill_in "Nom", with: "Bob"
    fill_in "Adresse email", with: "bob@example.test"
    check "registration_marketing_consent"
    click_button "M'inscrire"
    assert_text "Inscription en mode essai"
    registration = Registration.last
    # Sécurité : la soumission ne pose QUE le jeton
    # de consentement (opaque, expirable 14 j). L'effectif n'arrive qu'au
    # POST sur /mc?t=<token> — le clic sur /r/:token (inscription) ne
    # touche PAS au consentement marketing.
    assert registration.marketing_consent_requested?, "jeton de consentement généré"
    refute registration.marketing_consent, "pas de consentement effectif à la saisie"
    assert_nil registration.marketing_consent_at

    # Le bouton de /r/:token confirme SEULEMENT l'inscription.
    visit confirm_registration_path(registration.token)
    click_button "Confirmer mon inscription"
    registration.reload
    assert registration.confirmed?
    refute registration.marketing_consent, "/r/:token ne pose JAMAIS le consentement"

    # Le POST sur /mc applique le consentement (GET est sans effet — on
    # ne clique PAS sur le lien d'email seul, on confirme via button_to).
    visit marketing_consent_path(t: registration.marketing_consent_token)
    assert_text "Confirmer votre consentement"
    click_button "Oui, j'accepte d'être recontacté·e"
    assert_text "votre consentement est enregistré"
    registration.reload
    assert registration.marketing_consent
    assert_not_nil registration.marketing_consent_at
    assert_not_nil registration.marketing_withdrawal_token
  end

  test "Café IA : tout le parcours tutoie, comme tartiflette.dev" do
    cafe = Webinar.create!(title: "Café IA #8", starts_at: 1.day.from_now, host_sub: "host",
                           visibility: "published", kind: "cafe_ia")
    visit public_webinar_path(cafe.slug)
    assert_selector "h2", text: "Tu viens ?"
    assert_text "Laisse ton mail, on t'envoie le lien la veille."
    assert_text "Ton prénom et ton mail servent à ton inscription et aux messages sur ce café."
    fill_in "Ton prénom", with: "Alice"
    fill_in "Ton mail", with: "alice@example.test"
    check "registration_marketing_consent"
    click_button "Je viens"
    assert_text "Inscription pour essayer"
    registration = Registration.last

    visit confirm_registration_path(registration.token)
    assert_text "Confirme ton inscription"
    click_button "Je confirme"
    assert_current_path public_webinar_path(cafe.slug)
    assert_text "Tu es inscrit·e, Alice. À très vite !"

    visit marketing_consent_path(t: registration.reload.marketing_consent_token)
    assert_text "Tu veux #{Brand.elision("que")}#{Brand.organization} te recontacte ?"
    click_button "Oui, j'accepte d'être recontacté·e"
    assert_text "Merci, c'est noté !"

    visit marketing_withdrawal_path(t: registration.reload.marketing_withdrawal_token)
    click_button "Oui, je retire mon accord"
    assert_text "C'est fait, ton accord est retiré"
    assert_no_text(/\bvous\b|\bvotre\b/i)
  end
end
