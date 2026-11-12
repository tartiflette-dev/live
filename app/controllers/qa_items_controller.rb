# File Q&R du direct, côté animation, console de
# régie (rooms/qa_console.jsx).
#
#   GET   /webinars/:webinar_id/qa_items               file (ouvertes d'abord), auteurs, messages d'origine,
#                                                      état réel de l'analyse (dernier appel au LLM)
#   POST  /webinars/:webinar_id/qa_items  { message_id[, label] }   ajout manuel depuis un message
#   PATCH /webinars/:webinar_id/qa_items/:id  { label }             reformulation corrigée
#   POST  /webinars/:webinar_id/qa_items/:id/answer|dismiss|reopen
#   POST  /webinars/:webinar_id/qa_items/:id/display|hide            bandeau « question en cours »
#
# Réservé à l'animation (owner, project_host, guest_host) : même scope
# `where_animated_by` que la modération du chat ; sans rôle, 404 (défense
# énumération). Tout changement est signalé à la salle (QaBroadcast). La file
# reste traitable après la fin du direct (récapitulatif) ; seul l'affichage à
# l'écran est refusé (410). Le texte sort en JSON échappé, comme le chat.
class QaItemsController < ApplicationController
  include JsonCsrfRefusal

  ITEMS_LIMIT = 300

  before_action :authenticate_animateur!
  before_action :set_webinar
  before_action :set_item, except: %i[index create]

  rescue_from ActiveRecord::RecordInvalid do
    render json: { error: "invalid_qa_item" }, status: :unprocessable_entity
  end

  rescue_from QaItem::NotDisplayable do
    render json: { error: "not_displayable" }, status: :unprocessable_entity
  end

  def index
    items = @webinar.qa_items.queue_order.includes(:messages, :registration, :user).limit(ITEMS_LIMIT)
    render json: { items: items.map(&:console_attributes), analysis: analysis }, escape: true, escape_html_entities: true
  end

  def create
    message = @webinar.messages.find(params.require(:message_id))
    item = QaItem.enqueue!(message: message, label: params[:label].presence || message.body, source: "manual")
    return render json: { error: "message_erased" }, status: :unprocessable_entity unless item

    created = item.enqueued == :created
    respond(item, changed: created, status: created ? :created : :ok)
  end

  def update
    respond(@item, changed: @item.relabel!(params.require(:label).to_s))
  end

  def answer
    respond(@item, changed: @item.answer!)
  end

  def dismiss
    respond(@item, changed: @item.dismiss!)
  end

  def reopen
    respond(@item, changed: @item.reopen!)
  end

  def display
    return render json: { error: "webinar_ended" }, status: :gone if @webinar.ended?

    respond(@item, changed: @item.display!)
  end

  def hide
    respond(@item, changed: @item.hide!)
  end

  private

  def set_webinar
    @webinar = Webinar.where_animated_by(current_user).find_by!(slug: params[:webinar_id])
  end

  def set_item
    @item = @webinar.qa_items.find(params[:id])
  end

  # Drapeau de configuration ET issue du dernier appel au LLM pour ce
  # webinaire (QaExtractionJob) : une panne se voit dans la régie.
  def analysis
    {
      enabled: Rails.configuration.x.qa_llm_client_factory.call.present?,
      outcome: @webinar.qa_llm_outcome,
      at: @webinar.qa_llm_at&.utc&.iso8601(6),
      duration_ms: @webinar.qa_llm_duration_ms
    }
  end

  def respond(item, changed:, status: :ok)
    broadcast = changed ? QaBroadcast.new.deliver(@webinar) : :unchanged
    render json: item.reload.console_attributes.merge(broadcast: broadcast), status: status,
      escape: true, escape_html_entities: true
  end
end
