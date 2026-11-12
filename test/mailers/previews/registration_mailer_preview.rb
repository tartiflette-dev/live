# frozen_string_literal: true

# Un aperçu par mail et par tonalité (Voice) : `*_cafe_ia` = tutoiement de
# tartiflette.dev, `*_par_defaut` = tonalité par défaut (bootcamp).
# Objets non enregistrés : l'aperçu n'écrit rien en base.
class RegistrationMailerPreview < ActionMailer::Preview
  KINDS = { "cafe_ia" => "Café IA #8", "par_defaut" => "Bootcamp découverte" }.freeze
  TOKEN = "PREVIEWTOKEN0000000000000000abcd"

  KINDS.each do |suffix, title|
    kind = suffix == "par_defaut" ? "bootcamp" : suffix

    define_method(:"confirmation_#{suffix}") do
      registration = preview_registration(kind, title, marketing_consent_token: "PREVIEWMC", marketing_consent_token_expires_at: 14.days.from_now)
      RegistrationMailer.confirmation(registration)
    end

    define_method(:"request_confirmation_#{suffix}") do
      RegistrationMailer.request_confirmation(preview_request(kind, title))
    end

    define_method(:"access_#{suffix}") do
      RegistrationMailer.access(preview_registration(kind, title))
    end

    define_method(:"reminder_#{suffix}") do
      RegistrationMailer.reminder(preview_registration(kind, title))
    end

    define_method(:"speaker_link_#{suffix}") do
      registration = preview_registration(kind, title)
      speaker = Speaker.new(webinar: registration.webinar, name: "Camille D.", declared_email: registration.email, link_token: "PREVIEWLINK")
      RegistrationMailer.speaker_link(speaker, registration)
    end

    define_method(:"marketing_consent_confirmed_#{suffix}") do
      RegistrationMailer.marketing_consent_confirmed(preview_registration(kind, title, marketing_withdrawal_token: "PREVIEWWD"))
    end
  end

  private

  def preview_webinar(kind, title)
    Webinar.new(
      title: title, kind: kind, slug: "#{kind.dasherize}-preview", room_name: "preview-room",
      host_sub: "preview", starts_at: 1.day.from_now.change(hour: 9, min: 30),
      created_at: Time.current, updated_at: Time.current
    )
  end

  def preview_registration(kind, title, **attributes)
    Registration.new(webinar: preview_webinar(kind, title), email: "spectateur@example.test", name: "Camille",
                     token: TOKEN, **attributes)
  end

  # Demande groupée : le mailer lit ses cafés en base ; l'aperçu les fournit.
  def preview_request(kind, title)
    request = RegistrationRequest.new(name: "Camille", email: "camille@example.test", source: "tartiflette.dev",
                                      notify_next: kind == "cafe_ia", token: TOKEN)
    registrations = [ preview_registration(kind, title) ]
    request.define_singleton_method(:published_registrations) { registrations }
    request
  end
end
