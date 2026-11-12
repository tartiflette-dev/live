class RegistrationMailer < ApplicationMailer
  # Double opt-in : lien opaque vers la confirmation.
  #
  # Si une intention de consentement marketing a été portée par la
  # soumission (`marketing_consent_requested?`), la vue affiche un SECOND
  # bloc EXPLICITEMENT distinct : « Si vous avez coché la case… cliquez
  # sur ce lien séparé. » Le
  # destinataire doit comprendre qu'il peut cliquer SEULEMENT le lien
  # d'inscription et ne pas être recontacté — même si un tiers a coché
  # la case en son nom. Le lien de consentement pointe vers GET /mc?t=…
  # (sans effet) ; le consentement effectif ne se pose qu'au POST du
  # button_to côté MarketingConsentsController.
  # Inscription ouverte par l'accès immédiat (identité provisoire) : le mail
  # nomme la personne entrée et dit de confirmer depuis le même navigateur
  # pour garder ses échanges (RegistrationsController#hand_over sinon).
  def confirmation(registration)
    @registration = registration
    @webinar      = registration.webinar
    speak_as @webinar.voice
    @confirm_url  = confirm_registration_url(registration.token)
    @webinar_url  = public_webinar_url(@webinar.slug)
    @starts_at    = I18n.l(@webinar.starts_at, format: :long)
    @marketing_consent_url =
      if registration.marketing_consent_requested? && !registration.marketing_consent?
        marketing_consent_url(t: registration.marketing_consent_token)
      end

    mail(
      to:      registration.email,
      subject: subject_for(:confirmation, title: @webinar.title)
    )
  end

  # Demande de l'API cross-origin (docs/registrations-api.md) :
  # UN mail, UN lien `/confirmer?t=` pour tous les cafés créés ensemble et
  # le « préviens-moi du prochain ». Case de recontact cochée lors de la
  # demande : un paragraphe annonce les deux boutons de la page (politique
  # v1.6, RegistrationRequest#marketing_choice_offered?), sans second lien.
  def request_confirmation(registration_request)
    @registration_request = registration_request
    @registrations = registration_request.published_registrations.to_a
    speak_as registration_request.voice
    @confirm_url = registration_request_url(t: registration_request.token)

    mail(
      to:      registration_request.email,
      subject: subject_for(:request_confirmation)
    )
  end

  # Rappel de la veille (RegistrationReminder) à une inscription CONFIRMÉE :
  # le lien personnel `/r/:token`, celui de la confirmation, qui donne accès
  # au direct (cookie + page du webinaire) ; l'événement en pièce jointe
  # (WebinarCalendar#event, même UID que /w/:slug.ics : un agenda le met à
  # jour au lieu de le dupliquer). Pas de lien de retrait marketing : ce
  # mail n'est pas de la prospection, et la confirmation n'en porte pas.
  def reminder(registration)
    @registration = registration
    @webinar      = registration.webinar
    speak_as @webinar.voice
    @access_url   = confirm_registration_url(registration.token)
    @starts_at    = I18n.l(@webinar.starts_at, format: :long)
    calendar = WebinarCalendar.new(page_url: ->(webinar) { public_webinar_url(webinar.slug) })
    attachments["#{@webinar.slug}.ics"] = { mime_type: "text/calendar", content: calendar.event(@webinar) }

    mail(
      to:      registration.email,
      subject: subject_for(:reminder, title: @webinar.title, time: reminder_time)
    )
  end

  # Adresse saisie au lien participants privé, neuve ou déjà inscrite, sans
  # preuve de la boîte (InvitationEntry : seul le cookie d'une inscription
  # confirmée en tient lieu) : on demande à la personne si elle est bien
  # intervenue sous ce nom. Le lien, valable 14 jours (Speaker::LINK_TTL),
  # ouvre une page sans effet ; le rattachement n'a lieu qu'au POST de son
  # bouton (SpeakerLinksController). Ne pas cliquer suffit à ce que rien ne
  # soit attribué à sa fiche.
  def speaker_link(speaker, registration)
    @speaker      = speaker
    @registration = registration
    @webinar      = speaker.webinar
    speak_as @webinar.voice
    @link_url     = speaker_link_url(t: speaker.link_token)

    mail(
      to:      registration.email,
      subject: subject_for(:speaker_link, title: @webinar.title)
    )
  end

  # Inscription neuve créée par la reprise d'une identité provisoire
  # (RegistrationsController#hand_over) : confirmée, elle s'ouvre sur ce
  # navigateur ; ce mail donne son lien personnel `/r/:token` (page à bouton,
  # cookie posé au POST) pour l'ouvrir sur un autre.
  def access(registration)
    @registration = registration
    @webinar      = registration.webinar
    speak_as @webinar.voice
    @access_url   = confirm_registration_url(registration.token)
    @starts_at    = I18n.l(@webinar.starts_at, format: :long)

    mail(
      to:      registration.email,
      subject: subject_for(:access, title: @webinar.title)
    )
  end

  # Mail envoyé APRÈS validation du consentement marketing. Chaque mail
  # concerné porte un moyen de retrait : lien
  # direct vers /mc/withdraw?t=<withdrawal_token> + rappel de l'adresse de contact (Brand.support_email).
  def marketing_consent_confirmed(registration)
    @registration    = registration
    @webinar         = registration.webinar
    speak_as @webinar.voice
    @withdrawal_url  = marketing_withdrawal_url(t: registration.marketing_withdrawal_token)

    mail(
      to:      registration.email,
      subject: subject_for(:marketing_consent_confirmed)
    )
  end

  private

  # Tonalité du mail (Voice) : le gabarit `<action>.<format>+<tonalité>.erb`
  # s'il existe (variante ActionView), sinon le gabarit par défaut.
  def speak_as(voice)
    @voice = voice
    lookup_context.variants = [ voice.to_sym ] unless voice == Voice::DEFAULT
  end

  def subject_for(action, **values)
    Voice.t("registration_mailer.#{action}.subject", voice: @voice, **values)
  end

  def reminder_time
    I18n.l(@webinar.starts_at, format: Voice.t("registration_mailer.reminder.time_format", voice: @voice))
  end
end
