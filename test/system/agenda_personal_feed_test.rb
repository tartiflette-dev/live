require "application_system_test_case"

# Parcours visibles de l'agenda personnel (rack_test) : la page /agenda dit
# comment l'obtenir, la confirmation d'une inscription envoie le lien, le
# lien sert le flux, l'ancien flux public est fermé ; un café déplacé ou
# annulé prévient ses inscrits.
class AgendaPersonalFeedTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    # Un test système n'hérite pas du vidage d'ActionMailer::TestCase : sans
    # lui, les mails d'un test précédent du même processus seraient comptés.
    ActionMailer::Base.deliveries.clear
    travel_to Time.zone.local(2026, 11, 2, 10, 0)
    @privacy_url = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/privacy"
    @cafe = Webinar.create!(title: "Café IA #9", starts_at: Time.zone.local(2026, 11, 10, 9, 30),
                            host_sub: "host", visibility: "published", kind: "cafe_ia")
  end

  teardown do
    ENV["REGISTRATION_PRIVACY_URL"] = @privacy_url
  end

  # Fin du délai d'apaisement : le job d'annonce tourne, puis ses mails.
  def after_quiet_period
    travel WebinarChangeNotice::QUIET_PERIOD + 1.second
    perform_enqueued_jobs(only: WebinarChangeNoticeJob)
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob)
  end

  def mail_to(address, subject)
    ActionMailer::Base.deliveries.reverse.find { |mail| mail.to == [ address ] && mail.subject == subject }
  end

  # Navigateur neuf à chaque inscription : un navigateur déjà inscrit garde
  # son inscription (RegistrationsController#grant_access).
  def register_and_confirm(name, email)
    Capybara.reset_sessions!
    visit public_webinar_path(@cafe.slug)
    fill_in "Ton prénom", with: name
    fill_in "Ton mail", with: email
    click_button "Je viens"
    visit confirm_registration_path(@cafe.registrations.find_by!(email: email).token)
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) { click_button "Je confirme" }
  end

  test "de l'agenda à son flux personnel : inscription, mail du lien, flux servi, ancien flux fermé" do
    visit agenda_path
    within("[data-role='agenda-inscription']") do
      assert_text "Inscrivez-vous à un webinaire : vous recevrez par mail votre lien d'agenda personnel"
    end
    assert_no_link href: /agenda\.ics|webcal:/

    register_and_confirm("Alice", "alice@example.test")

    mail = mail_to("alice@example.test", "Ajoute le Café IA à ton agenda")
    assert mail, "le lien d'agenda part à la confirmation"
    feed_url = mail.text_part.body.to_s[%r{http://\S+/agenda/[A-Za-z0-9_-]+\.ics\?kind=cafe_ia}]
    assert feed_url

    visit URI(feed_url).request_uri
    assert_equal "text/calendar", page.response_headers["Content-Type"].split(";").first
    event = Icalendar::Parser.new(page.body, true).parse.sole.events.sole
    assert_equal "Café IA #9", event.summary.to_s

    visit "/agenda.ics?kind=cafe_ia"
    assert_equal 410, page.status_code
    assert_text "Inscrivez-vous à un webinaire"
  end

  test "une seconde inscription confirmée ne renvoie pas le lien" do
    register_and_confirm("Alice", "alice@example.test")
    other = Webinar.create!(title: "Café IA #10", starts_at: Time.zone.local(2026, 11, 17, 9, 30),
                            host_sub: "host", visibility: "published", kind: "cafe_ia")
    @cafe = other
    register_and_confirm("Alice", "alice@example.test")

    feed_mails = ActionMailer::Base.deliveries.select { |mail| mail.subject == "Ajoute le Café IA à ton agenda" }
    assert_equal [ [ "alice@example.test" ] ], feed_mails.map(&:to)
  end

  test "café déplacé : les inscrits reçoivent la nouvelle date, et leur lien ouvre la page du café" do
    register_and_confirm("Alice", "alice@example.test")

    @cafe.update!(starts_at: Time.zone.local(2026, 11, 12, 9, 30))
    after_quiet_period

    mail = mail_to("alice@example.test", "Nouvelle date pour le café : Café IA #9")
    assert mail
    assert_match(/jeudi 12 novembre à 9 h 30/, mail.text_part.body.to_s)
    assert mail.attachments.any? { |attachment| attachment.filename == "#{@cafe.slug}.ics" }

    visit URI(mail.text_part.body.to_s[%r{http://\S+/r/\S+}]).path
    click_button "Ouvrir la page du café"
    assert_current_path public_webinar_path(@cafe.slug)
    assert_text "Tu es inscrit·e, Alice"
  end

  test "café annulé : les inscrits reçoivent l'annulation, une seule fois" do
    register_and_confirm("Alice", "alice@example.test")

    @cafe.update!(visibility: "draft")
    after_quiet_period
    WebinarChangeNoticeJob.perform_now(WebinarChangeNotice.sole, WebinarChangeNotice.sole.revision)
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob)

    cancellations = ActionMailer::Base.deliveries.select { |mail| mail.subject == "Café annulé : Café IA #9" }
    assert_equal 1, cancellations.size
    assert_match(/mardi 10 novembre à 9 h 30 \(heure de Paris\), est annulé/, cancellations.sole.text_part.body.to_s)
  end
end
