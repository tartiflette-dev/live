class EpisodePublicationMailer < ApplicationMailer
  # Mail à UN intervenant : l'épisode est déposé dans Nextcloud
  # (EpisodeNotification). Factuel : dossier et lien, durée du direct,
  # liste des fichiers PARTAGÉS ; des vidéos en relecture sont annoncées,
  # sans nom ni lien. Réponse adressée à l'animateur propriétaire.
  def published(publication, speaker)
    @publication = publication
    @files       = publication.files_in("shared")
    @in_review   = publication.files_in("review", "approved").any?
    @speaker     = speaker
    @webinar     = publication.webinar
    @date        = I18n.l(@webinar.starts_at.to_date, format: :long)
    @duration    = live_duration
    owner_email  = User.find_by(oidc_sub: @webinar.host_sub)&.email

    mail(
      to:       speaker.email,
      reply_to: owner_email,
      subject:  "#{@webinar.title} — fichiers déposés dans Nextcloud"
    )
  end

  private

  def live_duration
    started, ended = @webinar.started_at, @webinar.ended_at
    return unless started && ended

    "#{DurationFormat.short(ended - started)} (de #{started.strftime('%H:%M')} à #{ended.strftime('%H:%M')}, heure de Paris)"
  end
end
