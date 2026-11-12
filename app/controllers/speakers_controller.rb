class SpeakersController < ApplicationController
  include AnimateurBrowserPolicy
  before_action :authenticate_animateur!
  before_action :set_webinar

  def create
    speaker = @webinar.speakers.build(params.require(:speaker).permit(:name, :email))
    if speaker.save
      redirect_to webinar_path(@webinar), notice: "Intervenant ajouté.", status: :see_other
    else
      redirect_to webinar_path(@webinar), alert: speaker.errors.full_messages.to_sentence, status: :see_other
    end
  end

  # Adresse de l'intervenant (mail de publication de l'épisode). Seul
  # champ modifiable : le nom et le lien restent ceux de l'invitation.
  def update
    speaker = @webinar.speakers.find(params[:id])
    if speaker.update(params.require(:speaker).permit(:email))
      redirect_to webinar_path(@webinar), notice: "Adresse de l'intervenant enregistrée.", status: :see_other
    else
      redirect_to webinar_path(@webinar), alert: speaker.errors.full_messages.to_sentence, status: :see_other
    end
  end

  def revoke
    @webinar.speakers.find(params[:id]).revoke!
    redirect_to webinar_path(@webinar), notice: "Lien intervenant révoqué.", status: :see_other
  end

  # Nouveau lien, nouvelle identité LiveKit. L'ancien jeton ne résout plus
  # (Speaker#replace! pose revoked_at) : la garde webhook et /api/token
  # refusent `speaker-<ancien id>` par le scope `speakers.active`, sans
  # empreinte dans le JWT. L'expulsion de la salle est au mieux.
  def regenerate
    speaker = @webinar.speakers.find(params[:id])
    successor = speaker.replace!
    unless successor
      redirect_to webinar_path(@webinar), alert: "Cet intervenant est déjà révoqué.", status: :see_other
      return
    end

    if (eviction_error = evict_replaced_speaker(speaker))
      redirect_to webinar_path(@webinar),
                  alert: "Lien régénéré, mais l'expulsion LiveKit a échoué (#{eviction_error}). L'ancienne session peut rester active jusqu'à l'expiration du jeton (max #{LivekitTokenService::DEFAULT_TTL / 3600} h).",
                  status: :see_other
    else
      redirect_to webinar_path(@webinar), notice: "Lien intervenant régénéré. L'ancien ne fonctionne plus.", status: :see_other
    end
  end

  private

  # La gestion des intervenants reste réservée aux
  # animateurs du projet et au propriétaire (`where_managed_by`). Un
  # invité connecté qui POSTe sur /webinars/<slug>/speakers reçoit 404.
  def set_webinar
    @webinar = Webinar.where_managed_by(current_user).find_by!(slug: params[:webinar_id])
  end

  # Même contrat que WebinarHostsController#destroy : seulement pendant
  # le direct, échec visible, jamais bloquant. Absent de la salle
  # (`not_found`) = déjà parti, pas une erreur.
  def evict_replaced_speaker(speaker)
    return unless @webinar.live?

    room_service_client.remove_participant(
      room: @webinar.room_name,
      identity: "speaker-#{speaker.id}"
    )
    nil
  rescue RoomServiceClient::RemoteError => e
    return nil if e.code == "not_found"

    log_eviction_failure(speaker, e)
  rescue RoomServiceClient::Error => e
    log_eviction_failure(speaker, e)
  end

  def log_eviction_failure(speaker, error)
    Rails.logger.warn(
      "[speakers#regenerate] remove_participant failed room=#{@webinar.room_name} identity=speaker-#{speaker.id} err=#{error.message}"
    )
    error.message
  end

  def room_service_client
    Rails.configuration.x.room_service_client_factory.call
  end
end
