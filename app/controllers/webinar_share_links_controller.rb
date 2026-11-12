class WebinarShareLinksController < ApplicationController
  # Lien d'invitation intervenant PARTAGÉ, côté animateur. Génération / régénération / désactivation du jeton
  # opaque associé à un webinaire. L'URL publique vit sur
  # /i/:share_token (InvitationsController).
  #
  # Gestion réservée owner / project_host : un co-animateur INVITÉ n'a PAS la main sur
  # l'invitation d'intervenants (symétrie avec SpeakersController).
  # 404 pour un guest_host (défense énumération).
  include AnimateurBrowserPolicy
  before_action :authenticate_animateur!
  before_action :set_webinar

  # POST /webinars/:webinar_id/share_link
  # Génère (si absent) OU régénère (si présent — invalide l'ancien).
  # Idempotent côté effet métier : « l'animateur veut un lien actif »,
  # une double soumission produit un lien actif (pas d'erreur fonctionnelle).
  def create
    @webinar.generate_share_token!
    redirect_to webinar_path(@webinar),
                notice: "Lien d'invitation partagé prêt.",
                status: :see_other
  end

  # DELETE /webinars/:webinar_id/share_link
  # Désactive le lien (NULL). Les Speakers déjà créés RESTENT valides —
  # c'est l'intention : couper l'invitation collective sans priver les
  # invités déjà rentrés de leur accès.
  def destroy
    @webinar.disable_share_token!
    redirect_to webinar_path(@webinar),
                notice: "Lien d'invitation partagé désactivé.",
                status: :see_other
  end

  private

  def set_webinar
    @webinar = Webinar.where_managed_by(current_user).find_by!(slug: params[:webinar_id])
  end
end
