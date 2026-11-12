# Sondages du direct, côté animation (régie).
#
#   GET    /webinars/:webinar_id/polls               plan + état du direct
#   POST   /webinars/:webinar_id/polls               ajouter au plan (`open: true` = lancer aussitôt)
#   GET    /webinars/:webinar_id/polls/:id           détail nominatif
#   PATCH  /webinars/:webinar_id/polls/:id           modifier (jamais lancé)
#   DELETE /webinars/:webinar_id/polls/:id           supprimer (jamais lancé)
#   PATCH  /webinars/:webinar_id/polls/reorder       { ids: [...] } nouvel ordre du plan
#   POST   /webinars/:webinar_id/polls/:id/open | close | show_results | hide_results
#
# Réservé à l'animation (owner, project_host, guest_host) : même scope
# `where_animated_by` que la modération de la discussion ; sans rôle, 404
# (défense énumération). Chaque changement de ce qui est à l'écran des
# participants est diffusé (PollBroadcast) ; un double clic ne rediffuse
# rien. Les textes saisis sortent en JSON échappé, comme la discussion.
class PollsController < ApplicationController
  include JsonCsrfRefusal

  SCALE_KEYS = %i[min max min_label max_label].freeze

  before_action :authenticate_animateur!
  before_action :set_webinar
  before_action :set_poll, only: [ :show, :update, :destroy, :open, :close, :show_results, :hide_results ]

  rescue_from Poll::Refused do |refusal|
    render json: { error: refusal.code }, status: :conflict
  end

  rescue_from ActiveRecord::RecordInvalid do |invalid|
    render json: { error: "invalid_poll", details: invalid.record.errors.full_messages }, status: :unprocessable_entity
  end

  def index
    render_json({
      now: Time.current.utc.iso8601,
      webinar: { state: @webinar.state, started_at: @webinar.started_at&.utc&.iso8601 },
      polls: @webinar.polls.map(&:host_attributes)
    })
  end

  def show
    render_json({ poll: @poll.host_attributes(respondents: true) })
  end

  # `open: true` (« Lancer maintenant ») : création et ouverture dans la même
  # transaction — un refus d'ouverture n'en laisse aucun sondage créé.
  def create
    launch = ActiveModel::Type::Boolean.new.cast(params[:open])
    poll = @webinar.with_lock do
      created = @webinar.polls.create!(poll_params.merge(position: @webinar.polls.maximum(:position).to_i + 1))
      created.open! if launch
      created
    end
    broadcast = launch ? PollBroadcast.new.deliver(@webinar) : nil
    render_json({ poll: poll.host_attributes, broadcast: broadcast }.compact, status: :created)
  end

  def update
    @poll.edit!(poll_params)
    render_json({ poll: @poll.host_attributes })
  end

  def destroy
    @poll.remove!
    head :no_content
  end

  def reorder
    ids = Array(params[:ids]).map(&:to_s)
    reordered = @webinar.with_lock do
      polls = @webinar.polls.to_a
      next false unless ids.sort == polls.map { |poll| poll.id.to_s }.sort

      polls.each { |poll| poll.update_columns(position: ids.index(poll.id.to_s) + 1, updated_at: Time.current) }
    end
    return render_json({ error: "invalid_order" }, status: :unprocessable_entity) unless reordered

    render_json({ polls: @webinar.polls.reload.map(&:host_attributes) })
  end

  def open
    render_transition(:open!)
  end

  def close
    render_transition(:close!)
  end

  def show_results
    render_transition(:show_results!)
  end

  def hide_results
    render_transition(:hide_results!)
  end

  private

  def set_webinar
    @webinar = Webinar.where_animated_by(current_user).find_by!(slug: params[:webinar_id])
  end

  def set_poll
    @poll = @webinar.polls.find(params[:id])
  end

  # Contenu seulement : position et cycle ne se posent jamais par ce biais.
  # `options` : liste de libellés (choix) ou { min, max, min_label, max_label }
  # (échelle).
  def poll_params
    raw = params.require(:poll)
    permitted = raw.permit(:kind, :multiple, :label, :planned_minute, :note)
    return permitted unless raw.key?(:options)

    options = raw[:options]
    options = options.is_a?(ActionController::Parameters) ? options.permit(*SCALE_KEYS).to_h : raw.permit(options: [])[:options]
    permitted.merge(options: options)
  end

  # Idempotent : une transition sans effet (déjà fermé, déjà montré) n'est
  # pas rediffusée.
  def transition(poll, event)
    poll.public_send(event) ? PollBroadcast.new.deliver(@webinar) : :unchanged
  end

  def render_transition(event)
    broadcast = transition(@poll, event)
    render_json({ poll: @poll.host_attributes(respondents: true), broadcast: broadcast })
  end

  def render_json(payload, status: :ok)
    render json: payload, status: status, escape: true, escape_html_entities: true
  end
end
