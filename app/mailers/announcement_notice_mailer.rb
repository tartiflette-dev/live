# Avis internes sur les envois groupés (Announcement#dispatch!), pour qu'un
# envoi ne passe jamais inaperçu :
#   • `list_sent`  — tout envoi aux listes, aux animateurs du projet ;
#   • `guest_sent` — tout envoi d'un co-animateur, au propriétaire du webinaire.
# Objet, auteur, cible, nombre de destinataires et lien vers le journal ; le
# texte de l'envoi y est repris. Sans destinataire connu, l'adresse de contact
# de la marque.
class AnnouncementNoticeMailer < ApplicationMailer
  helper AnnouncementsHelper

  def list_sent(announcement)
    @announcement = announcement
    @journal_url = webinar_announcements_url(announcement.webinar)
    mail(to: project_host_emails, subject: "Envoi à une liste : #{announcement.subject}")
  end

  def guest_sent(announcement)
    @announcement = announcement
    @journal_url = webinar_announcements_url(announcement.webinar)
    mail(to: announcement.owner_email,
         subject: "#{announcement.webinar.title} — message d'un co-animateur aux inscrits : #{announcement.subject}")
  end

  private

  def project_host_emails
    User.all.select(&:project_host?).map(&:email).presence || [ Brand.support_email ]
  end
end
