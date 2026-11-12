# Fin du « préviens-moi du prochain Café IA », depuis le lien des envois
# groupés « préviens-moi » (AnnouncementMailer) :
#
#   GET  /prochain/stop?t=<jeton> → page SANS EFFET (les scanners de liens
#                                   suivent les GET), un bouton ;
#   POST /prochain/stop?t=<jeton> → arrêt pour la personne : toutes ses
#                                   demandes confirmées (CSRF via button_to).
#
# Jeton signé, sans colonne (RegistrationRequest `generates_token_for`) :
# il cesse de valoir une fois l'arrêt posé ; un lien re-cliqué ou inconnu
# donne la même page neutre, 404. Ni les inscriptions ni le consentement
# marketing ne changent. Mêmes protections que /mc/withdraw : jeton en query
# string, pas de donnée personnelle à l'écran, `no-store`, Referrer-Policy
# strict-origin (TokenLinkPage). Tonalité Café IA : la demande vise le
# prochain Café IA.
class NotifyNextStopsController < ApplicationController
  include TokenLinkPage

  before_action { @voice = "cafe_ia" }
  before_action :set_request

  def show
  end

  def create
    RegistrationRequest.stop_notify_next_of(@notify_request.email)
    render :created
  end

  private

  def set_request
    @notify_request = RegistrationRequest.find_by_token_for(:notify_next_stop, params[:t].to_s)
    render :invalid, status: :not_found unless @notify_request&.confirmed?
  end
end
