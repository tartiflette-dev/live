# Question affichée à l'écran, côté salle.
#
#   GET /w/:slug/qa/current  → { displayed: { id, label, displayed_at } | null }
#
# Même forme que le paquet temps réel QaBroadcast (repli par polling du
# bandeau, rooms/qa_banner.jsx). Lisible par tout participant de la salle —
# animateur, intervenant nominatif (X-Speaker-Token, jamais dans l'URL),
# inscription confirmée — décidé serveur par RoomParticipant, comme le jeton
# LiveKit. Le libellé seul : jamais les auteurs de la question.
class QaDisplaysController < ApplicationController
  include RoomParticipant

  def show
    webinar = Webinar.find_by!(slug: params[:slug])
    return render json: { error: "participant_required" }, status: :forbidden unless resolve_role(webinar: webinar, speaker_token: request.headers["X-Speaker-Token"])

    render json: QaBroadcast.envelope(webinar).except(:topic), escape: true, escape_html_entities: true
  end
end
