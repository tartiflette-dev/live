# Régie du direct : « même quelqu'un qui est animateur doit voir la même chose que
# les participants […] on a un autre onglet » pour piloter le direct.
#
#   GET /webinars/:webinar_id/regie         → page (chrome undust, sans vidéo)
#   GET /webinars/:webinar_id/regie/status  → JSON : état du direct (début,
#     fin pour le bilan) + salle, et l'empreinte du lien participants privé
#     actif (`share_link_fingerprint`, null sans lien) : jamais le jeton dans
#     un GET ; le début d'une transcription interrompue
#     (`transcription_interrupted_since`, null sinon, Webinar::TranscriptionOutage) ;
#     et l'état des caméras (`camera_health`, CameraSample : émises sous 720p,
#     replis sans simulcast).
#
# Même périmètre que la scène (WebinarsController#stage) : animation du
# webinaire (owner, project_host, guest_host), scope `where_animated_by`.
# Sans rôle : 404 (défense énumération) ; anonyme : renvoyé à la connexion.
#
# La page ne rejoint JAMAIS la salle LiveKit : aucune connexion média,
# rien de publié. Chaque commande passe par les endpoints existants
# (cycle live, enregistrements, mains levées, mise en avant, discussion,
# modération, régénération du lien participants privé), qui revérifient le
# rôle à chaque appel.
class WebinarRegiesController < ApplicationController
  include AnimateurBrowserPolicy

  before_action :authenticate_animateur!
  before_action :set_webinar

  def show
    @stage_url = stage_webinar_path(slug: @webinar.slug)
    # Liste des inscrits (PII) : seulement à qui voit déjà /registrations
    # (WebinarRegistrationsController, `where_managed_by`). Le co-animateur
    # invité n'en reçoit pas l'URL ; l'endpoint lui répond 404 de toute façon.
    @registrations_visible = Webinar.where_managed_by(current_user).exists?(id: @webinar.id)
  end

  def status
    response.headers["Cache-Control"] = "no-store"
    render json: {
      state: @webinar.state,
      starts_at: @webinar.starts_at&.iso8601,
      live_since: @webinar.started_at&.iso8601,
      ended_at: @webinar.ended_at&.iso8601,
      share_link_fingerprint: @webinar.share_token_fingerprint,
      transcription_interrupted_since: @webinar.transcription_interrupted_since&.iso8601,
      camera_health: CameraSample.health_for(@webinar)
    }.merge(RoomSnapshot.new(@webinar).call)
  end

  private

  def set_webinar
    @webinar = Webinar.where_animated_by(current_user).find_by!(slug: params[:webinar_id])
  end
end
