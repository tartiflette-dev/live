# Battements du lecteur de replay (app/javascript/replay_player.js) :
#
#   POST /w/:slug/replay/battements
#     { session: "<uuid v4 de l'onglet>", from: 12.0, to: 27.1, playing: true }
#     → 204 ; 422 battement mal formé ; 404 sans accès au replay ;
#       409 séance d'une autre personne ; 429 débit dépassé.
#
# La personne est décidée SERVEUR (ReplayAccess : compte connecté d'abord,
# sinon inscription de ce navigateur), jamais lue du corps. Débit borné par
# personne (compteurs fichier partagés par les workers, comme la
# discussion) et par séance (ReplayView).
class ReplayViewsController < ApplicationController
  include ReplayAccess
  include JsonCsrfRefusal

  RATE_LIMIT_STORE = RegistrationRateLimitStore.new(name: "replay_rate_limits")

  before_action :require_json!
  before_action :set_viewer

  # Un battement toutes les ~15 s, plus pauses et sauts : 20 par minute
  # laissent la place à un deuxième onglet.
  rate_limit to: 20, within: 1.minute, name: "replay-beats",
    by: :rate_limit_key, store: RATE_LIMIT_STORE, with: :render_rate_limited

  rescue_from ReplayView::Refused do |refusal|
    status = refusal.message == "sessions_cap" ? :too_many_requests : :conflict
    render json: { error: refusal.message }, status: status
  end

  rescue_from ActiveRecord::RecordInvalid do
    render json: { error: "invalid_beat" }, status: :unprocessable_entity
  end

  def create
    from, to = params.values_at(:from, :to).map { |value| Float(value, exception: false) }
    return render(json: { error: "invalid_beat" }, status: :unprocessable_entity) unless from && to

    ReplayView.beat!(replay: @replay, viewer: @viewer, session_key: params[:session].to_s,
                     from: from, to: to, playing: ActiveModel::Type::Boolean.new.cast(params[:playing]) == true)
    head :no_content
  end

  private

  def require_json!
    head :unsupported_media_type unless request.media_type == "application/json"
  end

  def set_viewer
    webinar = Webinar.find_by(slug: params[:slug])
    @replay = webinar&.replay
    @viewer = webinar && replay_viewer(webinar)
    head :not_found unless replay_open_to?(@replay, @viewer)
  end

  def rate_limit_key
    "#{@viewer.class.name.underscore}-#{@viewer.id}"
  end

  def render_rate_limited
    render json: { error: "rate_limited" }, status: :too_many_requests
  end
end
