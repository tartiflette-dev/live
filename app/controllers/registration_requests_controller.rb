class RegistrationRequestsController < ApplicationController
  # Confirmation d'une demande d'inscription de l'API cross-origin
  # (docs/registrations-api.md) : UN lien pour tous les
  # cafés de la soumission et le « préviens-moi du prochain ».
  #
  # Même schéma que /mc :
  # - GET /confirmer?t=<token>  = page SANS effet (les scanners de liens
  #   Outlook Safe Links / antivirus suivent les GET) ;
  # - POST /confirmer?t=<token> = confirme (CSRF via button_to), pose le
  #   consentement marketing sur le seul bouton qui le dit (`marketing=1`),
  #   puis fait entrer la personne au CRM et transmet son message aux
  #   co-organisateurs (RegistrationRequest#notify_team!) — des effets
  #   qu'un robot ne doit pas déclencher à sa place ;
  # - jeton en QUERY STRING `t` (filter_parameters), jamais en chemin ;
  # - POST rend la page directement : une redirection écrirait l'URL et
  #   son jeton en clair dans « Redirected to » du journal Rails.
  #
  # Une fois confirmée, la page liste les cafés avec leur lien personnel
  # `/r/:token` (inscription déjà confirmée : cookie posé, accès direct) —
  # le lien du mail reste la page d'accès de la personne.
  include TokenLinkPage
  before_action :set_registration_request

  def show
    render :confirmed if @registration_request.confirmed?
  end

  # Case de recontact cochée sur la demande : deux boutons explicites,
  # `marketing=1` (accord) et `marketing=0` (sans accord), libellés dans la
  # tonalité de la page (Voice, docs/tonalites.md). Seul `"1"` accorde
  # Un POST sans choix n'accorde rien.
  def confirm
    if @registration_request.confirm!(marketing_consent: params[:marketing] == "1")
      enqueue_crm_sync
      @registration_request.notify_team!
    end
    render :confirmed
  end

  private

  def set_registration_request
    @registration_request = RegistrationRequest.find_by_token(params[:t])
    return render :invalid, status: :not_found unless @registration_request

    @voice = @registration_request.voice
    render :invalid, status: :gone if @registration_request.confirmation_expired?
  end

  def enqueue_crm_sync
    return unless ENV["CRM_SYNC_ENABLED"] == "1"

    @registration_request.registrations.each { |registration| CrmSyncJob.perform_later(registration.id) }
    CrmNotifyNextJob.perform_later(@registration_request.id) if @registration_request.notify_next?
  end
end
