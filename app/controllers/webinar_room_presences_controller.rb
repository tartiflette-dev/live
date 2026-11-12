# Page « Présence » d'un webinaire (PresenceTimeline) : consultation seule.
# Elle nomme les inscrits : même périmètre que leur liste
# (WebinarRegistrationsController) — propriétaire et animateurs du projet,
# 404 pour un co-animateur invité.
class WebinarRoomPresencesController < ApplicationController
  include AnimateurBrowserPolicy
  before_action :authenticate_animateur!

  def show
    @webinar = Webinar.where_managed_by(current_user).find_by!(slug: params[:webinar_id])
    @timeline = PresenceTimeline.new(@webinar).call
    # Graphiques seulement s'il y a au moins une présence datée.
    @chart = PresenceChart.new(@timeline) if @timeline.window
  end
end
