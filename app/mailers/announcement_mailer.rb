# Mail d'un envoi groupé (Announcement) à UN destinataire, mis en file par
# Announcement#enqueue_pending! (deliver_later étalé). Le texte est celui de
# l'auteur, tel quel ; le mail n'ajoute que le pied de la cible, dans sa
# tonalité, avec le lien personnel qu'elle donne (AnnouncementAudience) :
# accès au webinaire (inscrits, aucun lien de retrait), retrait du
# consentement (liste) ou arrêt du « préviens-moi » — ces deux derniers aussi
# en en-tête List-Unsubscribe.
#
# Une seule remise par marqueur : la remise est prise en base
# (AnnouncementDelivery#claim_sending!) avant tout rendu ; un job rejoué
# (redémarrage pendant un envoi étalé, relance manuelle) ne renvoie rien.
# Exclusion immédiate : la cible est relue à la remise ; qui n'en fait plus
# partie ne reçoit rien (`skipped_at`). Réponse adressée à l'auteur, ou au
# propriétaire du webinaire quand l'auteur est un co-animateur.
class AnnouncementMailer < ApplicationMailer
  # Marqueur effacé entre la mise en file et la remise : rien à envoyer.
  rescue_from ActiveJob::DeserializationError, with: -> { }

  after_deliver :mark_delivered

  def announcement(delivery)
    return unless delivery.claim_sending!

    @delivery = delivery
    @announcement = delivery.announcement
    @recipient = delivery.current_recipient
    return delivery.mark_skipped! unless @recipient

    @footer_url = @announcement.footer_url(@recipient.holder, self)
    headers["List-Unsubscribe"] = "<#{@footer_url}>" if @announcement.stop_link?

    mail(to: @recipient.email, reply_to: @announcement.reply_to_email, subject: @announcement.subject)
  end

  private

  def mark_delivered
    @delivery.mark_delivered! if @recipient
  end
end
