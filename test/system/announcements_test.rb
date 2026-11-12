require "application_system_test_case"

# Écran d'envoi groupé, de bout en bout côté serveur (rack_test) : depuis la
# régie, composer, voir l'aperçu et le nombre de destinataires, confirmer,
# retrouver l'envoi au journal ; le co-animateur ne peut viser que les
# inscrits de son webinaire.
class AnnouncementsTest < ApplicationSystemTestCase
  include OidcSignIn
  include ActiveJob::TestHelper

  setup do
    @owner = User.create!(email: "owner@example.test", oidc_sub: "sub-owner")
    @project = project_host_user
    # Café du jour, en cours : la fenêtre du co-animateur est ouverte.
    @webinar = announcement_webinar(host_sub: @owner.oidc_sub, starts_at: 10.minutes.ago)
    @guest = guest_user(@webinar)
    confirmed_registration(@webinar, "ana@example.test")
    confirmed_registration(@webinar, "bob@example.test")
    @consenting = consenting_registration(@webinar, "liste@example.test")
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  # Mails de cet envoi seulement : la file de remise du processus est
  # partagée avec les tests système qui précèdent.
  def delivered(subject)
    perform_enqueued_jobs
    ActionMailer::Base.deliveries.select { |mail| mail.subject == subject }
  end

  def compose(audience_label, subject:, body:)
    choose audience_label
    fill_in "Objet", with: subject
    fill_in "Message", with: body
    click_button "Voir l'aperçu"
  end

  test "animateur du projet : de la régie à la liste, aperçu, nombre, confirmation, journal, lien de retrait" do
    sign_in_as(@project)
    visit webinar_regie_path(@webinar)
    click_link "Envoyer un message aux inscrits"

    assert_selector "[data-audience=marketing_list] [data-role=audience-count]", text: "1 destinataire"
    compose "La liste : personnes d'accord pour être recontactées", subject: "Prochain café", body: "On se retrouve jeudi."

    assert_selector "[data-role=recipients-count]", text: "1 destinataire"
    within("[data-role=announcement-preview]") do
      assert_text "Prochain café"
      assert_text "On se retrouve jeudi."
      assert_text "Je retire mon accord"
    end

    click_button "Envoyer à 1 destinataire"
    assert_selector ".etat--ecart", text: "Coche la case de confirmation"
    assert_equal 0, Announcement.count

    check "confirmed"
    click_button "Envoyer à 1 destinataire"

    assert_text "Envoi lancé : 1 mail en route"
    within("[data-announcement-id]") do
      assert_text "Prochain café"
      assert_text "La liste"
      assert_text "1 destinataire"
    end

    mail = delivered("Prochain café").sole
    assert_equal [ "liste@example.test" ], mail.to
    assert_includes mail.text_part.decoded, "/mc/withdraw?t=#{@consenting.marketing_withdrawal_token}"
  end

  test "co-animateur : depuis la régie, les inscrits du jour seulement, sans lien de retrait, réponses au propriétaire" do
    sign_in_as(@guest)
    visit webinar_regie_path(@webinar)
    click_link "Envoyer un message aux inscrits"

    assert_selector "input[type=radio][name='announcement[audience]']", count: 1
    assert_no_text "La liste"
    compose "Inscrits confirmés de ce webinaire", subject: "Salle 2", body: "Le café a lieu salle 2."

    assert_selector "[data-role=recipients-count]", text: "3 destinataires"
    check "confirmed"
    click_button "Envoyer à 3 destinataires"
    assert_text "Envoi lancé : 3 mails en route"

    mails = delivered("Salle 2")
    assert_equal %w[ana@example.test bob@example.test liste@example.test], mails.flat_map(&:to).sort
    mails.each do |mail|
      assert_not_includes mail.text_part.decoded, "/mc/withdraw"
      assert_equal [ "owner@example.test" ], mail.reply_to
    end
  end
  test "préviens-moi : le lien d'arrêt du mail, page sans effet puis bouton, n'arrête que le préviens-moi" do
    request = consenting_request("prochain@example.test")
    sign_in_as(@project)
    visit new_webinar_announcement_path(@webinar)
    compose "Demandes « préviens-moi du prochain Café IA »", subject: "Café IA #10", body: "Il est ouvert."
    assert_selector "[data-role=recipients-count]", text: "1 destinataire"
    check "confirmed"
    click_button "Envoyer à 1 destinataire"

    text = delivered("Café IA #10").sole.text_part.decoded
    stop_url = text[%r{http://example\.com(/prochain/stop\?t=\S+)}, 1]
    visit stop_url
    assert_text "Tu ne veux plus être prévenu·e du prochain café ?"
    assert_nil request.reload.notify_next_stopped_at

    click_button "Oui, ne plus me prévenir"
    assert_text "C'est fait, on ne te préviendra plus"
    assert request.reload.notify_next_stopped_at
    assert request.marketing_consent?, "le consentement marketing ne change pas"
    assert_equal 0, Announcement.new(webinar: @webinar, audience: "notify_next").recipients.size
  end
end
