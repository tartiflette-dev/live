# Discussion du direct, côté animation (panneau « Questions »).
#
#   POST /webinars/:webinar_id/messages/:id/answer   question → répondue
#   POST /webinars/:webinar_id/messages/:id/pin      épinglée en tête chez tous
#   POST /webinars/:webinar_id/messages/:id/unpin
#
# Réservé à l'animation (owner, project_host, guest_host) : même scope
# `where_animated_by` que les mains levées et la mise en avant ; sans rôle,
# 404 (défense énumération). Le changement est diffusé comme un message
# (MessageBroadcast) ; les clients le rattrapent aussi par le curseur
# (updated_at, id). Après la fin du direct, le fil est figé (410).
class MessageModerationsController < ApplicationController
  include JsonCsrfRefusal

  before_action :authenticate_animateur!
  before_action :set_webinar
  before_action :refuse_after_end

  def answer
    update_flag(@webinar.messages.question.find(params[:id]), :answered_at, Time.current)
  end

  def pin
    update_flag(@webinar.messages.find(params[:id]), :pinned_at, Time.current)
  end

  def unpin
    update_flag(@webinar.messages.find(params[:id]), :pinned_at, nil)
  end

  private

  def set_webinar
    @webinar = Webinar.where_animated_by(current_user).find_by!(slug: params[:webinar_id])
  end

  def refuse_after_end
    render json: { error: "webinar_ended" }, status: :gone if @webinar.ended?
  end

  # Idempotent : un drapeau déjà dans l'état demandé garde son horodatage
  # d'origine et n'est pas rediffusé (double clic, deux animateurs).
  def update_flag(message, attribute, value)
    changed = message.with_lock do
      next false if message[attribute].present? == value.present?

      message.update!(attribute => value)
    end
    broadcast = changed ? MessageBroadcast.new.deliver(message) : :unchanged
    render json: message.public_attributes.merge(broadcast: broadcast), escape: true, escape_html_entities: true
  end
end
