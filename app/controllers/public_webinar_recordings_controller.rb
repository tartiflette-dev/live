class PublicWebinarRecordingsController < ApplicationController
  include CurrentRegistration

  # Endpoint read-only pour le spectateur (consentement). Payload minimal :
  #     { recording: { status: "recording|starting|stopping|…" | null },
  #       participant_recording: Boolean }
  # — AUCUN stop_url ni start_url : le spectateur ne pilote jamais
  # l'enregistrement, il doit seulement SAVOIR qu'il est en cours quand
  # il publie (main accordée).
  #
  # Autorisation : cookie d'inscription confirmée (CurrentRegistration).
  # Un visiteur anonyme OU une inscription non confirmée reçoit 403 :
  # on n'expose jamais le statut d'enregistrement d'un webinaire draft
  # à l'anonyme (défense énumération + consentement n'a de sens que
  # pour un publieur potentiel).
  before_action :set_webinar
  before_action :require_registration!

  def status
    identity = "viewer-#{current_registration.id}"
    composite_active = @webinar.recordings.active.composite.exists?
    track_active = @webinar.recordings.active.tracks.where(participant_identity: identity).exists?

    # Pour le payload `recording` on expose la MEILLEURE représentation
    # côté publieur : composite actif prioritaire, sinon piste active
    # de SON identité, sinon null. On ne divulgue PAS la liste des
    # autres pistes (seules les siennes concernent son consentement).
    rec = @webinar.recordings.active.composite.recent_first.first
    rec ||= @webinar.recordings.active.tracks.where(participant_identity: identity).recent_first.first

    response.headers["Cache-Control"] = "no-store"
    render json: {
      recording: rec && { status: rec.status },
      participant_recording: composite_active || track_active
    }
  end

  private

  def set_webinar
    @webinar = Webinar.published.find_by!(slug: params[:slug])
  end

  def require_registration!
    render json: { error: "registration_required" }, status: :forbidden unless current_registration
  end
end
