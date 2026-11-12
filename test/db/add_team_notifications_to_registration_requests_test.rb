# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261106210000_add_team_notifications_to_registration_requests")

# Étapes de données de la migration : les inscriptions de test de bout en bout
# sont marquées transmises sur les deux canaux ; les messages confirmés avant
# le relais manuel (MANUAL_WHATSAPP_RELAY_AT) sont marqués relayés sur WhatsApp,
# mais restent à envoyer par mail.
class AddTeamNotificationsToRegistrationRequestsTest < ActiveSupport::TestCase
  Step = AddTeamNotificationsToRegistrationRequests::RegistrationRequest
  RELAY_AT = Time.utc(2026, 11, 6, 21, 12)

  test "test de bout en bout : seules ces inscriptions sont marquées, sur les deux canaux" do
    end_to_end = %w[camille+cafe-test-1@example.test camille+cafe-test-2@example.test].map do |email|
      team_request(email, "Inscription de test de bout en bout")
    end
    others = [ team_request("intervenant@example.test", "Je propose une présentation pour le Café IA #9."),
               team_request("camille+cafe-test-3@example.test", "Une vraie question."),
               team_request("camille@example.test", "Inscription de test de bout en bout") ]

    assert_equal 2, Step.mark_end_to_end_tests_transmitted!

    end_to_end.each do |request|
      assert_not_nil request.reload.team_notified_at, request.email
      assert_not_nil request.whatsapp_relayed_at, request.email
    end
    assert_equal others.map(&:id).sort, RegistrationRequest.whatsapp_relay_pending.ids.sort
    assert_equal others.map(&:id).sort, RegistrationRequest.team_notification_pending.ids.sort
  end

  test "relais manuel : confirmés avant 21:12 UTC marqués relayés à cette heure, le mail reste à faire" do
    relayed = team_request("avant@example.test", "Je propose une présentation.", confirmed_at: RELAY_AT - 1.hour)
    after = team_request("apres@example.test", "Arrivé après le relais.", confirmed_at: RELAY_AT + 1.minute)
    unconfirmed = team_request("attente@example.test", "Pas encore confirmé.", confirmed_at: nil, created_at: RELAY_AT - 2.hours)
    silent = team_request("muet@example.test", nil, confirmed_at: RELAY_AT - 1.hour)

    assert_equal 1, Step.mark_manually_relayed!

    assert_equal RELAY_AT, relayed.reload.whatsapp_relayed_at
    assert_nil relayed.team_notified_at, "le rattrapage mail reste à faire"
    [ after, unconfirmed, silent ].each { |request| assert_nil request.reload.whatsapp_relayed_at, request.email }
    assert_equal [ after.id ], RegistrationRequest.team_messages.where(whatsapp_relayed_at: nil).ids
    assert_includes RegistrationRequest.team_notification_pending, relayed
  end

  test "relais manuel après l'étape des tests : leur date de transmission reste" do
    stamp = Time.utc(2026, 11, 7, 8, 0)
    test_request = team_request("camille+cafe-test-1@example.test", "Inscription de test de bout en bout",
                                confirmed_at: RELAY_AT - 1.hour)
    Step.mark_end_to_end_tests_transmitted!(stamp)
    Step.mark_manually_relayed!
    assert_equal stamp, test_request.reload.whatsapp_relayed_at
  end

  private

  def team_request(email, message, confirmed_at: RELAY_AT + 1.hour, **attributes)
    RegistrationRequest.create!(name: "Camille", email: email, source: "tartiflette.dev", message: message,
                                confirmed_at: confirmed_at, **attributes)
  end
end
