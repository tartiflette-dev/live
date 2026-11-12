# frozen_string_literal: true

# EgressClient — adaptateur unique de la dépendance `livekit-server-sdk`
# côté egress. `LiveKit::…`
# n'est nommé QUE ici, jamais ailleurs dans l'app (grep = vérification).
#
# Cible : le service `EgressService` twirp exposé par `livekit-server` en
# INTERNE (`http://livekit:7880`), consommé côté serveur uniquement — jamais
# depuis le navigateur (grants = clés API secrètes). En dev/test, `LIVEKIT_HOST`
# vaut typiquement `http://localhost:7880` ou est stubbé (tests unitaires).
#
# ENV lus :
#   LIVEKIT_HOST         base URL du twirp EgressService (défaut : http://livekit:7880)
#   STAGING_LIVEKIT_HOST optionnelle : sur l'instance de pré-production
#                        (STAGING_HOSTS), seul serveur média accepté ; sans
#                        elle, la pré-production n'impose aucun serveur média.
#   LIVEKIT_API_KEY      identité api (partagée avec livekit-server)
#   LIVEKIT_API_SECRET   secret HS256
#
# **Fail-loud** : toute erreur d'appel ou de configuration
# est ré-émise en `EgressClient::Error` (ou sous-classe), avec un message
# lisible pour l'UI. Le controller la persiste dans `Recording#error_message`
# et affiche via flash — un Recording ne reste JAMAIS en état ambigu.
class EgressClient
  # Défaut cohérent avec la configuration de l'egress (ws_url ws://livekit:7880) —
  # la lib twirp attend un http:// (upgrade WS géré côté livekit-server).
  DEFAULT_HOST = "http://livekit:7880"

  # Layout du template composite par défaut (egress `template-default`) :
  # `speaker` = l'intervenant actif / le partage d'écran occupe la scène,
  # les autres caméras en vignettes. Le défaut egress (`grid`) donne au
  # partage d'écran une tuile de la taille d'une caméra — illisible dans
  # un replay de démo « écran partagé ». Valeurs
  # possibles côté template : grid | speaker | single-speaker.
  COMPOSITE_LAYOUT = "speaker"

  class Error < StandardError; end
  class MissingCredentials < Error; end
  class RemoteError        < Error; end

  # @param host [String, nil]        base URL (défaut ENV LIVEKIT_HOST ou DEFAULT_HOST)
  # @param api_key [String, nil]     défaut ENV LIVEKIT_API_KEY
  # @param api_secret [String, nil]  défaut ENV LIVEKIT_API_SECRET
  # @param twirp_client [Object, nil] injection pour tests (duck-type)
  def initialize(host: nil, api_key: nil, api_secret: nil, twirp_client: nil)
    @host        = host       || ENV.fetch("LIVEKIT_HOST", DEFAULT_HOST)
    @api_key     = api_key    || ENV["LIVEKIT_API_KEY"].to_s
    @api_secret  = api_secret || ENV["LIVEKIT_API_SECRET"].to_s
    @injected    = twirp_client
  end

  # Démarre un egress room-composite (SFU) → MP4 sur disque local du
  # conteneur egress (monté sur l'hôte : le dossier que l'app lit sous RECORDINGS_ROOT),
  # layout `COMPOSITE_LAYOUT` (speaker).
  #
  # @param room_name [String] room LiveKit (= Webinar#room_name)
  # @param filepath  [String] chemin ABSOLU côté conteneur egress
  #   (ex. "/data/webinaire-alpha/2026-…-uuid.mp4"). Le préfixe `/data/`
  #   correspond au volume monté dans le conteneur egress (compose LiveKit).
  # @return [Hash] { egress_id:, status:, raw: EgressInfo }
  # @raise [MissingCredentials, RemoteError]
  def start_room_composite(room_name:, filepath:)
    ensure_credentials!

    output = LiveKit::Proto::EncodedFileOutput.new(
      file_type: :MP4,
      filepath:  filepath
    )

    info = twirp_client.start_room_composite_egress(room_name, output, layout: COMPOSITE_LAYOUT)
    normalize(info)
  rescue LiveKit::ServerError => e
    # ServerError porte code (string, ex. "not_found") + message — on garde
    # les deux pour diagnostic. Levé par `rpc!` du SDK (auth_mixin.rb) chaque
    # fois que livekit-server répond une erreur Twirp.
    raise RemoteError, redacted_message("egress start refusé (#{e.code}) : #{e.message}"), cause: nil
  rescue Errno::ECONNREFUSED, Faraday::ConnectionFailed, SocketError => e
    raise RemoteError, redacted_message("egress injoignable (#{@host}) : #{e.message}"), cause: nil
  end

  # One native track, no transcoding. filepath is an output intent
  # under the egress container's /data mount; the codec determines its suffix.
  def start_track_egress(room_name:, track_id:, filepath:)
    ensure_credentials!
    raise ArgumentError, "room_name and track_id required" if room_name.to_s.strip.empty? || track_id.to_s.strip.empty?
    unless filepath.to_s.match?(/\A\/data\/[a-z0-9-]+\/[a-z0-9-]+(?:\.(?:mp4|webm|ogg))?\z/)
      raise ArgumentError, "track filepath must remain under /data/<slug>/"
    end

    output = LiveKit::Proto::DirectFileOutput.new(filepath: filepath)
    normalize(twirp_client.start_track_egress(room_name, output, track_id))
  rescue LiveKit::ServerError => e
    raise RemoteError, redacted_message("track egress start refusé (#{e.code}) : #{e.message}"), cause: nil
  rescue Errno::ECONNREFUSED, Faraday::ConnectionFailed, Faraday::TimeoutError, SocketError => e
    raise RemoteError, redacted_message("egress injoignable (#{@host}) : #{e.message}"), cause: nil
  end

  # Interroge livekit-server sur l'état d'un egress connu — utilisé par
  # `RecordingSession.reconcile` :
  # un egress peut se terminer tout seul (« Source closed » — départ hôte +
  # departure_timeout room) : le fichier est finalisé côté disque mais le
  # Recording reste `recording` en DB → l'auto-start suivant voit un « actif »
  # fantôme (contrainte unique composite) et se tait.
  #
  # @param egress_id [String] identifiant précis (recherche 1:1)
  # @return [Hash, nil] { egress_id:, status:, ended_at:, error:, raw: }
  #   ; nil si livekit ne connaît PAS l'egress (déjà GC'd, ou id invalide)
  # @raise [MissingCredentials, RemoteError] jamais avalé — l'appelant
  #   décide de la conduite à tenir (log warning + skip côté reconcile).
  def list_egress(egress_id:)
    ensure_credentials!
    raise ArgumentError, "egress_id required" if egress_id.to_s.empty?

    response = twirp_client.list_egress(egress_id: egress_id)
    items = response.items || []
    return nil if items.empty?

    normalize(items.first)
  rescue LiveKit::ServerError => e
    # `not_found` = livekit-server AFFIRME que cet egress n'existe pas
    # (GC'd, ou id jamais valide) — c'est un ÉTAT (« introuvable »), pas
    # une erreur transitoire. On retourne nil : reconcile_recording le
    # traduit en Recording :failed avec message explicite. Toute AUTRE
    # code twirp reste une erreur → fail-safe (Recording laissé en l'état).
    return nil if e.code.to_s == "not_found"
    raise RemoteError, redacted_message("egress list refusé (#{e.code}) : #{e.message}"), cause: nil
  rescue Errno::ECONNREFUSED, Faraday::ConnectionFailed, SocketError => e
    raise RemoteError, redacted_message("egress injoignable (#{@host}) : #{e.message}"), cause: nil
  end

  # Arrête un egress en cours. Idempotent côté livekit-server : un stop sur
  # egress inconnu remonte Twirp::Error not_found → RemoteError (l'appelant
  # décide s'il traite comme succès ou échec ; ici on ne masque rien).
  #
  # @param egress_id [String]
  # @return [Hash] { egress_id:, status:, raw: EgressInfo }
  # @raise [MissingCredentials, RemoteError]
  def stop(egress_id:)
    ensure_credentials!
    raise ArgumentError, "egress_id required" if egress_id.to_s.empty?

    info = twirp_client.stop_egress(egress_id)
    normalize(info)
  rescue LiveKit::ServerError => e
    raise RemoteError, redacted_message("egress stop refusé (#{e.code}) : #{e.message}"), cause: nil
  rescue Errno::ECONNREFUSED, Faraday::ConnectionFailed, SocketError => e
    raise RemoteError, redacted_message("egress injoignable (#{@host}) : #{e.message}"), cause: nil
  end

  private

  def redacted_message(message)
    [ @api_key, @api_secret ].reject(&:blank?).sort_by { |secret| -secret.length }.reduce(message) do |text, secret|
      text.gsub(secret, "[FILTERED]")
    end
  end

  def twirp_client
    @injected || LiveKit::EgressServiceClient.new(
      @host, api_key: @api_key, api_secret: @api_secret
    )
  end

  def ensure_credentials!
    if staging_media_mismatch?
      raise Error, "Le staging doit utiliser son serveur média isolé."
    end

    unless ENV.fetch("EGRESS_ENABLED", "true") == "true"
      raise Error, "Enregistrement désactivé : egress isolé requis pour cet environnement."
    end

    return if @api_key != "" && @api_secret != ""

    raise MissingCredentials,
      "LIVEKIT_API_KEY / LIVEKIT_API_SECRET absents — voir la documentation de déploiement"
  end

  # La pré-production qui déclare son serveur média isolé ne pilote jamais
  # un autre egress : un LIVEKIT_HOST hérité de la prod y enregistrerait (ou
  # arrêterait) les sessions de la prod.
  def staging_media_mismatch?
    isolated_host = ENV["STAGING_LIVEKIT_HOST"].presence
    isolated_host && StagingHost.current? && @host != isolated_host
  end

  # EgressInfo (proto) → Hash simple pour l'appelant : évite de faire
  # remonter le type proto jusqu'au controller (frontière adaptateur).
  # `ended_at` et `error` sont renvoyés en clair pour la réconciliation :
  # un egress terminé côté
  # livekit-server porte un `ended_at` non-nul (Unix ms) et, en cas
  # d'échec, un `error` texte lisible (« Source closed », etc.).
  def normalize(info)
    {
      egress_id: info.egress_id,
      status:    proto_status_to_symbol(info.status),
      ended_at:  info.ended_at,
      error:     info.error.to_s.presence,
      raw:       info,
      files:     info.respond_to?(:file_results) ? info.file_results.map(&:filename) : []
    }
  end

  # Enum proto → symbole lisible (starting/active/ending/complete/failed/…).
  # Cf. livekit_egress_pb.rb : EgressStatus.
  def proto_status_to_symbol(status)
    case status
    when :EGRESS_STARTING, 0      then :starting
    when :EGRESS_ACTIVE, 1        then :active
    when :EGRESS_ENDING, 2        then :ending
    when :EGRESS_COMPLETE, 3      then :complete
    when :EGRESS_FAILED, 4        then :failed
    when :EGRESS_ABORTED, 5       then :aborted
    when :EGRESS_LIMIT_REACHED, 6 then :limit_reached
    else                               status.to_s.downcase.to_sym
    end
  end
end
