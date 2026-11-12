class WebinarHostInvitationsController < ApplicationController
  # Liens animateur, côté gestion : créer et
  # révoquer depuis la page du webinaire. Réservé au propriétaire et aux
  # animateurs du projet (`where_managed_by`, comme WebinarHostsController) :
  # un co-animateur invité reçoit 404 (défense énumération).
  include AnimateurBrowserPolicy
  before_action :authenticate_animateur!
  before_action :set_webinar

  def create
    invitation = @webinar.host_invitations.build(invitation_params.merge(created_by_sub: current_user.oidc_sub))
    if invitation.save
      redirect_to webinar_path(@webinar), notice: "Lien animateur créé.", status: :see_other
    else
      redirect_to webinar_path(@webinar), alert: invitation.errors.full_messages.to_sentence, status: :see_other
    end
  end

  # Révoquer n'expulse pas les co-animateurs déjà entrés par ce lien : ils
  # se retirent un par un dans la liste des co-animateurs.
  def revoke
    @webinar.host_invitations.find(params[:id]).revoke!
    redirect_to webinar_path(@webinar), notice: "Lien animateur révoqué.", status: :see_other
  end

  private

  def set_webinar
    @webinar = Webinar.where_managed_by(current_user).find_by!(slug: params[:webinar_id])
  end

  def invitation_params
    params.require(:host_invitation).permit(:max_uses, :expires_at, :signup_url)
  end
end
