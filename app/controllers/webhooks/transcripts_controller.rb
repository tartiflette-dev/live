module Webhooks
  # Segments de transcript poussés par transcriber/ (LiveKit
  # Agent + Whisper). Même recette de signature que le webhook
  # LiveKit (JWT HS256, iss = LIVEKIT_API_KEY, claim sha256 = base64 du
  # SHA-256 du corps brut) — le verifier est réutilisé via sa méthode
  # `authenticate!`.
  #
  # Payload JSON applicatif :
  #   {
  #     "room":         "<livekit room name>",
  #     "segment_id":   "<uuid v4>",
  #     "participant": {
  #       "identity": "speaker-42",
  #       "name":     "Pauline"
  #     },
  #     "text":         "...",
  #     "started_at":   "2026-10-07T09:00:12.123Z",
  #     "ended_at":     "2026-10-07T09:00:15.789Z"
  #   }
  #
  # Invariants :
  #   • room inconnue → 204 no-op (jamais 500). L'agent ne connaît pas
  #     l'état applicatif ; on absorbe silencieusement.
  #   • duplicate (webinar_id, segment_id) → 204 no-op (idempotence :
  #     l'agent retente après timeout).
  #   • parole commencée après la fin du direct → 204 no-op.
  #   • payload mal formé → 400.
  #   • signature invalide → 401.
  #
  # No cookie/session authority: la signature protège le corps brut.
  class TranscriptsController < ActionController::API
    MAX_BODY_BYTES = 128.kilobytes

    # L'agent ne rejoint une salle que si l'app l'y autorise : ce drapeau
    # ne change que par un déploiement de l'instance, décidé par son
    # opérateur. Un agent démarré sans ce drapeau reste donc inerte
    # (fail-closed).
    def enabled
      response.headers["Cache-Control"] = "no-store"
      render json: { enabled: self.class.enabled? }
    end

    def self.enabled?
      ENV["TRANSCRIPT_ENABLED"] == "true"
    end

    def create
      return head :no_content unless self.class.enabled?

      body = request.raw_post
      return head :content_too_large if body.bytesize > MAX_BODY_BYTES

      LivekitWebhookVerifier.authenticate!(
        body: body,
        authorization: request.headers["Authorization"],
        api_key: ENV["LIVEKIT_API_KEY"],
        api_secret: ENV["LIVEKIT_API_SECRET"],
      )

      payload = JSON.parse(body)
      ingest(payload)
      head :no_content
    rescue LivekitWebhookVerifier::Unauthorized
      head :unauthorized
    rescue LivekitWebhookVerifier::MissingCredentials
      head :service_unavailable
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError
      head :bad_request
    end

    private

    # Les erreurs applicatives (webinar introuvable, segment dupliqué)
    # ne doivent JAMAIS lever un 500 — l'agent n'a pas la visibilité
    # pour les corriger, et chaque échec coûterait une re-livraison en
    # boucle. On absorbe en 204 et on sort.
    def ingest(payload)
      room_name  = payload.fetch("room").to_s
      segment_id = payload.fetch("segment_id").to_s
      return if segment_id.empty? || room_name.empty?

      webinar = Webinar.find_by(room_name: room_name)
      return unless webinar

      participant = payload.fetch("participant", {})
      identity    = participant["identity"].to_s
      # Même règle que l'enregistrement des pistes : animateur, intervenant
      # actif, spectateur inscrit confirmé (prise de parole). Jamais un
      # intervenant révoqué, un lien legacy ou un inconnu.
      return unless TrackRecordingSession.authorized?(webinar, identity)

      started_at = Time.iso8601(payload.fetch("started_at"))
      # Parole commencée après la fin du direct : jamais archivée, même si un
      # agent est resté ou arrivé à contretemps. Une phrase
      # commencée avant la fin et transcrite après est gardée.
      return if webinar.ended? && (webinar.ended_at.nil? || started_at > webinar.ended_at)

      TranscriptSegment.create(
        webinar: webinar,
        participant_identity: identity[0, 128],
        speaker_name: participant["name"].to_s.presence&.slice(0, 128),
        text: payload.fetch("text").to_s,
        started_at: started_at,
        ended_at: Time.iso8601(payload.fetch("ended_at")),
        segment_id: segment_id[0, 128],
      )
    rescue ActiveRecord::RecordNotUnique
      # (webinar_id, segment_id) existe déjà → idempotence.
      nil
    end
  end
end
