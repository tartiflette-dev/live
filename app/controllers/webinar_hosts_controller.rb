class WebinarHostsController < ApplicationController
  # Gestion des co-animateurs invités.
  #
  # • Création / suppression PAR EMAIL par un animateur du projet ou le
  #   propriétaire (`can_manage_hosts?`). Un invité (`guest_host`) ne
  #   peut PAS gérer la liste (« PAS d'accès … à la
  #   gestion des intervenants/co-animateurs ».
  # • Scoping webinaire = `where_managed_by` (owner / project_host) :
  #   un invité qui POSTe reçoit 404 (défense énumération, cohérent
  #   avec SpeakersController).
  # • Email normalisé en downcase par le modèle (unique par webinaire,
  #   case-insensitive).
  include AnimateurBrowserPolicy
  before_action :authenticate_animateur!
  before_action :set_webinar

  def create
    email = params.dig(:webinar_host, :email).to_s
    host = @webinar.webinar_hosts.build(email: email, invited_by_sub: current_user.oidc_sub)
    if host.save
      redirect_to webinar_path(@webinar), notice: "Co-animateur ajouté : #{host.email}.", status: :see_other
    else
      redirect_to webinar_path(@webinar), alert: host.errors.full_messages.to_sentence, status: :see_other
    end
  end

  # Reconduction : reprend les co-animateurs cochés
  # du webinaire précédent du même propriétaire. Seuls les candidats de
  # `Webinar#carryover_hosts` sont repris ; tout autre email envoyé est ignoré.
  def carry_over
    emails = Array.wrap(params[:emails]).grep(String)
    created = @webinar.carry_over_hosts!(emails, invited_by_sub: current_user.oidc_sub)
    if created.any?
      redirect_to webinar_path(@webinar), notice: "Co-animateurs repris : #{created.map(&:email).join(', ')}.",
                                          status: :see_other
    else
      redirect_to webinar_path(@webinar), alert: "Aucun co-animateur sélectionné.", status: :see_other
    end
  end

  def destroy
    # Scope IDOR-safe : `@webinar.webinar_hosts.find` empêche la
    # suppression d'un WebinarHost appartenant à un AUTRE webinaire par
    # son id (défense IDOR). `@webinar` est lui-même
    # scopé `where_managed_by(current_user)` dans set_webinar.
    host = @webinar.webinar_hosts.find(params[:id])
    claimed_sub = host.claimed_sub
    host.destroy!

    # Expulsion LiveKit (défense stale-authorization) : si le
    # co-animateur avait déjà rejoint la salle, son jeton reste valide
    # jusqu'à expiration (TTL 4 h, LivekitTokenService) — on l'éjecte
    # explicitement maintenant. Les requêtes app Rails suivantes
    # répondent 404 d'elles-mêmes (webinar_hosts entry supprimée →
    # `role_for` retourne nil → scope exclut).
    #
    # Expulsion best-effort : un échec (livekit down, participant déjà
    # parti) ne doit PAS bloquer la suppression — le droit est déjà
    # coupé côté app Rails, c'est l'invariant central. On log l'échec
    # pour diagnostic.
    eviction_error = nil
    if claimed_sub.present? && @webinar.live?
      begin
        room_service_client.remove_participant(
          room: @webinar.room_name,
          identity: "host-#{claimed_sub}"
        )
      rescue RoomServiceClient::Error => e
        Rails.logger.warn(
          "[webinar_hosts#destroy] remove_participant failed room=#{@webinar.room_name} identity=host-#{claimed_sub} err=#{e.message}"
        )
        eviction_error = e.message
      end
    end

    if eviction_error
      # L'échec de l'expulsion doit être VISIBLE pour l'animateur.
      # Le droit est coupé côté app Rails
      # (destroy ok), mais l'ancien JWT LiveKit reste valide jusqu'à
      # son TTL (15 min pour cohost, voir LivekitTokenService::
      # COHOST_TTL) et la garde webhook `participant_joined` expulsera
      # à la prochaine reconnexion. On signale pour que l'animateur
      # décide : réessayer, terminer le direct, ou patienter.
      redirect_to webinar_path(@webinar),
                  alert: "Co-animateur retiré, mais l'expulsion LiveKit a échoué (#{eviction_error}). Sa session en cours reste active jusqu'à l'expiration du jeton (max 15 min).",
                  status: :see_other
    else
      redirect_to webinar_path(@webinar), notice: "Co-animateur retiré.", status: :see_other
    end
  end

  private

  def set_webinar
    @webinar = Webinar.where_managed_by(current_user).find_by!(slug: params[:webinar_id])
  end

  # Injection via Rails.configuration.x pour permettre le stub en test
  # (cohérent avec RecordingSession / WebinarStatesController).
  def room_service_client
    Rails.configuration.x.room_service_client_factory.call
  end
end
