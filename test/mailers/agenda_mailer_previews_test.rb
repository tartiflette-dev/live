require "test_helper"
require Rails.root.join("test/mailers/previews/calendar_subscription_mailer_preview")
require Rails.root.join("test/mailers/previews/webinar_change_mailer_preview")

# Chaque aperçu des mails de l'agenda se rend, dans la tonalité annoncée par
# son nom ; un aperçu par mail et par tonalité.
class AgendaMailerPreviewsTest < ActiveSupport::TestCase
  PREVIEWS = { CalendarSubscriptionMailerPreview => CalendarSubscriptionMailer,
               WebinarChangeMailerPreview => WebinarChangeMailer }.freeze

  PREVIEWS.each_key do |preview|
    preview.emails.each do |email|
      test "aperçu #{preview.name} #{email}" do
        mail = preview.call(email)

        assert_predicate mail.subject, :present?
        assert_predicate mail.html_part.body.to_s, :present?
        greeting = email.end_with?("_cafe_ia") ? "Salut" : "Bonjour"
        assert_match(/\A#{greeting} Camille,/, mail.text_part.body.to_s)
      end
    end
  end

  PREVIEWS.each do |preview, mailer|
    test "#{preview.name} : un aperçu par mail et par tonalité" do
      expected = mailer.action_methods.sort.flat_map { |name| [ "#{name}_cafe_ia", "#{name}_par_defaut" ] }
      assert_equal expected.sort, preview.emails.sort
    end
  end
end
