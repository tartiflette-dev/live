require "test_helper"
require Rails.root.join("test/mailers/previews/registration_mailer_preview")

# Chaque aperçu se rend, dans la tonalité annoncée par son nom.
class RegistrationMailerPreviewTest < ActiveSupport::TestCase
  # Mails envoyés AVANT toute preuve de la boîte : ils ne reprennent jamais le
  # nom saisi. `request_confirmation` commence par
  # `request_`, pas par `confirmation`, d'où la liste explicite.
  UNPROVEN_ADDRESS_MAILS = %w[confirmation_ request_confirmation_ speaker_link_].freeze

  RegistrationMailerPreview.emails.each do |email|
    test "aperçu #{email}" do
      mail = RegistrationMailerPreview.call(email)
      text = mail.text_part.body.to_s

      assert_predicate mail.subject, :present?
      assert_predicate mail.html_part.body.to_s, :present?
      unproven = UNPROVEN_ADDRESS_MAILS.any? { |name| email.start_with?(name) }
      greeting = email.end_with?("_cafe_ia") ? "Salut" : "Bonjour"
      if unproven
        assert_match(/\A#{greeting},/, text)
        assert_no_match(/Camille/, text, "mail à une adresse non prouvée : le nom saisi n'y figure pas")
      else
        assert_match(/#{greeting} Camille/, text)
      end
    end
  end

  test "un aperçu par mail et par tonalité" do
    mails = RegistrationMailer.action_methods.sort
    expected = mails.flat_map { |name| [ "#{name}_cafe_ia", "#{name}_par_defaut" ] }.sort
    assert_equal expected, RegistrationMailerPreview.emails.sort
  end
end
