require "application_system_test_case"

# Vrai Chrome (Selenium) : le navigateur applique lui-même la
# Referrer-Policy de la page à l'en-tête Origin du POST du bouton — ce que
# rack_test ne fait pas. Régression E2E : `no-referrer` →
# `Origin: null` → InvalidAuthenticityToken, aucune confirmation possible.
# Protection CSRF activée le temps du test (coupée en environnement de test).
class TokenPageButtonsTest < JsSystemTestCase
  setup do
    @forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    @webinar = Webinar.create!(title: "Café IA de novembre", starts_at: 3.days.from_now, host_sub: "h", visibility: "published")
  end

  teardown { ActionController::Base.allow_forgery_protection = @forgery }

  test "/confirmer : clic réel sur « Je confirme »" do
    request = RegistrationRequest.create!(name: "Camille", email: "camille@example.test")
    Registration.find_or_create_for(@webinar, email: request.email, name: request.name, registration_request: request)

    visit registration_request_path(t: request.token)
    click_button "Je confirme"
    assert_text "C'est confirmé, à très vite !"
    assert request.reload.confirmed?
    assert request.registrations.all?(&:confirmed?)
  end

  test "/mc puis /mc/withdraw : clics réels sur accepter puis retirer" do
    registration = @webinar.registrations.create!(name: "Bob", email: "bob@example.test", confirmed_at: Time.current)
    registration.request_marketing_consent!

    visit marketing_consent_path(t: registration.marketing_consent_token)
    click_button "Oui, j'accepte d'être recontacté·e"
    assert_text "Merci, c'est noté !"
    assert registration.reload.marketing_consent?

    visit marketing_withdrawal_path(t: registration.marketing_withdrawal_token)
    click_button "Oui, je retire mon accord"
    assert_text "C'est fait, ton accord est retiré"
    assert registration.reload.marketing_consent_withdrawn?
  end
end
