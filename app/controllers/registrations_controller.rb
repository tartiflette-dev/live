class RegistrationsController < ApplicationController
  include CurrentRegistration
  include RegistrationsHelper
  include TokenLinkPage
  skip_before_action :protect_token_link_page, only: :create

  # `scope: :registrations` : compteur commun avec l'API cross-origin
  # (Api::RegistrationsController) — 10 inscriptions/minute/IP (préfixe /64
  # en IPv6, ClientNetwork) au total. Le mail envoyé à l'adresse saisie a sa
  # propre limite, par destinataire (RecipientMailThrottle).
  rate_limit to: 10, within: 1.minute, only: :create, scope: :registrations,
    by: -> { Digest::SHA256.hexdigest(ClientNetwork.key(request.remote_ip)) },
    store: RegistrationRateLimitStore.new,
    with: -> { render plain: "Trop de demandes. Réessayez dans une minute.", status: :too_many_requests }

  def create
    @webinar = Webinar.published.find_by!(slug: params[:slug])
    @voice = @webinar.voice
    return head :gone if @webinar.ended?
    return head :service_unavailable unless registration_privacy_url
    # Navigateur retiré de ce webinaire (RoomRemoval) : ni inscription, ni
    # accès immédiat sous une autre adresse.
    return render_room_removed if room_removed?(@webinar)

    attributes = params.expect(registration: [ :name, :email, :participation, :marketing_consent ])
    @registration = @webinar.registrations.new(attributes.except(:marketing_consent))
    @registration.valid?
    errors = @registration.errors.reject { |error| error.type == :taken && error.attribute == :email }
    unless errors.empty? && @registration.email.to_s.length <= 254
      @registration_error = Voice.t("registrations.invalid_submission", voice: @voice)
      render "webinars/pre_live", status: :unprocessable_entity
      return
    end

    registration, created = Registration.find_or_create_for(@webinar, email: @registration.email, name: @registration.name,
                                                            participation: @registration.participation)
    # Sécurité : une soumission anonyme
    # ne modifie JAMAIS le consentement d'une inscription EXISTANTE —
    # sinon n'importe qui, en connaissant l'email d'un tiers, pourrait
    # faire émettre un lien de consentement en son nom. Un JETON DÉDIÉ
    # (`marketing_consent_token`, expiration 14 j, voir modèle) est émis
    # UNIQUEMENT sur une inscription NOUVELLE, et le consentement devient
    # effectif via le POST (CSRF-protégé) de /mc?t=<token>, surtout PAS
    # via le /r/:token d'inscription qui ne touche plus au marketing.
    if created && attributes[:marketing_consent] == "1"
      registration.request_marketing_consent!
    end
    # Accès immédiat pendant le direct : la salle s'ouvre sur
    # cet appareil sous une identité PROVISOIRE, le mail part quand même (il
    # prévient la boîte qu'on est entré avec son adresse) et le CRM attend sa
    # confirmation. Jamais pour
    # une inscription retrouvée : saisir l'adresse d'autrui ne fait pas entrer
    # sous son nom.
    #
    # Pas de mail possible (budget `:security` de RecipientMailThrottle
    # refusé) = pas d'accès immédiat : ce mail est ce qui prévient la boîte de
    # l'entrée sous son adresse, on n'ouvre jamais la salle sans lui.
    # L'inscription reste en attente.
    confirmation = PendingRegistrationMail.reserve_confirmation(
      registration, instant_access_wanted: created && @webinar.instant_access_open?, first: created
    )
    instant = confirmation.instant_access && registration.grant_instant_access!
    # Resending the same pending link permits recovery after a queue failure.
    # Confirmed registrations receive the identical response without extra mail.
    # Une inscription EN ATTENTE ne reçoit pas plus d'un mail par 10 minutes
    # (RecipientMailThrottle) : saisir l'adresse d'autrui n'arrose pas sa
    # boîte. La réponse est la même, mail parti ou non.
    confirmation.deliver
    return grant_access(registration) if instant

    render :pending
  end

  # GET /r/:token — TOUJOURS sans effet : page à bouton, le POST fait le
  # reste (CSRF).
  #   • non confirmée : les scanners de liens (Outlook Safe Links, antivirus)
  #     suivent les GET ; depuis la politique v1.6, confirmer fait
  #     entrer au CRM, un robot ne doit pas le faire à la place de la personne ;
  #   • déjà confirmée : bouton d'accès au direct. Le GET ne pose pas le
  #     cookie d'inscription : un lien envoyé par un tiers ne doit pas imposer
  #     son identité au navigateur qui l'ouvre ;
  #   • retirée de la salle : page « Accès retiré », aucun cookie ;
  #   • provisoire (accès immédiat), vue depuis un autre navigateur que le
  #     sien : la page demande un prénom, celui de l'inscription neuve
  #     (`hand_over`).
  def confirm
    registration = find_published_registration
    return head :not_found unless registration

    @webinar = registration.webinar
    @voice = @webinar.voice
    return render_room_removed if registration.room_removed_at

    @confirm_path = confirm_registration_path(registration.token)
    @hand_over = handed_over?(registration)
    render registration.confirmed? ? :access : :confirm
  end

  # POST /r/:token — confirmation par la personne (CSRF via button_to).
  # /r/:token ne touche PAS au consentement marketing : il prouve la
  # possession de l'adresse pour l'inscription, pas pour la prospection
  # (bascule uniquement via le POST de MarketingConsentsController).
  def confirm_registration
    registration = find_published_registration
    return head :not_found unless registration
    return hand_over(registration) if handed_over?(registration)

    enqueue_crm_sync(registration) if registration.confirm!
    grant_access(registration)
  end

  private

  # Identité provisoire (accès immédiat) dont le lien du mail est cliqué
  # depuis un AUTRE navigateur que celui qui la porte :
  # la boîte est prouvée, pas ce navigateur-là.
  def handed_over?(registration)
    registration.provisional? && registration_in_browser(registration.webinar.registrations) != registration
  end

  # La personne de la boîte reçoit une inscription neuve et confirmée, sous
  # le prénom et le choix qu'elle donne (Registration#hand_over!) ;
  # l'identité provisoire passe en pierre tombale et reste au navigateur qui
  # l'a ouverte, sans CRM ni attribution. Rien ne change tant que ce
  # navigateur ne peut pas recevoir l'inscription neuve (retiré, ou déjà
  # inscrit : 409). Un mail d'accès lui donne le lien de l'inscription neuve,
  # pour l'ouvrir sur un autre navigateur.
  def hand_over(provisional)
    @webinar = provisional.webinar
    @voice = @webinar.voice
    @confirm_path = confirm_registration_path(provisional.token)
    @hand_over = true
    return render_room_removed if room_removed?(@webinar)
    return render(:already_registered, status: :conflict) if current_registration

    @hand_over_name = params[:name].to_s.strip
    @hand_over_participation = params[:participation].presence || "spectator"
    unless @hand_over_name.present? && @hand_over_name.length <= 120 &&
           Registration.participations.key?(@hand_over_participation)
      @hand_over_invalid = true
      return render(:confirm, status: :unprocessable_entity)
    end

    fresh = provisional.hand_over!(name: @hand_over_name, participation: @hand_over_participation)
    return head :not_found unless fresh

    enqueue_crm_sync(fresh)
    RegistrationMailer.access(fresh).deliver_later
    grant_access(fresh)
  end

  # Tout inscrit confirmé entre au CRM comme participant ; le job pousse
  # aussi un consentement marketing déjà validé (ordre inverse rare).
  # Garde-fou `CRM_SYNC_ENABLED` ici aussi : évite d'empiler des jobs
  # no-op quand la synchro n'est pas câblée.
  def enqueue_crm_sync(registration)
    CrmSyncJob.perform_later(registration.id) if registration.crm_sync_eligible? && ENV["CRM_SYNC_ENABLED"] == "1"
  end

  def find_published_registration
    registration = Registration.find_by_token(params[:token])
    registration if registration&.webinar&.visibility_published?
  end

  # Cookie d'inscription, seulement ici (POST, CSRF), persistant
  # (RoomRemoval#identity_cookie). Refusé, sans cookie :
  #   • une inscription retirée de la salle : le navigateur n'adopte jamais une
  #     identité retirée ;
  #   • un navigateur déjà retiré de ce webinaire : la confirmation d'une autre
  #     inscription ne lui rend pas la salle, la trace du retrait reste ;
  #   • un navigateur qui porte déjà une inscription valide à ce webinaire :
  #     elle est gardée, jamais remplacée par une autre — sinon le bouton d'un
  #     lien envoyé par un tiers lui ferait prendre l'identité de ce tiers,
  #     bannie ensuite (docs/moderation.md). Message neutre sur l'inscription
  #     du lien ; seule l'inscription gardée est nommée, pour « Ce n'est pas
  #     moi » (CurrentRegistration#remember_registration).
  def grant_access(registration)
    @webinar = registration.webinar
    @voice = @webinar.voice
    return render_room_removed if registration.room_removed_at || room_removed?(@webinar)
    return render(:already_registered, status: :conflict) unless remember_registration(registration)

    redirect_to public_webinar_path(@webinar.slug)
  end
end
