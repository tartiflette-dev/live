require "test_helper"

# Fin du « préviens-moi » : pour la personne (toutes ses demandes
# confirmées), sans toucher inscriptions ni consentement marketing ; jeton
# signé qui cesse de valoir après l'arrêt.
class RegistrationRequestNotifyNextStopTest < ActiveSupport::TestCase
  test "arrête toutes les demandes confirmées de la personne, pas celles des autres ni les non confirmées" do
    first = confirmed_request("ana@example.test", notify_next: true)
    second = consenting_request("ana@example.test")
    pending = RegistrationRequest.create!(name: "Ana", email: "ana@example.test", notify_next: true)
    other = confirmed_request("bob@example.test", notify_next: true)

    assert_equal 2, RegistrationRequest.stop_notify_next_of("ana@example.test")

    assert first.reload.notify_next_stopped_at
    assert second.reload.notify_next_stopped_at
    assert_nil pending.reload.notify_next_stopped_at
    assert_nil other.reload.notify_next_stopped_at
    assert first.notify_next?, "notify_next garde ce que la personne a demandé"
  end

  test "ni les inscriptions ni le consentement marketing ne changent" do
    webinar = announcement_webinar
    registration = consenting_registration(webinar, "ana@example.test")
    request = consenting_request("ana@example.test")

    RegistrationRequest.stop_notify_next_of("ana@example.test")

    assert registration.reload.marketing_consent?
    assert registration.confirmed?
    assert request.reload.marketing_consent?
    assert_not request.marketing_consent_withdrawn?
    assert request.marketing_withdrawal_token.present?
  end

  test "le jeton d'arrêt désigne la demande, puis cesse de valoir une fois l'arrêt posé" do
    request = confirmed_request("ana@example.test", notify_next: true)
    token = request.generate_token_for(:notify_next_stop)
    assert_equal request, RegistrationRequest.find_by_token_for(:notify_next_stop, token)

    RegistrationRequest.stop_notify_next_of("ana@example.test")

    assert_nil RegistrationRequest.find_by_token_for(:notify_next_stop, token)
    assert_nil RegistrationRequest.find_by_token_for(:notify_next_stop, "forgé")
  end
end
