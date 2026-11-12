# Régénérer le lien participants privé depuis la régie. Une personne retirée
# peut revenir en caméra par ce
# lien partagé tant qu'il vit : toute l'animation du webinaire (owner,
# project_host, co-animateur invité, scope `where_animated_by`) peut le
# fermer pendant le direct, même seule en régie. Régénérer SEULEMENT : créer
# un lien absent et le désactiver restent à la gestion des intervenants
# (WebinarShareLinksController, owner et project_host).
#
#   POST /webinars/:webinar_id/share_link/regeneration
#     → 200 { link, masked_link, fingerprint } pour le propriétaire et
#       l'animateur du projet (can_manage_speakers?)
#     → 200 { fingerprint } pour un co-animateur invité : il ferme la porte
#       sans recevoir le nouveau lien, qui fait entrer des intervenants
#       (inviter reste au propriétaire)
#     → 409 { error: "no_share_link" } sans lien actif, rien de créé
#     → 403 { error: "not_live" } pour un co-animateur invité hors direct,
#       rien ne change : régénérer avant l'événement couperait les
#       intervenants invités qui n'ont pas encore cliqué (même règle que la
#       modération). Propriétaire et animateur du projet : à tout moment.
#
# L'ancien lien meurt ; les intervenants déjà entrés gardent leur lien
# personnel. Le nouveau jeton ne voyage que dans cette réponse à un POST
# protégé CSRF, jamais dans un GET ni dans les journaux : la régie l'affiche
# masqué (masked_token_link) et le copie. `fingerprint` lui sert à voir si
# le lien affiché a été remplacé depuis (Webinar#share_token_fingerprint,
# relu dans /regie/status).
#
# Sans session animateur (anonyme, intervenant, spectateur) : 403 en JSON,
# pas de renvoi vers la page de connexion ; sans rôle d'animation : 404
# (défense énumération).
class WebinarShareLinkRegenerationsController < ApplicationController
  include JsonCsrfRefusal

  before_action :require_animateur_session
  before_action :set_webinar
  before_action :require_live_for_guest

  def create
    response.headers["Cache-Control"] = "no-store"
    token = @webinar.regenerate_share_token!
    return render json: { error: "no_share_link" }, status: :conflict unless token

    render json: regeneration_payload(token)
  end

  private

  def regeneration_payload(token)
    payload = { fingerprint: @webinar.share_token_fingerprint }
    return payload unless @webinar.can_manage_speakers?(current_user)

    link = invitation_url(t: token)
    payload.merge(link: link, masked_link: helpers.masked_token_link(link))
  end

  # Le co-animateur invité ferme la porte pendant le direct seulement.
  def require_live_for_guest
    return if @webinar.live? || @webinar.can_manage_speakers?(current_user)

    render json: { error: "not_live" }, status: :forbidden
  end

  def require_animateur_session
    render json: { error: "animateur_session_required" }, status: :forbidden unless user_signed_in?
  end

  def set_webinar
    @webinar = Webinar.where_animated_by(current_user).find_by(slug: params[:webinar_id])
    render json: { error: "not_found" }, status: :not_found unless @webinar
  end
end
