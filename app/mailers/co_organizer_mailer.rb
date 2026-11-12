# Message laissé à une inscription CONFIRMÉE venue du site partenaire
# (API d'inscription cross-origin), transmis aux co-organisateurs.
# Destinataire = `CO_ORGANIZERS_NOTIFY_TO` ;
# variable absente = aucun envoi. Partage annoncé par /confidentialite.
# Envoi : RegistrationRequest#notify_team!, une fois par demande.
#
# Sujet fixe (par tonalité, voices.<tonalité>.co_organizer_mailer), sans
# nom : le nom et le message sont du texte saisi par un inconnu, ils
# restent dans le corps. Reply-To = la personne, pour que
# les co-organisateurs puissent lui répondre comme avec le mailto.
class CoOrganizerMailer < ApplicationMailer
  include VoicedMailer

  def self.recipient
    ENV["CO_ORGANIZERS_NOTIFY_TO"].presence
  end

  def message_received(registration_request, to:)
    @registration_request = registration_request
    @registrations = registration_request.published_registrations.to_a
    speak_as registration_request.voice

    mail(
      to:       to,
      reply_to: registration_request.email,
      subject:  voiced_subject
    )
  end
end
