class MarketingConsentsController < ApplicationController
  # Validation du consentement marketing — jeton à usage unique, horodaté,
  # expirable, envoyé par mail à l'adresse qui a été saisie, qui PROUVE
  # que la personne qui le clique a accès à l'adresse ET VEUT recevoir
  # des sollicitations.
  #
  # Sécurité :
  # - GET /mc?t=<token>  = page de confirmation SANS effet (immunisée
  #   aux scanners de liens Outlook Safe Links / antivirus) ;
  # - POST /mc?t=<token> = applique le consentement (CSRF via button_to) ;
  # - POST /mc/decline?t=<token> = refus explicite, consomme le jeton ;
  # - jeton en QUERY STRING `t` (filter_parameters), jamais en PATH ;
  # - jeton distinct du `Registration.token` d'inscription ;
  # - jeton rejeté si expiré (TTL 14 j), avec message clair ;
  # - affichage sans PII (ni email, ni nom — seul le titre du webinaire).

  include TokenLinkPage

  # GET /mc?t=<token>
  def show
    @registration = Registration.find_by_marketing_consent_token(params[:t])
    return render :invalid, status: :not_found unless @registration&.webinar&.visibility_published?

    @voice = @registration.webinar.voice
    return render :expired, status: :gone if @registration.marketing_consent_token_expired?
    return render :already_consented if @registration.marketing_consent?

    @webinar_title = @registration.webinar.title
    # Pas de @registration.email dans la vue — aucune donnée personnelle.
  end

  # POST /mc?t=<token>
  def create
    registration = Registration.find_by_marketing_consent_token(params[:t])
    return render :invalid, status: :not_found unless registration&.webinar&.visibility_published?

    @voice = registration.webinar.voice

    # Sérialisation garantie 2 : un retrait concurrent est
    # exécuté sous le MÊME verrou (voir MarketingWithdrawalsController).
    # Si le retrait gagne la course, `apply_marketing_consent!` voit
    # `marketing_consent_withdrawn_at.present?` et refuse → état final
    # déterministe : retiré si retrait postérieur.
    newly_consented = registration.with_lock { registration.apply_marketing_consent! }

    unless newly_consented
      return render :already_withdrawn, status: :gone if registration.marketing_consent_withdrawn?
      return render :expired, status: :gone if registration.marketing_consent_token_expired?
      return render :already_consented
    end

    # Mail de merci + lien de retrait (chaque mail concerné porte un
    # moyen de retrait). CRM : enqueue seulement
    # si l'inscription a été confirmée ET que la synchro est activée —
    # évite d'empiler des jobs qui seront no-op (cf. CrmSyncJob invariants).
    RegistrationMailer.marketing_consent_confirmed(registration).deliver_later
    if registration.crm_sync_eligible? && ENV["CRM_SYNC_ENABLED"] == "1"
      CrmSyncJob.perform_later(registration.id)
    end

    @webinar_title = registration.webinar.title
    render :created
  end

  # POST /mc/decline?t=<token> — refus explicite ("Non merci").
  def decline
    registration = Registration.find_by_marketing_consent_token(params[:t])
    return render :invalid, status: :not_found unless registration&.webinar&.visibility_published?

    @voice = registration.webinar.voice

    registration.with_lock { registration.decline_marketing_consent! }
    @webinar_title = registration.webinar.title
    render :declined
  end
end
