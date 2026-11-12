# frozen_string_literal: true

# Émission des access tokens LiveKit (JWT HS256) par rôle.
#
# Quatre rôles, quatre jeux de grants :
#
#   • :host       → peut publier + roomAdmin (mute/kick/end room) — réservé
#                   owner ET project_host (droits étendus live, admin cible)
#   • :cohost     → peut publier (PAS roomAdmin) — co-animateur INVITÉ,
#                   participe à l'animation côté app Rails (go_live/end,
#                   mains levées), mais ne doit JAMAIS tenir le pouvoir
#                   LiveKit de couper/expulser l'animateur du projet
# (défense privilege-escalation).
#   • :speaker    → peut publier (pas roomAdmin) — intervenant invité
#                   (lien signé, hors Pocket ID)
#   • :viewer     → subscribe seulement (canPublish=false) — public spectateur
#
# Le droit de publier par défaut du rôle cède à `can_publish:` /
# `publish_sources:` quand l'appelant les donne : Api::TokensController les
# tient de PublishPermission (accord à l'image).
# Un jeton qui publie hors animation de droit reçoit le TTL court
# COHOST_TTL (accord et parole se retirent en cours de direct).
#
# Clés lues d'ENV via `LiveKit::AccessToken` (LIVEKIT_API_KEY /
# LIVEKIT_API_SECRET). Aucune clé n'est jamais lue depuis un fichier commité
# (invariant spec §Secrets).
#
# TTL courts : viewer/speaker/host ≤ 4h. Décision architecturale :
# le token est **re-signé à chaque accès** par le controller qui sert la page
# scène (jamais de JWT figé dans un favori).
# Ce service ne gère ni le stockage, ni le re-signage : il ne fait qu'émettre.
#
# Non-objectifs (spec) : ce service N'expose PAS d'endpoint HTTP (controllers
# sœurs), NE gère PAS l'egress (action W3 dédiée).
class LivekitTokenService
  # TTL par défaut : 4 heures. Suffisant pour un webinaire, contraint pour
  # limiter l'exploitation d'un token fuité. La re-signature à chaque
  # accès rend un TTL long inutile côté produit.
  DEFAULT_TTL = 4 * 60 * 60 # 4h en secondes

  # TTL court des droits qui se retirent en cours de direct (défense
  # stale-authorization) : rôle `:cohost` (un
  # co-animateur invité perd vite son accès si son droit est retiré côté
  # Rails) et tout jeton qui publie hors animation de droit (intervenant ou
  # spectateur sous accord à l'image, PublishPermission : accord retiré ou
  # parole reprise, son jeton ne doit pas les lui rendre longtemps). Combiné
  # avec la garde webhook `participant_joined` (Webhooks::LivekitController :
  # expulsion, PublishPermission#reconcile_on_join), un JWT périmé ne tient
  # au plus que `COHOST_TTL` secondes.
  COHOST_TTL = 15 * 60 # 15 min en secondes

  ROLES = %i[host cohost speaker viewer].freeze

  class UnknownRole < ArgumentError; end
  class MissingCredentials < RuntimeError; end

  # TTL court pour :cohost et pour tout jeton qui publie hors animation de
  # droit (`:host`), défense stale-authorization ; les autres gardent 4 h —
  # le composant React les fait charger une seule fois au montage et la
  # re-signature à chaque accès à la page suffit.
  def self.ttl_for(role, publishes: false)
    role == :cohost || (publishes == true && role != :host) ? COHOST_TTL : DEFAULT_TTL
  end

  # @param room [String] slug du webinaire (= `room` LiveKit)
  # @param identity [String] identifiant participant unique dans la room
  #   (host_sub, id spectateur anonyme, etc.). LiveKit refuse deux
  #   participants avec la même identity dans une même room.
  # @param role [Symbol] :host | :speaker | :viewer
  # @param name [String, nil] nom affiché (facultatif)
  # @param ttl [Integer] durée de vie en secondes (défaut : DEFAULT_TTL)
  # @param can_publish [Boolean, nil] droit de publier (nil : celui du rôle)
  # @param publish_sources [Array<String>, nil] sources permises (nil : toutes)
  def initialize(room:, identity:, role:, name: nil, ttl: nil, can_publish: nil, publish_sources: nil)
    raise UnknownRole, "role must be one of #{ROLES.inspect}, got #{role.inspect}" \
      unless ROLES.include?(role)

    @room = room
    @identity = identity
    @role = role
    @name = name
    @can_publish = can_publish.nil? ? role != :viewer : can_publish
    @publish_sources = publish_sources
    @ttl = ttl || self.class.ttl_for(role, publishes: @can_publish)
  end

  # Retourne le JWT signé, prêt à être renvoyé au client LiveKit JS.
  #
  # @return [String] JWT HS256
  # @raise [MissingCredentials] si LIVEKIT_API_KEY ou LIVEKIT_API_SECRET sont
  #   absents d'ENV au moment de l'appel.
  def call
    ensure_credentials!

    token = LiveKit::AccessToken.new(
      identity: @identity,
      ttl: @ttl,
      name: @name
    )
    token.video_grant = video_grant_for(@role)
    token.to_jwt
  end

  private

  def ensure_credentials!
    return if ENV["LIVEKIT_API_KEY"].to_s != "" && ENV["LIVEKIT_API_SECRET"].to_s != ""

    raise MissingCredentials,
      "LIVEKIT_API_KEY / LIVEKIT_API_SECRET absents d'ENV — voir la documentation de déploiement"
  end

  # Grants explicites. On ne s'en remet pas aux défauts du SDK : le contrat
  # « host = roomAdmin » et le droit de publier (celui du rôle, ou celui que
  # donne l'appelant) doivent être lisibles ici, pas déduits d'une absence de clé.
  def video_grant_for(role)
    common = { room: @room, roomJoin: true, canPublish: @can_publish, canPublishSources: @publish_sources }

    # canPublishData false pour TOUS les rôles : le client ne publie jamais de
    # données (chat en HTTP, diffusion par le serveur via RoomService SendData).
    # Un jeton qui le permet laisse forger un paquet que les filtres
    # `readServer*` prendraient pour un paquet serveur (participant undefined).
    case role
    # canUpdateOwnMetadata (host/cohost/speaker) : le nom saisi dans le
    # PreJoin devient le `name` du participant (room.jsx NameSync →
    # setName) — sans ce grant, le participant s'affiche « speaker-<session> »
    # sur la scène et dans le MP4. Le viewer ne le reçoit PAS.
    when :host
      LiveKit::VideoGrant.new(**common, canPublishData: false, canSubscribe: true, roomAdmin: true, canUpdateOwnMetadata: true)
    when :cohost
      # Co-animateur invité : publie et met à jour son métadonnée, MAIS
      # NE DÉTIENT PAS `roomAdmin` — le pilotage de la salle (mute,
      # expulsion, end room) reste owner/project_host. Les contrôles
      # applicatifs (go_live, end, mains levées) passent par les
      # endpoints Rails qui ré-évaluent `role_for` à chaque appel.
      LiveKit::VideoGrant.new(**common, canPublishData: false, canSubscribe: true, roomAdmin: false, canUpdateOwnMetadata: true)
    when :speaker
      LiveKit::VideoGrant.new(**common, canPublishData: false, canSubscribe: true, roomAdmin: false, canUpdateOwnMetadata: true)
    when :viewer
      LiveKit::VideoGrant.new(**common, canPublishData: false, canSubscribe: true, roomAdmin: false)
    end
  end
end
