require "test_helper"

# Pages dont l'URL porte un jeton en query (`/confirmer?t=`, `/mc?t=`,
# `/mc/withdraw?t=`) et dont l'effet passe par un bouton POST (button_to).
#
# Régression trouvée en E2E Chromium : avec
# `Referrer-Policy: no-referrer`, le navigateur envoie `Origin: null` sur
# le POST du formulaire (Fetch, « serializing a request origin »), et la
# protection CSRF de Rails (`forgery_protection_origin_check`) le rejette
# — personne ne pouvait confirmer. Ce test rejoue ce que fait le
# navigateur : il lit la Referrer-Policy de la page, en déduit l'en-tête
# Origin du POST, et poste le jeton CSRF du formulaire, protection activée
# (elle est coupée par défaut en environnement de test).
class TokenPageButtonsOriginTest < ActionDispatch::IntegrationTest
  setup do
    @forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.day.from_now, host_sub: "h", visibility: "published")
  end

  teardown { ActionController::Base.allow_forgery_protection = @forgery }

  test "/confirmer : le bouton confirme dans un vrai navigateur" do
    request = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", notify_next: true)
    click_button_like_a_browser registration_request_path(t: request.token)
    assert_response :success
    assert request.reload.confirmed?
  end

  test "/r/:token : le bouton confirme l'inscription dans un vrai navigateur" do
    registration = @webinar.registrations.create!(name: "Camille", email: "camille-r@example.test")
    click_button_like_a_browser confirm_registration_path(registration.token)
    assert_redirected_to public_webinar_path(@webinar.slug)
    assert registration.reload.confirmed?
  end

  test "/mc : le bouton d'acceptation applique le consentement dans un vrai navigateur" do
    registration = consent_requested_registration
    click_button_like_a_browser marketing_consent_path(t: registration.marketing_consent_token),
                                action: confirm_marketing_consent_path(t: registration.marketing_consent_token)
    assert_response :success
    assert registration.reload.marketing_consent?
  end

  test "/mc : le bouton « Non merci » consomme le jeton dans un vrai navigateur" do
    registration = consent_requested_registration
    click_button_like_a_browser marketing_consent_path(t: registration.marketing_consent_token),
                                action: decline_marketing_consent_path(t: registration.marketing_consent_token)
    assert_response :success
    assert_nil registration.reload.marketing_consent_token
  end

  test "/mc/withdraw : le bouton retire le consentement dans un vrai navigateur" do
    registration = consent_requested_registration
    registration.apply_marketing_consent!
    token = registration.reload.marketing_withdrawal_token
    click_button_like_a_browser marketing_withdrawal_path(t: token)
    assert_response :success
    assert registration.reload.marketing_consent_withdrawn?
  end

  # « Ce n'est pas moi » (NotMeController) : bouton POST de la page 409, de la
  # salle spectateur et de la page du webinaire ; refusé sans jeton CSRF.
  test "« Ce n'est pas moi » : le bouton oublie l'inscription dans un vrai navigateur, jamais sans jeton CSRF" do
    registration = @webinar.registrations.create!(name: "Camille", email: "camille-p@example.test")
    click_button_like_a_browser confirm_registration_path(registration.token)
    assert cookies["registration_id"].present?

    post public_webinar_not_me_path(@webinar.slug), headers: { "Origin" => "http://www.example.com" }
    assert_response :unprocessable_entity
    assert cookies["registration_id"].present?, "sans jeton CSRF, rien n'est oublié"

    click_button_like_a_browser public_webinar_path(@webinar.slug), action: public_webinar_not_me_path(@webinar.slug)
    assert_redirected_to public_webinar_path(@webinar.slug)
    assert cookies["registration_id"].blank?
  end

  test "strict-origin : le Referer ne porte jamais le chemin ni le jeton" do
    request = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", notify_next: true)
    registration = consent_requested_registration
    [ registration_request_path(t: request.token), marketing_consent_path(t: registration.marketing_consent_token) ].each do |path|
      get path
      assert_equal "strict-origin", response.headers["Referrer-Policy"], path
      assert_equal "no-store", response.headers["Cache-Control"], path
    end
  end

  private

  def consent_requested_registration
    registration = @webinar.registrations.create!(name: "Bob", email: "bob-#{SecureRandom.hex(3)}@example.test",
                                                  confirmed_at: Time.current)
    registration.request_marketing_consent!
    registration
  end

  # GET de la page, puis POST du formulaire `action` (le premier de la
  # page par défaut) avec son jeton CSRF et l'en-tête Origin qu'un
  # navigateur enverrait sous la Referrer-Policy reçue.
  def click_button_like_a_browser(page_path, action: nil)
    get page_path
    assert_response :success
    form = css_select(action ? "form[action='#{action}']" : "form").first
    assert form, "bouton absent de #{page_path}"
    origin = response.headers["Referrer-Policy"] == "no-referrer" ? "null" : "http://www.example.com"
    post form["action"], params: { authenticity_token: form.at_css("input[name=authenticity_token]")["value"] },
                         headers: { "Origin" => origin }
  end
end
