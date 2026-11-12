require "application_system_test_case"

# Parcours d'une inscription venue de tartiflette.dev : soumission API
# (deux cafés) → UN mail → page sans effet → bouton → liens d'accès.
class RegistrationRequestConfirmationTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @first = Webinar.create!(title: "Café IA de novembre", starts_at: 3.days.from_now, host_sub: "h", visibility: "published")
    @second = Webinar.create!(title: "Café IA de décembre", starts_at: 30.days.from_now, host_sub: "h", visibility: "published")
    ActionMailer::Base.deliveries.clear
  end

  test "un seul lien confirme les deux cafés, puis ouvre chaque café" do
    perform_enqueued_jobs do
      assert RegistrationSubmission.new(
        name: "Camille", email: "camille@example.test", slugs: [ @first.slug, @second.slug ],
        source: "tartiflette.dev"
      ).save
    end
    assert_equal 1, ActionMailer::Base.deliveries.size, "un seul mail pour la soumission"
    link = ActionMailer::Base.deliveries.last.text_part.body.to_s[%r{http://\S+/confirmer\?t=\S+}]
    uri = URI.parse(link)

    visit "#{uri.path}?#{uri.query}"
    assert_text "Confirme ton inscription"
    assert_text "Café IA de novembre"
    assert_text "Café IA de décembre"
    assert_not Registration.where(email: "camille@example.test").any?(&:confirmed?), "le GET est sans effet"

    click_button "Je confirme"
    assert_text "C'est confirmé, à très vite !"
    assert Registration.where(email: "camille@example.test").all?(&:confirmed?)

    within "[data-role=registration-request-confirmed] li", text: "Café IA de décembre" do
      click_link "Ouvrir la page du café"
    end
    click_button "Ouvrir la page du café" # le GET de /r/:token ne donne plus l'accès seul
    assert_current_path public_webinar_path(@second.slug)
    assert_text "Tu es inscrit·e, Camille"
  end

  test "case de recontact cochée : le mail l'annonce, le bouton explicite la pose, le lien de retrait l'ôte" do
    perform_enqueued_jobs do
      assert RegistrationSubmission.new(
        name: "Camille", email: "camille@example.test", slugs: [ @first.slug ],
        marketing_consent: true, source: "tartiflette.dev"
      ).save
    end
    text = ActionMailer::Base.deliveries.last.text_part.body.to_s
    assert_match(/a été cochée lors de cette demande/, text)
    uri = URI.parse(text[%r{http://\S+/confirmer\?t=\S+}])

    visit "#{uri.path}?#{uri.query}"
    assert_text "a été cochée lors de cette demande"
    assert_no_button "Je confirme", exact: true
    registration = Registration.find_by!(email: "camille@example.test")
    assert_not registration.marketing_consent?, "le GET est sans effet"

    click_button "Je confirme, et Studio Exemple peut me recontacter"
    assert_text "Studio Exemple pourra te recontacter"
    assert registration.reload.marketing_consent?

    click_link "ne plus être recontacté·e"
    click_button "Oui, je retire mon accord"
    assert registration.reload.marketing_consent_withdrawn?
    assert registration.confirmed?
  end

  test "case de recontact cochée, « Je confirme, sans être recontacté·e » : inscrit sans consentement" do
    perform_enqueued_jobs do
      RegistrationSubmission.new(name: "Lou", email: "lou@example.test", slugs: [ @first.slug ],
                                 marketing_consent: true).save
    end
    uri = URI.parse(ActionMailer::Base.deliveries.last.text_part.body.to_s[%r{http://\S+/confirmer\?t=\S+}])

    visit "#{uri.path}?#{uri.query}"
    click_button "Je confirme, sans être recontacté·e"
    assert_text "C'est confirmé, à très vite !"
    assert_no_text "Studio Exemple pourra te recontacter"
    registration = Registration.find_by!(email: "lou@example.test")
    assert registration.confirmed?
    assert_not registration.marketing_consent?
  end

  test "« préviens-moi » seul, case cochée : accord par le bouton explicite, retrait par la page confirmée" do
    perform_enqueued_jobs do
      RegistrationSubmission.new(name: "Lou", email: "lou@example.test", slugs: [], notify_next: true,
                                 marketing_consent: true, source: "tartiflette.dev").save
    end
    uri = URI.parse(ActionMailer::Base.deliveries.last.text_part.body.to_s[%r{http://\S+/confirmer\?t=\S+}])

    visit "#{uri.path}?#{uri.query}"
    assert_text "a été cochée lors de cette demande"
    click_button "Je confirme, et Studio Exemple peut me recontacter"
    assert_text "on te prévient par mail"
    request = RegistrationRequest.find_by!(email: "lou@example.test")
    assert request.marketing_consent?

    click_link "ne plus être recontacté·e"
    click_button "Oui, je retire mon accord"
    assert request.reload.marketing_consent_withdrawn?
  end

  # Le POST rejoué (aucun second mail) : RegistrationRequestsControllerTest.
  test "message laissé : rien avant le clic ; au clic, l'équipe le reçoit par mail et le relais le voit" do
    saved = ENV["CO_ORGANIZERS_NOTIFY_TO"]
    ENV["CO_ORGANIZERS_NOTIFY_TO"] = "orga@tartiflette.test"
    perform_enqueued_jobs do
      assert RegistrationSubmission.new(
        name: "Camille", email: "camille@example.test", slugs: [ @first.slug ], source: "tartiflette.dev",
        message: "Je propose une présentation pour le prochain café."
      ).save
    end
    assert_equal [ [ "camille@example.test" ] ], ActionMailer::Base.deliveries.map(&:to), "rien à l'équipe avant la confirmation"
    uri = URI.parse(ActionMailer::Base.deliveries.last.text_part.body.to_s[%r{http://\S+/confirmer\?t=\S+}])

    perform_enqueued_jobs do
      visit "#{uri.path}?#{uri.query}"
      click_button "Je confirme"
      assert_text "C'est confirmé, à très vite !"
    end

    team_mail = ActionMailer::Base.deliveries.find { |mail| mail.to == [ "orga@tartiflette.test" ] }
    assert team_mail, "mail d'équipe envoyé à la confirmation"
    assert_equal [ "camille@example.test" ], team_mail.reply_to
    assert_includes team_mail.body.to_s, "Je propose une présentation pour le prochain café."
    assert_includes team_mail.body.to_s, "Café IA de novembre"
    assert_equal [ "camille@example.test" ], RegistrationRequest.whatsapp_relay_pending.map(&:email)
  ensure
    ENV["CO_ORGANIZERS_NOTIFY_TO"] = saved
  end
end
