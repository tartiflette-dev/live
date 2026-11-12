# Sondages du direct dans le lecteur de replay (app/javascript/replay_polls.js) :
#
#   GET  /w/:slug/replay/sondages                 → { polls: [ReplayPoll…] }
#   POST /w/:slug/replay/sondages/:id/reponses    { value } → 201 le sondage,
#        avec la réponse et le résultat direct + replay ;
#        409 `answered_live` (déjà répondu au direct) ;
#        422 réponse hors format ; 404 sans accès, replay non publié,
#        sondage absent de la vidéo ou personne effacée pendant l'envoi ;
#        429 débit dépassé.
#
# Une réponse par personne et par sondage, remplacée tant qu'elle vient du
# replay, jamais à la place d'une réponse du direct (Poll#respond_from_replay!).
class ReplayPollsController < ApplicationController
  include ReplayInteraction

  before_action :require_json!, only: :respond
  before_action :set_replay_viewer
  before_action :require_published_replay!, only: :respond

  rate_limit to: 30, within: 1.minute, name: "replay-polls-read", only: :index,
    by: :rate_limit_key, store: RATE_LIMIT_STORE, with: :render_rate_limited
  rate_limit to: 10, within: 1.minute, name: "replay-polls-answer", only: :respond,
    by: :rate_limit_key, store: RATE_LIMIT_STORE, with: :render_rate_limited

  rescue_from Poll::Refused do |refusal|
    render json: { error: refusal.code }, status: refusal.code == :viewer_gone ? :not_found : :conflict
  end

  rescue_from ActiveRecord::RecordInvalid do
    render json: { error: "invalid_response" }, status: :unprocessable_entity
  end

  def index
    render_escaped_json({ polls: ReplayPoll.for(@replay).map { |replay_poll| replay_poll.attributes_for(@viewer) } })
  end

  def respond
    replay_poll = ReplayPoll.for(@replay).find { |candidate| candidate.poll.id.to_s == params[:id].to_s }
    return head(:not_found) unless replay_poll

    replay_poll.poll.respond_from_replay!(viewer: @viewer, value: params[:value])
    render_escaped_json(replay_poll.attributes_for(@viewer), status: :created)
  end
end
