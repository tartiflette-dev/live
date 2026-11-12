# Modération du direct depuis la régie : jusqu'ici, la seule arme contre un intrus était « Terminer ».
#
#   POST /webinars/:webinar_id/participants/:identity/mute    → { muted_tracks: n }
#   POST /webinars/:webinar_id/participants/:identity/remove  → { removed: true, share_link_reentry: bool }
#
# `share_link_reentry` : la personne retirée, entrée par le lien participants
# privé encore actif, pourrait revenir par lui ; la régie propose de le
# régénérer (WebinarShareLinkRegenerationsController).
#
# Toute l'animation du webinaire (owner, project_host, co-animateur invité),
# scope `where_animated_by` comme la régie et la mise en avant : un retrait
# ne peut pas attendre qu'un propriétaire soit là. Le co-animateur invité ne
# gère ni intervenants ni inscrits (Webinar#can_manage_speakers?,
# #can_manage_registrations?) : il ne modère que pendant le direct (sinon 403
# `not_live`) une personne présente dans la salle (sinon 422 `not_in_room`),
# sans rien écrire quand il est refusé. Owner et project_host
# retirent durablement, présente ou non, à tout moment. Sans rôle : 404 (défense
# énumération) ; anonyme, intervenant (lien `t`) ou spectateur (cookie
# d'inscription), sans session animateur : renvoyés à la connexion.
#
# Cibles : `speaker-<id>` et `viewer-<id>` de CE webinaire (ParticipantModeration) ;
# une identité d'animation (`host-*`) ou d'une autre forme → 422, une
# personne inconnue du webinaire → 404, LiveKit en échec → 502.
class WebinarParticipantsController < ApplicationController
  include JsonCsrfRefusal

  before_action :authenticate_animateur!
  before_action :set_webinar
  before_action :require_live_for_guest

  rescue_from ParticipantModeration::InvalidIdentity do
    render json: { error: "invalid_identity" }, status: :unprocessable_entity
  end

  rescue_from ParticipantModeration::NotInRoom do
    render json: { error: "not_in_room" }, status: :unprocessable_entity
  end

  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "not_found" }, status: :not_found
  end

  rescue_from RoomServiceClient::Error do |error|
    Rails.logger.warn("[webinar_participants] webinar=#{@webinar.id} #{action_name} #{error.class}: #{error.message}")
    render json: { error: "room_update_failed" }, status: :bad_gateway
  end

  def mute
    render json: { muted_tracks: moderation.mute_audio }
  end

  def remove
    moderation.remove
    render json: { removed: true, share_link_reentry: moderation.share_link_reentry? }
  end

  private

  def set_webinar
    @webinar = Webinar.where_animated_by(current_user).find_by!(slug: params[:webinar_id])
  end

  # Le co-animateur invité modère pendant le direct seulement.
  def require_live_for_guest
    render json: { error: "not_live" }, status: :forbidden unless manages_people? || @webinar.live?
  end

  def moderation
    @moderation ||= ParticipantModeration.new(@webinar, params[:identity], present_only: !manages_people?)
  end

  # Gestion durable des intervenants ET des inscrits : owner, project_host.
  def manages_people?
    return @manages_people if defined?(@manages_people)

    @manages_people = @webinar.can_manage_speakers?(current_user) && @webinar.can_manage_registrations?(current_user)
  end
end
