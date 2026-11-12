# Mise en avant d'un intervenant pendant le direct.
#
#   POST   /webinars/:webinar_id/spotlight  { identity }  → pose ou remplace
#   DELETE /webinars/:webinar_id/spotlight                → retire
#
# Réservé à l'animation (owner, project_host, guest_host) : même scope
# `where_animated_by` que les mains levées et le cycle live, donc le même
# périmètre que `Webinar#can_animate?`. Un utilisateur sans rôle reçoit
# 404 (défense énumération), un anonyme est renvoyé vers la connexion.
# Intervenants (lien `t`) et spectateurs n'ont pas de session animateur :
# ils ne passent jamais. L'écriture va dans les métadonnées de la salle
# LiveKit (RoomSpotlight), que tous les clients lisent.
class WebinarSpotlightsController < ApplicationController
  before_action :authenticate_animateur!
  before_action :set_webinar

  rescue_from RoomSpotlight::InvalidIdentity do
    render json: { error: "invalid_identity" }, status: :unprocessable_entity
  end

  rescue_from RoomServiceClient::Error do |error|
    Rails.logger.warn("[webinar_spotlights] webinar=#{@webinar.id} #{error.class}: #{error.message}")
    render json: { error: "spotlight_update_failed" }, status: :bad_gateway
  end

  def create
    render json: { spotlight: spotlight.feature(params[:identity]) }
  end

  def destroy
    render json: { spotlight: spotlight.clear }
  end

  private

  def set_webinar
    @webinar = Webinar.where_animated_by(current_user).find_by!(slug: params[:webinar_id])
  end

  def spotlight
    RoomSpotlight.new(@webinar)
  end
end
