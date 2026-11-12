# frozen_string_literal: true

# Un aperçu par annonce et par tonalité (Voice) des mails de changement d'un
# webinaire. Objets non enregistrés : l'aperçu n'écrit rien en base.
class WebinarChangeMailerPreview < ActionMailer::Preview
  KINDS = { "cafe_ia" => "Café IA #9", "par_defaut" => "Bootcamp découverte" }.freeze
  TOKEN = "PREVIEWTOKEN0000000000000000abcd"

  KINDS.each do |suffix, title|
    kind = suffix == "par_defaut" ? "bootcamp" : suffix

    define_method(:"rescheduled_#{suffix}") do
      WebinarChangeMailer.rescheduled(preview_registration(kind, title))
    end

    define_method(:"cancelled_#{suffix}") do
      registration = preview_registration(kind, title)
      WebinarChangeMailer.cancelled(registration, starts_at: registration.webinar.starts_at - 2.days)
    end
  end

  private

  def preview_registration(kind, title)
    webinar = Webinar.new(title: title, kind: kind, slug: "#{kind.dasherize}-preview", room_name: "preview-room",
                          host_sub: "preview", starts_at: 5.days.from_now.change(hour: 9, min: 30),
                          created_at: 1.week.ago, updated_at: Time.current)
    Registration.new(webinar: webinar, email: "spectateur@example.test", name: "Camille", token: TOKEN)
  end
end
