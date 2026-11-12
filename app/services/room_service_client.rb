# frozen_string_literal: true

# Room operations boundary (including its dated deltas).
# Callers supply authorized room/participant identities; only plain hashes leave this adapter.
class RoomServiceClient
  DEFAULT_HOST = "http://livekit:7880"

  class Error < StandardError; end
  class MissingCredentials < Error; end
  # Refus de LiveKit, joignable. `code` = code d'erreur LiveKit
  # (« not_found », « unavailable »…), pour qui doit distinguer.
  class RemoteError < Error
    attr_reader :code

    def initialize(message = nil, code: nil)
      @code = code&.to_s
      super(message)
    end
  end

  def initialize(host: nil, api_key: nil, api_secret: nil, twirp_client: nil, dispatch_client: nil)
    @host = host || ENV.fetch("LIVEKIT_HOST", DEFAULT_HOST)
    @api_key = api_key || ENV["LIVEKIT_API_KEY"].to_s
    @api_secret = api_secret || ENV["LIVEKIT_API_SECRET"].to_s
    @injected = twirp_client
    @injected_dispatch = dispatch_client
  end

  # `sources` : noms LiveKit des sources permises (« camera »,
  # « screen_share »…) ; vide = toutes.
  def update_participant(room:, identity:, can_publish:, sources: [])
    rpc(:update_participant) do
      required_strings!(room: room, identity: identity)
      raise ArgumentError, "can_publish must be boolean" unless [ true, false ].include?(can_publish)

      permission = LiveKit::Proto::ParticipantPermission.new(
        can_publish: can_publish, can_subscribe: true, can_publish_data: false,
        can_publish_sources: sources.map { |source| source.to_s.upcase.to_sym }
      )
      twirp_client.update_participant(room: room, identity: identity, permission: permission)
    end
  end

  def mute_track(room:, identity:, track_sid:)
    rpc(:mute_track) do
      required_strings!(room: room, identity: identity, track_sid: track_sid)
      twirp_client.mute_published_track(room: room, identity: identity, track_sid: track_sid, muted: true)
    end
  end

  def remove_participant(room:, identity:)
    rpc(:remove_participant) do
      required_strings!(room: room, identity: identity)
      twirp_client.remove_participant(room: room, identity: identity)
    end
  end

  # Liste les participants d'une salle. Retourne un Array<Hash> ; chaque
  # entrée porte :identity, :kind, :tracks ([{sid:, source:}, ...]).
  # Utilisé par TrackRecordingSession.backfill — défense idempotence
  # au moment où la fenêtre d'enregistrement s'ouvre (go_live!, start
  # composite) pour rattraper les pistes publiées avant.
  def list_participants(room:)
    rpc(:list_participants) do
      required_strings!(room: room)
      twirp_client.list_participants(room: room)
    end[:participants] || []
  end

  # Métadonnées courantes d'une salle (chaîne JSON brute, "" sans
  # métadonnées) ; nil quand LiveKit ne connaît pas, ou plus, la salle.
  # Lecture seule, pour la régie (RoomSnapshot).
  def room_metadata(room:)
    rooms = rpc(:list_rooms) do
      required_strings!(room: room)
      twirp_client.list_rooms(names: [ room ])
    end[:rooms] || []
    rooms.find { |info| info[:name] == room }&.fetch(:metadata, "")
  end

  def update_room_metadata(room:, metadata:)
    rpc(:update_room_metadata) do
      required_strings!(room: room)
      twirp_client.update_room_metadata(room: room, metadata: metadata_json(metadata))
    end
  end

  def create_room(name:, empty_timeout: nil, metadata: nil)
    rpc(:create_room) do
      required_strings!(name: name)
      unless empty_timeout.nil? || (empty_timeout.is_a?(Integer) && empty_timeout.between?(0, 2**32 - 1))
        raise ArgumentError, "empty_timeout must be an unsigned integer"
      end
      twirp_client.create_room(name, empty_timeout: empty_timeout, metadata: metadata.nil? ? nil : metadata_json(metadata))
    end
  end

  def send_data(room:, data:, kind: :reliable, destination_identities: [])
    rpc(:send_data) do
      required_strings!(room: room)
      raise ArgumentError, "data must be a string" unless data.is_a?(String)
      raise ArgumentError, "kind must be reliable or lossy" unless [ :reliable, :lossy ].include?(kind)
      unless destination_identities.is_a?(Array) && destination_identities.all? { |identity| identity.is_a?(String) && identity.present? }
        raise ArgumentError, "destination_identities must contain nonempty strings"
      end
      twirp_client.send_data(room: room, data: data, kind: kind == :reliable ? :RELIABLE : :LOSSY,
        destination_identities: destination_identities)
    end
  end

  # Dispatches d'agents de la salle (transcripteur nommé, TranscriberPresence).
  # Chaque entrée porte :id, :agent_name, :state ({ created_at:, jobs: [...] }),
  # horodatages LiveKit en nanosecondes.
  def list_agent_dispatches(room:)
    rpc(:list_dispatch) do
      required_strings!(room: room)
      LiveKit::Proto::ListAgentDispatchResponse.new(agent_dispatches: dispatch_client.list_dispatch(room).to_a)
    end[:agent_dispatches] || []
  end

  # LiveKit crée la salle si elle n'existe pas : l'appelant vérifie avant
  # qu'il y a quelqu'un à transcrire.
  def create_agent_dispatch(room:, agent_name:)
    rpc(:create_dispatch) do
      required_strings!(room: room, agent_name: agent_name)
      dispatch_client.create_dispatch(room, agent_name)
    end
  end

  # LiveKit termine les jobs du dispatch et retire leur agent de la salle.
  def delete_agent_dispatch(room:, dispatch_id:)
    rpc(:delete_dispatch) do
      required_strings!(room: room, dispatch_id: dispatch_id)
      dispatch_client.delete_dispatch(dispatch_id, room)
    end
  end

  private

  def dispatch_client
    @injected_dispatch ||= LiveKit::AgentDispatchServiceClient.new(@host, api_key: @api_key, api_secret: @api_secret)
  end

  def twirp_client
    @injected ||= LiveKit::RoomServiceClient.new(@host, api_key: @api_key, api_secret: @api_secret)
  end

  def rpc(operation)
    raise MissingCredentials, "LIVEKIT_API_KEY / LIVEKIT_API_SECRET absents" if @api_key.blank? || @api_secret.blank?

    response = yield
    raise TypeError, "missing SDK response" if response.nil?

    JSON.parse(Google::Protobuf.encode_json(response, emit_defaults: true, preserve_proto_fieldnames: true), symbolize_names: true)
  rescue Error
    raise
  rescue LiveKit::ServerError => e
    raise RemoteError.new("room #{operation} refusé (#{e.code}) : #{redacted_message(e)}", code: e.code), cause: nil
  rescue StandardError => e
    raise Error, "room #{operation} échoué (#{e.class}) : #{redacted_message(e)}", cause: nil
  end

  def redacted_message(error)
    [ @api_key, @api_secret ].reject(&:blank?).reduce(error.message) { |message, secret| message.gsub(secret, "[FILTERED]") }
  end

  def required_strings!(**values)
    values.each do |name, value|
      raise ArgumentError, "#{name} must be a nonempty string" unless value.is_a?(String) && value.present?
    end
  end

  def metadata_json(metadata)
    raise ArgumentError, "metadata must be a hash" unless metadata.is_a?(Hash)

    JSON.generate(metadata)
  end
end
