class HostInvitationsController < ApplicationController
  # Lien animateur — page PUBLIQUE /a?t=<token>.
  #
  # Sans effet : la page ne fait qu'expliquer et proposer la connexion. Son
  # bouton POSTe le jeton vers /auth/pocket_id (CSRF :
  # omniauth-rails_csrf_protection) ; l'acceptation a lieu au retour de
  # Pocket ID (SessionsController#oidc_callback). Jeton en query `t`, masqué
  # des journaux Rails par filter_parameters ; TokenLinkPage tient la page
  # hors cache et le jeton hors du Referer.
  include TokenLinkPage

  before_action :require_html_format

  def show
    @invitation = HostInvitation.find_by_token(params[:t])
    return render :unavailable, status: :not_found if @invitation.nil?
    return render :unavailable, status: :gone unless @invitation.usable?

    @webinar = @invitation.webinar
  end

  private

  # Aperçu de lien (messageries, scanners) en Accept non HTML : 406 plutôt
  # qu'un MissingTemplate (cf. WebinarsController).
  def require_html_format
    head :not_acceptable unless request.format.html? || request.format.all?
  end
end
