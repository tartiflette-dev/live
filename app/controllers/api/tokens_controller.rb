module Api
  # Émission de tokens LiveKit.
  #
  # Endpoint UNIQUE d'émission côté salle : le client JS (composant React
  # `rooms/room.jsx`) POST ici pour obtenir `{ token, serverUrl, role, room,
  # identity, devicePreferences, participantConsent }` et monter
  # `<LiveKitRoom>`. Le rôle est
  # décidé ICI, jamais transmis par le client (test
  # `token_endpoint_role_enforcement`).
  #
  # Décision de rôle : RoomParticipant#resolve_role (ordre strict host /
  # cohost, puis speaker, puis viewer) ; aucun participant reconnu → 403.
  #
  # Aucun paramètre client (`role`, `host_sub`, `identity` sub…) ne peut
  # promouvoir le rôle. Un attaquant qui POST `{slug, role:"host"}` reçoit
  # un token viewer seulement avec une inscription confirmée, sinon 403.
  # Propriété de sécurité testée en controller test.
  #
  # Format : JSON in, JSON out. CSRF actif (Rails omakase, meta-tag CSRF
  # lu par le composant React et posé en X-CSRF-Token header).
  class TokensController < ApplicationController
    include RoomParticipant
    include JsonOnly
    include PresenceCapture

    # Format d'entrée : { "slug": "...", "speaker_token": "..." | null }.
    # Format de sortie 200 : { token, serverUrl, role, room, identity,
    # devicePreferences, participantConsent } — devicePreferences =
    # préférences de périphériques mémorisées (contrat DevicePreference),
    # null pour un spectateur qui n'a pas de mémoire serveur ;
    # participantConsent = accord à l'image (contrat ParticipantConsent),
    # null pour l'animation de droit, qui n'a pas de fenêtre de consentement.
    # Le droit de publier du jeton vient de PublishPermission : fermé à qui
    # n'a pas d'accord en cours.
    # 404 si slug inconnu. Jamais 500 sur input malformé (rescue explicite).
    def create
      slug = params[:slug].to_s
      @webinar = Webinar.find_by(slug: slug)
      return head :not_found if @webinar.nil?

      resolution = resolve_role(webinar: @webinar, speaker_token: params[:speaker_token])
      return render json: { error: "registration_required" }, status: :forbidden unless resolution

      identity = identity_for(resolution.role, resolution.subject)
      # Défense en profondeur : un :speaker sans subject (régression —
      # ne devrait plus arriver depuis la suppression du legacy) ne
      # peut pas recevoir d'identité ; on refuse plutôt que d'émettre
      # un JWT sans identity.
      return render json: { error: "registration_required" }, status: :forbidden if identity.nil?

      # Entrée d'un spectateur : un inscrit « participant »
      # entre main levée, à admettre depuis la régie. Son jeton ne publie que
      # selon PublishPermission (accord à l'image et parole accordée).
      viewer = resolution.role == :viewer
      HandRaiseControl.new(@webinar).raise_declared_hand(resolution.record) if viewer
      publish = PublishPermission.new(@webinar).token_grant(resolution.record)

      # TTL explicite ici : COURT pour
      # un :cohost et pour tout jeton qui publie hors animation de droit
      # (accord à l'image et parole se retirent en cours de direct, défense
      # stale-authorization), standard sinon. La décision est VISIBLE côté
      # endpoint pour qu'un reviewer la lise sans ouvrir le service.
      ttl = LivekitTokenService.ttl_for(resolution.role, publishes: publish[:can_publish])

      token = LivekitTokenService.new(
        room: @webinar.room_name,
        identity: identity,
        role: resolution.role,
        name: resolution.name,
        ttl: ttl,
        can_publish: publish[:can_publish],
        publish_sources: publish[:sources]
      ).call
      note_presence_attempt(@webinar, "token_issued", identity)

      render json: {
        token: token,
        serverUrl: livekit_server_url,
        role: resolution.role.to_s,
        room: @webinar.room_name,
        identity: identity,
        devicePreferences: device_preferences_payload(resolution.record),
        participantConsent: ParticipantConsent.payload_for(@webinar, resolution.record)
      }
    end

    private

    def device_preferences_payload(record)
      DevicePreference.payload_for(record) if DevicePreference.ownable?(record)
    end

    # Identités uniques par participant (LiveKit refuse deux participants
    # avec la même identity dans une même room). Host/cohost = oidc_sub
    # stable ; les deux rôles partagent le préfixe `host-` côté identité
    # (TrackRecordingSession.authorized? lit `host-<sub>` indifféremment
    # — c'est le TOKEN LiveKit qui diffère par ses grants). Named
    # speakers (:speaker) et registered viewers (:viewer) ont une
    # identité stable fondée sur leur record DB.
    #
    # Depuis la suppression du chemin legacy, `:speaker`
    # exige TOUJOURS un `subject` (Speaker.id). Un appelant qui
    # obtiendrait :speaker sans subject (régression) reçoit `nil` →
    # côté caller cela coupe l'émission du token (403).
    def identity_for(role, subject)
      case role
      when :host, :cohost then "host-#{subject}"
      when :speaker       then subject ? "speaker-#{subject}" : nil
      when :viewer        then "viewer-#{subject}"
      end
    end

    # URL du signal LiveKit (le client ajoute `/rtc` lui-même), propre à
    # chaque instance : en production, son absence refuse le démarrage
    # (InstanceSettings). Hors production, repli sur le serveur LiveKit local
    # de développement.
    def livekit_server_url
      ENV["LIVEKIT_URL"].presence || "ws://localhost:7880"
    end
  end
end
