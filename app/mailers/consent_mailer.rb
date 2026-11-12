class ConsentMailer < ApplicationMailer
  # Mails à l'animateur propriétaire du webinaire sur l'accord à l'image.
  # Sans compte connu pour le propriétaire, le
  # mail part à l'adresse de contact de la marque, celle de la politique de
  # confidentialité pour tout retrait.
  EXCERPTS_DELAY = 7.days
  REPLAY_DELAY = 30.days

  # Accord retiré dans la salle : les délais de dépublication promis par la
  # politique (docs/depublication.md) partent de ce mail.
  def withdrawn(consent)
    @webinar = consent.webinar
    @person = person_label(consent.holder, consent.participant_identity)
    @withdrawn_at = consent.withdrawn_at.in_time_zone("Europe/Paris")
    @excerpts_by = I18n.l((@withdrawn_at + EXCERPTS_DELAY).to_date, format: :long)
    @replay_by = I18n.l((@withdrawn_at + REPLAY_DELAY).to_date, format: :long)
    @recordings_url = webinar_recordings_url(@webinar)

    mail(to: owner_email, subject: "#{@webinar.title} — accord à l'image retiré : #{@person}")
  end

  # La salle n'a pas retiré le droit de publier d'une personne sans accord en
  # cours (PublishingRevocationJob, essais épuisés).
  def revocation_failed(webinar, holder)
    @webinar = webinar
    @person = person_label(holder, PublishPermission.identity_for(holder))
    @regie_url = webinar_regie_url(@webinar)

    mail(to: owner_email, subject: "#{@webinar.title} — droit de publier non retiré, sans accord à l'image")
  end

  private

  def owner_email
    User.find_by(oidc_sub: @webinar.host_sub)&.email.presence || Brand.support_email
  end

  def person_label(holder, identity)
    name = holder.is_a?(User) ? holder.email : holder&.name
    [ name, "(#{identity})" ].compact.join(" ")
  end
end
