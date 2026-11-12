# frozen_string_literal: true

# EpisodeNotification — prévient les intervenants qu'un épisode est déposé.
# Envoi automatique à des tiers, autorisé
# explicitement pour cette fonction ; contenu factuel :
# lien du dossier, liste des fichiers, durée. Seul ce qui est PARTAGÉ est
# nommé et lié ; des vidéos en relecture sont seulement annoncées.
#
# Destinataires : les intervenants actifs du webinaire dont l'animation a
# saisi l'adresse — jamais les spectateurs. Un mail par personne (aucune
# adresse n'est montrée aux autres), jamais deux fois pour la même liste
# de fichiers (EpisodePublication#notified_emails). Un envoi en échec
# n'empêche pas les autres ; il est noté sur la publication et part à la
# relance suivante.
#
# WhatsApp : canal injecté, désactivé (WhatsappChannel). Il accompagne le
# mail : mêmes destinataires, même fois (jamais à chaque relance). Le
# message ne porte pas le lien, qui part par mail (préférence de contact : liens par mail).
class EpisodeNotification
  def initialize(publication, whatsapp: WhatsappChannel.new)
    @publication = publication
    @webinar     = publication.webinar
    @whatsapp    = whatsapp
  end

  def deliver
    pending = recipients.reject { |speaker| @publication.notified?(speaker.email) }
    mailed, failed = pending.partition { |speaker| mail(speaker) }
    @publication.update!(error_message: "Mail non envoyé à : #{failed.map(&:email).join(', ')}") if failed.any?
    mailed.each { |speaker| @whatsapp.deliver(speaker: speaker, text: whatsapp_text) } if @whatsapp.enabled?
  end

  private

  def whatsapp_text
    count = @publication.files_in("shared").size
    "« #{@webinar.title} » : les fichiers du direct (#{count} fichier#{'s' if count > 1}) " \
      "sont déposés dans Nextcloud, dossier #{@publication.folder}."
  end

  def recipients
    @webinar.speakers.reachable_by_email.order(:id)
  end

  def mail(speaker)
    EpisodePublicationMailer.published(@publication, speaker).deliver_now
    @publication.record_notification!(speaker.email)
    true
  rescue StandardError => error
    Rails.logger.error("[episode_notification] webinar=#{@webinar.slug} speaker=#{speaker.id} err=#{error.class}")
    false
  end
end
