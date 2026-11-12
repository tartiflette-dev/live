# Points d'entrée JSON du spectateur d'un replay (sondages, questions) :
# même décision d'accès que la page et la vidéo (ReplayAccess), personne
# décidée SERVEUR (compte connecté d'abord, sinon l'inscription de ce
# navigateur à CE webinaire), jamais lue du corps. Sans accès : 404.
# Écrire exige en plus un replay publié : l'animation qui relit son replay
# avant publication n'ajoute rien aux résultats ni à la file.
#
# Débit borné par personne (compteurs fichier partagés par les workers,
# comme les battements), clé = sa voie et son id.
module ReplayInteraction
  extend ActiveSupport::Concern
  include ReplayAccess
  include JsonCsrfRefusal

  RATE_LIMIT_STORE = RegistrationRateLimitStore.new(name: "replay_interaction_rate_limits")

  private

  def set_replay_viewer
    @webinar = Webinar.find_by(slug: params[:slug])
    @replay = @webinar&.replay
    @viewer = @webinar && replay_viewer(@webinar)
    head :not_found unless replay_open_to?(@replay, @viewer)
  end

  def require_published_replay!
    head :not_found unless @replay.published?
  end

  def require_json!
    head :unsupported_media_type unless request.media_type == "application/json"
  end

  def rate_limit_key
    "#{@viewer.class.name.underscore}-#{@viewer.id}"
  end

  def render_rate_limited
    render json: { error: "rate_limited" }, status: :too_many_requests
  end

  def render_escaped_json(payload, status: :ok)
    render json: payload, status: status, escape: true, escape_html_entities: true
  end
end
