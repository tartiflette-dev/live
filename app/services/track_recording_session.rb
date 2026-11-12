# Durable per-track claim; database locks never span remote calls.
class TrackRecordingSession
  SOURCES = %w[camera microphone screen_share screen_share_audio].freeze
  DEFAULT_WINDOW_MAX_HOURS = 4

  # Fenêtre pendant laquelle les pistes individuelles doivent être
  # enregistrées. Cas réel :
  # la condition `webinar.live?` seule rate deux parcours réels :
  #   • un animateur/intervenant publie EN COULISSES avant « Passer en
  #     direct » — track_published arrive, enqueue_track jette, les pistes
  #     postérieures au go_live! ne sont jamais rattrapées ;
  #   • l'animateur lance l'enregistrement composite SANS passer en
  #     direct (observé : webinaire en draft, composite OK, 0
  #     piste individuelle).
  #
  # Règle : les pistes s'enregistrent dès qu'un enregistrement composite
  # tourne (RecordingSession active) OU que le direct est en cours.
  #
  # Borne d'âge (REQUEST_CHANGES) :
  # un composite n'OUVRE la fenêtre que s'il a démarré il y a moins de
  # RECORDING_WINDOW_MAX_HOURS. Au-delà, c'est un fantôme (livekit-server
  # relancé, webhook egress_ended perdu) —
  # le `live?` reste une ouverture indépendante de l'âge. Lu à CHAQUE
  # appel pour éviter un redéploiement sur changement de valeur.
  def self.recording_window_open?(webinar)
    return false unless webinar
    return true if webinar.live?

    recent_active_composites(webinar).exists?
  end

  # Un composite au-delà de la borne (recording|starting|stopping depuis
  # > RECORDING_WINDOW_MAX_HOURS) est fantôme — on ne peut plus confirmer
  # son état côté LiveKit (gc egress, redémarrage livekit-server). On le
  # transitionne en :failed avec un message explicite et on cascade pour
  # fermer les pistes qui en dépendaient.
  #
  # Idempotent : un composite déjà failed/done est ignoré. Appelée par
  # le webhook track_published, par le rattrapage et par EgressCompletion
  # (webhook egress_ended: nouveau fil).
  #
  # **Jamais sweep en live**. Un direct légitime
  # de plus de 4 h ne doit JAMAIS voir son composite marqué failed —
  # sinon `ensure_active` relance un second egress en parallèle (deux
  # Recording actifs côté DB, mais surtout deux egress composites côté
  # LiveKit → deux fichiers mp4 avec le même contenu). La borne joue sur
  # le composite SANS garde-fou live? ; le sweep l'applique seulement
  # hors live.
  def self.sweep_stale_composites(webinar, client: RecordingSession.default_client)
    return 0 unless webinar
    return 0 if webinar.live?

    cutoff = Time.current - window_max_hours.hours
    stale = webinar.recordings.active.composite.where("started_at IS NOT NULL AND started_at <= ?", cutoff)
    count = 0
    stale.each do |composite|
      count += 1
      # Stop remote best-effort. On ne sait
      # pas si l'egress tourne encore (webhook perdu, livekit-server
      # redémarré), mais tenter l'arrêt coûte peu et peut libérer un
      # process pendouillant côté serveur. Erreur loggée sans PII.
      if composite.egress_id.present?
        begin
          client.stop(egress_id: composite.egress_id)
        rescue EgressClient::Error => error
          Rails.logger.warn(
            "[track_recording_session] sweep stop best-effort egress=#{composite.egress_id} err=#{error.class}: #{error.message}"
          )
        end
      end
      composite.update!(
        status: :failed,
        error_message: "dépassement de durée max, statut non confirmé (> #{window_max_hours} h)",
        ended_at: composite.ended_at || Time.current
      )
    end
    RecordingSession.cascade_stop_tracks_if_window_closed(webinar, client: client) if count.positive?
    count
  end

  def self.recent_active_composites(webinar)
    cutoff = Time.current - window_max_hours.hours
    webinar.recordings.active.composite.where("started_at IS NOT NULL AND started_at > ?", cutoff)
  end

  def self.window_max_hours
    raw = ENV["RECORDING_WINDOW_MAX_HOURS"].to_s
    parsed = Integer(raw, 10) rescue nil
    (parsed && parsed.positive?) ? parsed : DEFAULT_WINDOW_MAX_HOURS
  end

  def self.authorized?(webinar, identity)
    return false unless identity.is_a?(String)

    # L'identité `host-<sub>` est acceptée pour TOUT
    # animateur (propriétaire, animateur du projet, co-animateur invité).
    # Le propriétaire est fast-path (jamais besoin de toucher à `users`).
    if (match = /\Ahost-(.+)\z/.match(identity))
      sub = match[1]
      return true if sub == webinar.host_sub

      user = User.find_by(oidc_sub: sub)
      return webinar.animated_by?(user)
    end

    if (match = /\Aspeaker-([1-9]\d*)\z/.match(identity))
      return webinar.speakers.active.exists?(id: match[1])
    end

    # Spectateur en prise de parole : LiveKit ne publie sa piste que si
    # l'animateur lui a ouvert la publication (main levée) ; on enregistre
    # alors une inscription À CE webinaire qui a accès à la salle (confirmée,
    # ou PROVISOIRE par l'accès immédiat), jamais un inconnu ni une personne
    # retirée de la salle. Les pistes restent sur l'identité LiveKit
    # `viewer-<id>` : une identité provisoire n'est jamais promue en
    # inscription confirmée d'un autre navigateur (Registration#hand_over!),
    # et le manifeste la marque « non vérifié » (EpisodeManifest).
    match = /\Aviewer-([1-9]\d*)\z/.match(identity)
    match && webinar.registrations.with_room_access.exists?(id: match[1])
  end

  # Piste à enregistrer : identité autorisée dans la salle ET, hors
  # animation de droit, accord à l'image en cours (ParticipantConsent ;
  # co-animateur invité compris). Pas dans `authorized?` : la garde webhook
  # participant_joined s'en sert pour EXPULSER, et une personne sans accord
  # reste dans la salle en spectatrice.
  def self.recordable?(webinar, identity)
    authorized?(webinar, identity) && ParticipantConsent.covers?(webinar, identity)
  end

  def self.valid_track?(sid, source)
    sid.is_a?(String) && sid.match?(/\ATR_[A-Za-z0-9_-]{1,128}\z/) && SOURCES.include?(source)
  end

  def self.start(webinar:, track_sid:, identity:, source:, client: RecordingSession.default_client)
    return unless valid_track?(track_sid, source) && recording_window_open?(webinar.reload) && recordable?(webinar, identity)

    recording = webinar.recordings.new(kind: :track, status: :starting, track_sid: track_sid,
      participant_identity: identity, track_source: source, started_at: Time.current)
    recording.output_prefix = recording.filename_for(kind: :track, identity: identity, source: source)
    begin
      recording.save!
    rescue ActiveRecord::RecordNotUnique
      # La piste est déjà revendiquée par un Recording actif (webhook et
      # rattrapage concurrents). Un Recording clos de la même piste ne
      # bloque pas : après une reprise du direct, elle s'enregistre de
      # nouveau dans un nouveau fichier.
      return webinar.recordings.tracks.active.find_by(track_sid: track_sid)
    end

    unless recording_window_open?(webinar.reload) && recordable?(webinar, identity)
      recording.update!(status: :failed, error_message: "Démarrage annulé avant appel distant.", ended_at: Time.current)
      return recording
    end

    begin
      result = client.start_track_egress(room_name: webinar.room_name, track_id: track_sid, filepath: "/data/#{recording.output_prefix}")
      raise EgressClient::RemoteError, "Démarrage sans identifiant distant." if result[:egress_id].blank?
      EgressCompletion.apply(recording, result)
      if !recording_window_open?(webinar.reload) || !recordable?(webinar, identity) || recording.reload.stopping?
        stop(recording, client: client)
      end
    rescue EgressClient::Error => error
      recording.with_lock do
        unless recording.done?
          recording.update!(status: :failed, error_message: "Démarrage incertain : #{error.message}")
        end
      end
    end
    recording
  end

  # Rattrapage des pistes DÉJÀ PUBLIÉES au moment où la fenêtre
  # d'enregistrement s'ouvre (go_live!, start composite). Interrogation
  # best-effort du client RoomService (list_participants) ; chaque piste
  # publiée d'une identité STANDARD à enregistrer (`recordable?`) déclenche un
  # StartTrackEgressJob — idempotent par l'index unique sur la piste
  # ACTIVE (RecordNotUnique rescue en interne) : une piste déjà en captation
  # n'est pas relancée, une piste dont l'enregistrement est clos l'est.
  #
  # Les participants kind != STANDARD (EGRESS, AGENT, INGRESS, SIP,
  # CONNECTOR, BRIDGE) sont ignorés : leurs pistes synthétiques
  # (enregistrement, transcription) n'ont rien à faire dans l'archive.
  #
  # Pas d'exception propagée : un échec distant est logué sans PII,
  # le direct/composite continue (invariant miroir du webhook).
  def self.backfill(webinar, room_client: nil)
    sweep_stale_composites(webinar)
    return unless recording_window_open?(webinar.reload)
    return unless ENV["TRACK_EGRESS_ENABLED"] == "true"

    room_client ||= Rails.configuration.x.room_service_client_factory.call
    participants = room_client.list_participants(room: webinar.room_name)
    return unless participants.is_a?(Array)

    participants.each do |participant|
      next unless participant.is_a?(Hash)

      kind = participant[:kind].to_s
      next unless kind.empty? || kind == "STANDARD"

      identity = participant[:identity].to_s
      next if identity.blank?
      next unless recordable?(webinar, identity)

      Array(participant[:tracks]).each do |track|
        next unless track.is_a?(Hash)

        sid = track[:sid].to_s
        source = track[:source].to_s.downcase
        next unless valid_track?(sid, source)

        StartTrackEgressJob.perform_later(webinar.id, sid, identity, source)
      end
    end
  rescue RoomServiceClient::Error => error
    Rails.logger.warn(
      "[track_recording_session] backfill room=#{webinar.room_name} err=#{error.class}: #{error.message}"
    )
  end

  def self.stop(recording, client: RecordingSession.default_client)
    egress_id = nil
    recording.with_lock do
      return :inactive if recording.done?
      # Idempotence (cas réel : cascade compose→tracks
      # peut recouper stop_all en fin de direct). Une piste déjà en
      # cours d'arrêt avec un egress identifié a déjà vu client.stop —
      # on ne rappelle pas (évite deux ordres stop remote par piste).
      return :pending if recording.stopping? && recording.egress_id.present?
      recording.update!(status: :stopping, error_message: nil)
      egress_id = recording.egress_id
      if egress_id.blank?
        recording.update!(error_message: "Arrêt en attente du retour de démarrage distant.")
        return :pending
      end
    end

    result = client.stop(egress_id: egress_id)
    EgressCompletion.apply(recording, result)
    recording.reload.failed? ? :failed : (recording.done? ? :ok : :pending)
  rescue EgressClient::Error => error
    recording.with_lock do
      recording.update!(status: :stopping, error_message: "Arrêt incertain : #{error.message}") unless recording.done?
    end
    :failed
  end
end
