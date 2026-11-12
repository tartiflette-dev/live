require "application_system_test_case"

# Le lien du rappel de la veille ouvre le direct à la personne inscrite.
class RegistrationReminderSystemTest < ApplicationSystemTestCase
  include ActionMailer::TestHelper

  test "le lien du rappel donne accès à la page du webinaire en tant qu'inscrite" do
    webinar = Webinar.create!(title: "Café IA rappel", starts_at: 1.day.from_now.change(hour: 9, min: 30),
                              host_sub: "host", visibility: "published")
    webinar.registrations.create!(name: "Alice", email: "alice@example.test").confirm!

    assert_emails(1) { RegistrationReminder.deliver_due(webinar.starts_at.yesterday.change(hour: 9)) }
    link = ActionMailer::Base.deliveries.last.text_part.body.to_s[%r{https?://\S+/r/\S+}]

    visit URI(link).path
    click_button "Ouvrir la page du café" # le GET ne donne plus l'accès seul
    assert_current_path public_webinar_path(webinar.slug)
    assert_text "Tu es inscrit·e, Alice"
    assert_no_button "Je viens"
  end
end
