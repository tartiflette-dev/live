require "timeout"

# Vue serveur de la salle LiveKit pour la régie : qui est
# là, qui est sur scène, ce qui est mis en avant. La régie ne rejoint
# JAMAIS la salle (aucune connexion média, aucun flux vidéo) : elle lit
# ce que LiveKit sait, par l'API RoomService.
#
# Mêmes règles de comptage que la salle (rooms/room.jsx) :
#   • présent  = participant humain (kind STANDARD) — ni l'enregistreur
#                (EGRESS) ni le transcripteur (AGENT) ;
#   • sur scène = présent qui peut publier (animation, intervenant,
#                spectateur à qui l'on a donné la parole), ou intervenant et
#                co-animateur invité en attente d'accord à l'image
#                (`awaiting_consent`, comme `awaitsConsent` côté salle) ;
#   • participants = présents que la régie peut modérer
#                (ParticipantModeration : intervenants et spectateurs, jamais
#                l'animation), micro ouvert ou non.
#
# Fail-open : LiveKit injoignable ou en erreur → `room: "unavailable"`,
# la régie l'affiche et reste pilotable (direct, enregistrement, mains,
# discussion passent par Rails seul).
#
# Coût borné (NB1) : chaque onglet de régie relit toutes
# les 5 s, et un direct peut avoir plusieurs animateurs. La lecture est
# mise en cache CACHE_TTL par webinaire (Rails.cache, partagé entre
# onglets et processus), échec compris, ce qui borne ce qu'un LiveKit lent
# coûte en threads Puma. Une salle inconnue de LiveKit coûte un seul appel
# (ListRooms), jamais ListParticipants.
#
# La lecture (les deux appels) est coupée à RPC_TIMEOUT_SECONDS, sous la
# durée du cache : un LiveKit lent retient une requête 2 s au plus, puis
# l'échec est mis en cache pour la période. Pas de verrou : pendant une
# lecture lente, un autre onglet qui trouve le cache vide lit aussi, avec
# la même borne.
class RoomSnapshot
  RPC_TIMEOUT_SECONDS = 2
  CACHE_TTL = 3.seconds
  HUMAN_KINDS = [ "", "STANDARD" ].freeze
  # Libellé d'une personne sans nom affiché, d'après le préfixe de
  # l'identité émise par Api::TokensController (host-<sub>, speaker-<id>,
  # viewer-<id>). Affichage seulement : l'identité elle-même figure dans
  # `on_stage` (la mise en avant la vise) ; LiveKit la diffuse déjà à toute
  # la salle, la régie, réservée à l'animation, n'expose rien de nouveau.
  ROLE_LABELS = { "host" => "Animation", "speaker" => "Intervenant", "viewer" => "Spectateur" }.freeze

  def initialize(webinar, client: nil)
    @webinar = webinar
    @client = client
  end

  # @return [Hash] { room:, present:, on_stage: [...], participants: [...], spotlight: }
  #   room : "open" (salle ouverte), "closed" (LiveKit ne la connaît pas),
  #   "unavailable" (LiveKit injoignable).
  def call
    Rails.cache.fetch(self.class.cache_key(@webinar), expires_in: CACHE_TTL) { read }
  end

  # Une écriture de la salle (mise en avant, RoomSpotlight) rend la lecture
  # en cache périmée : la régie qui vient de commander voit le résultat au
  # tour suivant, pas trois secondes plus tard.
  def self.expire(webinar)
    Rails.cache.delete(cache_key(webinar))
  end

  def self.cache_key(webinar)
    [ "room_snapshot", webinar.id ]
  end

  private

  def read
    metadata, participants = Timeout.timeout(RPC_TIMEOUT_SECONDS, RoomServiceClient::Error, "LiveKit room read timed out") do
      read_room
    end
    return closed if metadata.nil?

    humans = participants.select { |participant| participant[:kind].to_s.in?(HUMAN_KINDS) }
    {
      room: "open",
      present: humans.size,
      on_stage: humans.select { |participant| publishing?(participant) || awaiting_consent?(participant) }
                      .map { |participant| on_stage_entry(participant) },
      participants: humans.select { |participant| ParticipantModeration.target?(participant[:identity]) }
                          .map { |participant| participant_entry(participant) },
      spotlight: RoomSpotlight.identity_in(metadata)
    }
  rescue RoomServiceClient::RemoteError => e
    return closed if e.code == "not_found"

    unavailable(e)
  rescue RoomServiceClient::Error => e
    unavailable(e)
  end

  # [métadonnées, participants] ; participants non lus pour une salle que
  # LiveKit ne connaît pas.
  def read_room
    metadata = client.room_metadata(room: @webinar.room_name)
    return [ nil, [] ] if metadata.nil?

    [ metadata, client.list_participants(room: @webinar.room_name) ]
  end

  def client
    @client ||= Rails.configuration.x.room_service_client_factory.call
  end

  # `camera` : caméra publiée ET allumée. Éteindre sa caméra la coupe
  # (mute) sans la dépublier : la régie la dit coupée, et ne l'attend pas
  # dans les mesures (CameraSample, rien n'est relevé caméra coupée).
  def on_stage_entry(participant)
    tracks = Array(participant[:tracks])
    sources = tracks.map { |track| track[:source].to_s }
    {
      identity: participant[:identity],
      name: display_name(participant),
      camera: tracks.any? { |track| track[:source].to_s == "CAMERA" && !track[:muted] },
      screen_share: sources.include?("SCREEN_SHARE"),
      awaiting_consent: awaiting_consent?(participant)
    }
  end

  def publishing?(participant)
    participant.dig(:permission, :can_publish) == true
  end

  # Intervenant ou co-animateur invité que la salle ne laisse pas encore
  # publier, faute d'accord à l'image (PublishPermission).
  def awaiting_consent?(participant)
    !publishing?(participant) && role_of(participant).in?(%w[host speaker])
  end

  def participant_entry(participant)
    {
      identity: participant[:identity],
      name: display_name(participant),
      role: role_of(participant),
      microphone: ParticipantModeration.open_audio_tracks(participant).any?
    }
  end

  def display_name(participant)
    participant[:name].presence || ROLE_LABELS.fetch(role_of(participant), "Participant")
  end

  def role_of(participant)
    participant[:identity].to_s.split("-", 2).first
  end

  def closed
    { room: "closed", present: 0, on_stage: [], participants: [], spotlight: nil }
  end

  def unavailable(error)
    Rails.logger.info("[room_snapshot] salle illisible webinar=#{@webinar.slug} : #{error.message}")
    { room: "unavailable", present: nil, on_stage: [], participants: [], spotlight: nil }
  end
end
