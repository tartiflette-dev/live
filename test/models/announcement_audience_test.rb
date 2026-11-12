require "test_helper"

# Cibles d'un envoi groupé : qui reçoit, une fois par adresse, et qui en sort
# sur-le-champ (retrait, retrait de la salle, pierre tombale).
class AnnouncementAudienceTest < ActiveSupport::TestCase
  setup do
    @webinar = announcement_webinar
    @other = announcement_webinar(title: "Café IA #10", starts_at: 8.days.from_now)
  end

  def emails(audience, webinar: @webinar)
    build_announcement(webinar, audience).recipients.map(&:email)
  end

  test "inscrits du webinaire : confirmés seulement, ni retirés de la salle, ni pierres tombales, ni autre café" do
    confirmed_registration(@webinar, "ana@example.test")
    Registration.create!(webinar: @webinar, name: "Pending", email: "pending@example.test")
    confirmed_registration(@webinar, "removed@example.test", room_removed_at: 1.minute.ago)
    confirmed_registration(@webinar, "tomb@example.test").tap { |registration| registration.update_columns(retired_email_digest: "x") }
    confirmed_registration(@other, "bob@example.test")

    assert_equal [ "ana@example.test" ], emails("webinar_registrants")
  end

  test "la liste : consentement actif, inscriptions et demandes dédoublonnées par adresse" do
    consenting_registration(@webinar, "ana@example.test")
    consenting_registration(@other, "ana@example.test")
    consenting_request("ana@example.test")
    consenting_request("bob@example.test")
    confirmed_registration(@webinar, "carol@example.test")

    assert_equal %w[ana@example.test bob@example.test], emails("marketing_list")
  end

  test "la liste : un retrait exclut la personne immédiatement, toutes fiches confondues" do
    registration = consenting_registration(@webinar, "ana@example.test")
    consenting_request("ana@example.test")
    announcement = build_announcement(@webinar, "marketing_list")
    assert announcement.recipient_for("ana@example.test")

    Registration.withdraw_marketing_consent_of("ana@example.test")
    RegistrationRequest.withdraw_marketing_consent_of("ana@example.test")

    assert_nil announcement.recipient_for("ana@example.test")
    assert_empty emails("marketing_list")
    assert registration.reload.marketing_consent_withdrawn?
  end

  test "la liste : consentement porté par un café dépublié compris (son lien de retrait fonctionne), demande non confirmée exclue" do
    hidden = announcement_webinar(title: "Annulé", visibility: "draft")
    consenting_registration(hidden, "ana@example.test")
    RegistrationRequest.create!(name: "Bob", email: "bob@example.test", notify_next: true).grant_marketing_consent!

    assert_equal %w[ana@example.test], emails("marketing_list")
  end

  test "préviens-moi : demandes confirmées, sans qui a dit stop, sauf accord redonné depuis" do
    confirmed_request("ana@example.test", notify_next: true)
    confirmed_request("ana@example.test", notify_next: true)
    RegistrationRequest.create!(name: "Pending", email: "pending@example.test", notify_next: true)
    confirmed_request("nope@example.test", notify_next: false)
    stopped = consenting_request("stop@example.test")
    stopped.withdraw_marketing_consent!
    consenting_request("back@example.test").withdraw_marketing_consent!
    consenting_registration(@webinar, "back@example.test")

    assert_equal %w[ana@example.test back@example.test], emails("notify_next")
  end

  test "préviens-moi : une demande arrêtée par le lien d'arrêt n'est plus servie, toutes demandes de la personne" do
    confirmed_request("ana@example.test", notify_next: true)
    confirmed_request("ana@example.test", notify_next: true)
    confirmed_request("bob@example.test", notify_next: true)

    RegistrationRequest.stop_notify_next_of("ana@example.test")

    assert_equal %w[bob@example.test], emails("notify_next")
  end

  test "recipient_for : nil sur adresse vide ou hors cible" do
    confirmed_registration(@webinar, "ana@example.test")
    announcement = build_announcement(@webinar, "webinar_registrants")

    assert_nil announcement.recipient_for(nil)
    assert_nil announcement.recipient_for("bob@example.test")
    assert_equal "ana@example.test", announcement.recipient_for("ana@example.test").email
  end
end
