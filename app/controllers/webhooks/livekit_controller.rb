module Webhooks
  # No cookie/session authority: LiveKit signs both the JWT and raw-body digest.
  class LivekitController < ActionController::API
    def create
      body = request.raw_post
      return head :content_too_large if body.bytesize > 1.megabyte

      event = LivekitWebhookVerifier.new.verify(body: body, authorization: request.headers["Authorization"])
      case event["event"]
      when "track_published"
        enqueue_track(event) if ENV["TRACK_EGRESS_ENABLED"] == "true"
      when "egress_updated"
        EgressActivationJob.perform_later(event.fetch("egress_info", {}))
      when "egress_ended"
        FinalizeEgressJob.perform_later(event.fetch("egress_info", {}))
      when "participant_joined"
        # Défense stale-authorization : un JWT LiveKit
        # émis au co-animateur reste valide jusqu'à son TTL. Si son
        # droit a été retiré entre l'émission et la reconnexion
        # (`WebinarHost` supprimé, Speaker révoqué, inscription
        # supprimée, personne retirée depuis la régie — ParticipantModeration),
        # LiveKit l'accepte toujours et notre app Rails
        # ne le saurait pas. On GARDE au niveau du webhook : à chaque
        # participant qui rejoint, on vérifie son autorisation via la
        # même règle que la décision de rôle (`TrackRecordingSession
        # .authorized?`), et on l'expulse à la volée sinon. Autorisé, son
        # droit de publier est remis d'accord avec son accord à l'image
        # (PublishPermission#reconcile_on_join).
        enforce_participant_authorization(event)
      when "participant_left", "participant_connection_aborted"
        note_departure(event)
      when "room_finished"
        note_room_finished(event)
      end
      head :no_content
    rescue LivekitWebhookVerifier::Unauthorized
      head :unauthorized
    rescue LivekitWebhookVerifier::InvalidPayload
      head :bad_request
    rescue LivekitWebhookVerifier::MissingCredentials
      head :service_unavailable
    end

    private

    def enqueue_track(event)
      # Fenêtre d'enregistrement = direct en cours OU composite actif
      # (dans la borne d'âge RECORDING_WINDOW_MAX_HOURS). Cas réel : le
      # filtre `Webinar.live.find_by` perdait toute
      # piste publiée alors que le composite tournait sans go_live!
      # (cafe-ia-2 : composite OK, zéro piste). La condition centralisée
      # est portée par TrackRecordingSession.recording_window_open?,
      # réutilisée par #start et le rattrapage.
      #
      # Avant de décider, on balaie les composites
      # fantômes (recording depuis > borne) — un livekit-server redémarré
      # peut laisser un composite « recording » éternel, qui ouvrirait
      # la fenêtre sans fin si on ne mesurait pas l'âge.
      webinar = Webinar.find_by(room_name: event.dig("room", "name"))
      return unless webinar

      TrackRecordingSession.sweep_stale_composites(webinar)
      return unless TrackRecordingSession.recording_window_open?(webinar)

      identity = event.dig("participant", "identity")
      track = event.fetch("track", {})
      return unless TrackRecordingSession.recordable?(webinar, identity)
      return unless TrackRecordingSession.valid_track?(track["sid"], track["source"].to_s.downcase)

      StartTrackEgressJob.perform_later(webinar.id, track["sid"], identity, track["source"].downcase)
    end

    # Garde temps-réel.
    # L'autorisation réutilise `TrackRecordingSession.authorized?` : même
    # règle que l'enregistrement des pistes (qui y ajoute l'accord à
    # l'image, `recordable?`) et le webhook transcripts (une seule source
    # de vérité). Un échec distant est best-effort
    # (log sans PII) : le droit n'était pas valide, mieux vaut une
    # tentative loguée qu'une acceptation silencieuse.
    #
    # Classes d'identités JAMAIS expulsées :
    #   • `participant.kind` != STANDARD → EGRESS (enregistrement
    #     composite + pistes individuelles), AGENT (transcripteur
    #     LiveKit Agent / Whisper), INGRESS / SIP / CONNECTOR / BRIDGE.
    #     Les expulser casserait l'enregistrement et le transcript à
    #     chaque direct.
    #
    # Pour toutes les identités STANDARD (`host-<sub>`, `speaker-<id>`,
    # `viewer-<id>`), on applique `authorized?`. L'ancien chemin
    # `speaker-legacy-*` a été SUPPRIMÉ — ces
    # identités, si elles reparaissent, sont désormais traitées comme
    # inconnues et expulsées (fail-closed).
    def enforce_participant_authorization(event)
      room_name = event.dig("room", "name")
      participant = event.fetch("participant", {})
      identity = participant["identity"]
      return if room_name.blank? || identity.blank?

      kind = participant_kind(participant)
      return unless kind.empty? || kind == "STANDARD"

      webinar = Webinar.find_by(room_name: room_name)
      return if webinar.nil?

      if TrackRecordingSession.authorized?(webinar, identity)
        # Quelqu'un est revenu : la fin automatique programmée n'a plus lieu
        # (AutoEndLiveJob). Un participant expulsé ci-dessous ne compte pas.
        webinar.mark_room_occupied!
        reconcile_publish_permission(webinar, identity, participant)
        note_arrival(webinar, identity, event)
        # Si cette arrivée a (re)créé la salle, le transcripteur y est
        # renvoyé ; sinon la vérification ne fait rien.
        TranscriberPresenceJob.perform_later(webinar.id) unless webinar.ended?
        return
      end

      # Pas de PII dans le log — identity est opaque (host-<sub>,
      # speaker-<id>, viewer-<id>), room_name = slug (public).
      Rails.logger.warn(
        "[webhooks/livekit] stale participant rejected room=#{room_name} identity=#{identity}"
      )
      begin
        room_service_client.remove_participant(room: room_name, identity: identity)
      rescue RoomServiceClient::Error => e
        Rails.logger.warn(
          "[webhooks/livekit] remove_participant failed room=#{room_name} identity=#{identity} err=#{e.message}"
        )
      end
      # Au journal APRÈS l'expulsion : une écriture lente ne retarde pas la garde.
      note_presence(webinar, event, "refused")
    end

    # Jeton émis avant un retrait d'accord (ou avant la garde) : publication
    # fermée ; accord donné avant l'arrivée : publication ouverte. Le JSON
    # proto omet `can_publish` quand il vaut false. Si LiveKit ne répond pas,
    # une fermeture manquée est confiée à PublishingRevocationJob (essais
    # bornés, puis alerte) ; une ouverture manquée laisse seulement la
    # personne sans publier.
    def reconcile_publish_permission(webinar, identity, participant)
      publishing = participant.dig("permission", "can_publish") == true
      HandRaiseControl.new(webinar, client: room_service_client).reconcile_publication(identity, publishing: publishing)
    rescue RoomServiceClient::Error => e
      Rails.logger.warn("[webhooks/livekit] publish permission not reconciled room=#{webinar.room_name} identity=#{identity} err=#{e.class}")
      holder = PublishPermission.new(webinar).record_for(identity)
      PublishingRevocationJob.perform_later(webinar, holder) if publishing && holder
    end

    # Arrivée au journal de présence (PresenceEvent) et première arrivée d'un
    # inscrit (RoomAttendance), APRÈS la garde et la réconciliation : une
    # écriture de confort ne doit jamais empêcher la fermeture d'une
    # publication. La lecture de la salle par la régie rattrape une première
    # arrivée non notée.
    def note_arrival(webinar, identity, event)
      note_presence(webinar, event, "joined")
      RoomAttendance.note_arrival(webinar, identity, at: PresenceEvent.webhook_time(event))
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[webhooks/livekit] arrival not noted room=#{webinar.room_name} identity=#{identity} err=#{e.class}")
    end

    # Départ, ou connexion interrompue avant d'aboutir, d'une personne
    # (jamais l'enregistreur ni le transcripteur). Aucune garde ici : qui
    # part ne reçoit rien.
    def note_departure(event)
      kind = participant_kind(event.fetch("participant", {}))
      return unless kind.empty? || kind == "STANDARD"

      webinar = Webinar.find_by(room_name: event.dig("room", "name").to_s)
      note_presence(webinar, event, event["event"] == "participant_left" ? "left" : "aborted")
    end

    # Journal de présence : best-effort, jamais une erreur rendue à LiveKit
    # (qui rejouerait le webhook) ni un obstacle à la garde.
    def note_presence(webinar, event, kind)
      return if webinar.nil?

      identity = event.dig("participant", "identity")
      return unless kind == "room_finished" || PresenceEvent.human_identity?(identity)

      PresenceEvent.record_room!(webinar, kind, identity, at: PresenceEvent.webhook_time(event), livekit_event_id: event["id"])
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[webhooks/livekit] presence not noted room=#{webinar.room_name} kind=#{kind} err=#{e.class}")
    end

    # participant.kind émis en JSON proto (preserve_proto_fieldnames) :
    # valeur par défaut STANDARD omise → nil ou "STANDARD" entrant.
    def participant_kind(participant)
      participant["kind"].to_s
    end

    # Fin automatique : LiveKit ferme la salle d'un
    # direct en cours quand le dernier participant humain l'a quittée. La
    # vacance est relevée et la fin programmée ; AutoEndLiveJob revérifie
    # tout au moment d'agir. Direct en cours ou non, la fermeture va au
    # journal de présence : plus personne n'est dans la salle.
    def note_room_finished(event)
      webinar = Webinar.find_by(room_name: event.dig("room", "name").to_s)
      note_presence(webinar, event, "room_finished")
      return unless webinar&.live?

      webinar.mark_room_empty!
      AutoEndLiveJob.schedule(webinar)
    end

    def room_service_client
      Rails.configuration.x.room_service_client_factory.call
    end
  end
end
