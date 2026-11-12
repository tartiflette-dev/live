# « Ajoute le Café IA à ton agenda » : le lien du flux d'agenda personnel
# (CalendarSubscription), envoyé une fois par personne, après la première
# confirmation d'une inscription — jamais à une adresse non prouvée. Les
# portes d'entrée (webcal, Google, Outlook, téléchargement) visent toutes
# /agenda/<jeton>.ics, restreint à l'émission quand la tonalité en est une.
# Pas de lien de retrait marketing : ce mail n'est pas de la prospection.
class CalendarSubscriptionMailer < ApplicationMailer
  include VoicedMailer

  def feed_link(subscription, name:, voice:)
    speak_as voice
    @name = name
    kind = voice if Webinar::KINDS.include?(voice)
    feed_url = personal_agenda_url(subscription.token, format: :ics, kind: kind)
    @links = CalendarSubscribeLinks.new(feed_url, name: WebinarCalendar.feed_name(kind))

    mail(to: subscription.email, subject: voiced_subject)
  end
end
