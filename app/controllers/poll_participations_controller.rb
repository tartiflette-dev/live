# Sondages du direct, côté participants.
#
#   GET  /w/:slug/polls/current             → { at, poll, my_response }
#   POST /w/:slug/polls/:id/responses       { value } → { at, poll, my_response }
#
# Mêmes participants que la discussion (RoomAuthor : animation, intervenant
# nominatif, inscription confirmée), décidés serveur à chaque appel ;
# l'animation voit et répond comme tout le monde. `poll` = le sondage à
# l'écran (ouvert, ou dont le résultat est montré), `my_response` = la
# valeur déjà donnée par CE participant au direct (une réponse donnée
# depuis le replay n'y compte pas : elle n'est pas montrée comme telle).
# Une réponse est remplacée tant que le sondage est ouvert ; le compteur est rediffusé, regroupé à la seconde
# (PollBroadcast.schedule_tally). Réponses texte en JSON échappé.
class PollParticipationsController < ApplicationController
  include RoomAuthor
  include JsonCsrfRefusal

  # Compteurs fichier partagés par les workers Puma, dans un répertoire et
  # sous un verrou propres aux sondages (pas ceux des inscriptions).
  RATE_LIMIT_STORE = RegistrationRateLimitStore.new(name: "poll_rate_limits")

  before_action :set_webinar
  before_action :require_json!, only: :respond
  before_action :set_author

  # Anti-rafale par participant, après la décision du rôle (clé = son jeton).
  # Lecture : un onglet relit toutes les 5 à 30 s ; 30 en 30 s laisse la
  # place à plusieurs onglets.
  rate_limit to: 30, within: 30.seconds, name: "poll-current", only: :current,
    by: :rate_limit_key, store: RATE_LIMIT_STORE, with: :render_rate_limited
  rate_limit to: 10, within: 10.seconds, name: "poll-burst", only: :respond,
    by: :rate_limit_key, store: RATE_LIMIT_STORE, with: :render_rate_limited

  rescue_from Poll::Refused do |refusal|
    render json: { error: refusal.code }, status: :conflict
  end

  rescue_from ActiveRecord::RecordInvalid do
    render json: { error: "invalid_response" }, status: :unprocessable_entity
  end

  def current
    render_snapshot
  end

  def respond
    poll = @webinar.polls.find(params[:id])
    poll.respond!(identity: @author.identity, name: @author.name, registration: @author.registration,
                  value: params[:value])
    PollBroadcast.schedule_tally(@webinar)
    render_snapshot(status: :created)
  end

  private

  def set_webinar
    @webinar = Webinar.find_by!(slug: params[:slug])
  end

  def require_json!
    head :unsupported_media_type unless request.media_type == "application/json"
  end

  def render_rate_limited
    render json: { error: "rate_limited" }, status: :too_many_requests
  end

  def render_snapshot(status: :ok)
    snapshot = PollBroadcast.snapshot(@webinar)
    poll_id = snapshot.dig(:poll, :id)
    my_response = poll_id && PollResponse.live.where(poll_id: poll_id, respondent_identity: @author.identity).pick(:value)
    render json: snapshot.merge(my_response: my_response), status: status, escape: true, escape_html_entities: true
  end
end
