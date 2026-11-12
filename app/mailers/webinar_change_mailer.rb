# Annonces de WebinarChangeNotice aux inscriptions confirmées d'un webinaire
# à venir : nouvelle date (événement joint, même UID que /w/:slug.ics et
# SEQUENCE croissante : l'agenda qui l'a déjà le déplace) ou annulation.
# Transactionnels : ni lien de retrait marketing, ni prospection.
class WebinarChangeMailer < ApplicationMailer
  include VoicedMailer

  def rescheduled(registration)
    @registration = registration
    @webinar      = registration.webinar
    speak_as @webinar.voice
    @starts_at    = @webinar.starts_at
    @access_url   = confirm_registration_url(registration.token)
    calendar = WebinarCalendar.new(page_url: ->(webinar) { public_webinar_url(webinar.slug) })
    attachments["#{@webinar.slug}.ics"] = { mime_type: "text/calendar", content: calendar.event(@webinar) }

    mail(to: registration.email, subject: voiced_subject(title: @webinar.title))
  end

  # @param starts_at [Time] la date annoncée jusque-là, celle qui est annulée
  def cancelled(registration, starts_at:)
    @registration = registration
    @webinar      = registration.webinar
    speak_as @webinar.voice
    @starts_at    = starts_at
    @agenda_url   = agenda_url

    mail(to: registration.email, subject: voiced_subject(title: @webinar.title))
  end
end
