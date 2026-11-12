# frozen_string_literal: true

require "test_helper"

class RoomServiceClientTest < ActiveSupport::TestCase
  # Exercise the installed SDK's protobuf construction without an HTTP connection.
  class CapturingSdk < LiveKit::RoomServiceClient
    attr_reader :requests
    attr_accessor :failure

    def initialize
      @requests = []
      @api_key = "test-key"
      @api_secret = "test-secret"
    end

    attr_accessor :participants_response, :rooms_response

    def rpc!(method, request, **)
      @requests << [ method, request ]
      raise failure if failure

      case method
      when :UpdateParticipant
        LiveKit::Proto::ParticipantInfo.new(identity: request.identity, permission: request.permission)
      when :CreateRoom
        LiveKit::Proto::Room.new(name: request.name, metadata: request.metadata)
      when :UpdateRoomMetadata
        LiveKit::Proto::Room.new(name: request.room, metadata: request.metadata)
      when :MutePublishedTrack
        LiveKit::Proto::MuteRoomTrackResponse.new(track: LiveKit::Proto::TrackInfo.new(sid: request.track_sid, muted: request.muted))
      when :RemoveParticipant
        LiveKit::Proto::RemoveParticipantResponse.new
      when :SendData
        LiveKit::Proto::SendDataResponse.new
      when :ListParticipants
        @participants_response || LiveKit::Proto::ListParticipantsResponse.new
      when :ListRooms
        @rooms_response || LiveKit::Proto::ListRoomsResponse.new
      end
    end
  end

  setup do
    @sdk = CapturingSdk.new
    @client = RoomServiceClient.new(api_key: "test-key", api_secret: "test-secret", twirp_client: @sdk)
  end

  test "update_participant_permissions promotes and revokes publishing without ever allowing data publishing" do
    [ true, false ].each do |publish|
      result = @client.update_participant(room: "room", identity: "viewer-42", can_publish: publish)
      method, request = @sdk.requests.last
      assert_equal :UpdateParticipant, method
      assert_equal "room", request.room
      assert_equal "viewer-42", request.identity
      assert_equal publish, request.permission.can_publish
      assert request.permission.can_subscribe
      assert_equal false, request.permission.can_publish_data, "la parole accordée ne rouvre pas la publication de données"
      assert_equal "viewer-42", result[:identity]
      assert_equal publish, result[:permission][:can_publish]
      assert_kind_of Hash, result[:permission]
    end
  end

  test "update_participant limite les sources publiables quand elles sont données ; sans elles, toutes" do
    @client.update_participant(room: "room", identity: "speaker-7", can_publish: true, sources: PublishPermission::SOURCES)
    assert_equal %i[CAMERA MICROPHONE SCREEN_SHARE SCREEN_SHARE_AUDIO], @sdk.requests.last.last.permission.can_publish_sources.to_a

    @client.update_participant(room: "room", identity: "speaker-7", can_publish: false)
    assert_empty @sdk.requests.last.last.permission.can_publish_sources.to_a
  end

  test "mute_track only mutes the specified participant track" do
    result = @client.mute_track(room: "room", identity: "viewer-42", track_sid: "TR_42")
    method, request = @sdk.requests.last
    assert_equal :MutePublishedTrack, method
    assert_equal [ "room", "viewer-42", "TR_42", true ], [ request.room, request.identity, request.track_sid, request.muted ]
    assert_equal "TR_42", result[:track][:sid]
    assert result[:track][:muted]
  end

  test "remove_participant returns a plain empty hash" do
    assert_equal({}, @client.remove_participant(room: "room", identity: "viewer-42"))
    method, request = @sdk.requests.last
    assert_equal :RemoveParticipant, method
    assert_equal [ "room", "viewer-42" ], [ request.room, request.identity ]
  end

  test "room metadata is JSON encoded exactly once" do
    result = @client.update_room_metadata(room: "room", metadata: { focus: "speaker-1", logos: [] })
    method, request = @sdk.requests.last
    assert_equal :UpdateRoomMetadata, method
    assert_equal "room", request.room
    assert_equal({ "focus" => "speaker-1", "logos" => [] }, JSON.parse(request.metadata))
    assert_equal request.metadata, result[:metadata]
  end

  test "create_room maps name positionally and encodes optional metadata" do
    result = @client.create_room(name: "room", empty_timeout: 600, metadata: { focus: "screen" })
    method, request = @sdk.requests.last
    assert_equal :CreateRoom, method
    assert_equal "room", request.name
    assert_equal 600, request.empty_timeout
    assert_equal({ "focus" => "screen" }, JSON.parse(request.metadata))
    assert_equal "room", result[:name]
  end

  test "create_room defaults preserve server timeout and metadata" do
    @client.create_room(name: "room")
    request = @sdk.requests.last.last
    assert_equal 0, request.empty_timeout
    assert_equal "", request.metadata
  end

  test "send_data sends binary payload reliably to selected identities" do
    assert_equal({}, @client.send_data(room: "room", data: "\xFF\x00".b, destination_identities: [ "viewer-42" ]))
    method, request = @sdk.requests.last
    assert_equal :SendData, method
    assert_equal "room", request.room
    assert_equal "\xFF\x00".b, request.data
    assert_equal :RELIABLE, request.kind
    assert_equal [ "viewer-42" ], request.destination_identities.to_a
  end

  test "send_data supports lossy broadcasts" do
    @client.send_data(room: "room", data: "message", kind: :lossy)
    request = @sdk.requests.last.last
    assert_equal :LOSSY, request.kind
    assert_empty request.destination_identities
  end

  test "list_participants décode les ParticipantInfo en Array<Hash>" do
    @sdk.participants_response = LiveKit::Proto::ListParticipantsResponse.new(
      participants: [
        LiveKit::Proto::ParticipantInfo.new(
          identity: "host-sub-marc", kind: :STANDARD,
          tracks: [ LiveKit::Proto::TrackInfo.new(sid: "TR_cam", source: :CAMERA) ]
        ),
        LiveKit::Proto::ParticipantInfo.new(identity: "EG_rec", kind: :EGRESS)
      ]
    )
    result = @client.list_participants(room: "room")
    method, request = @sdk.requests.last
    assert_equal :ListParticipants, method
    assert_equal "room", request.room
    assert_equal 2, result.size
    assert_equal "host-sub-marc", result[0][:identity]
    assert_equal "STANDARD", result[0][:kind]
    assert_equal "TR_cam", result[0][:tracks][0][:sid]
    assert_equal "CAMERA", result[0][:tracks][0][:source]
    assert_equal "EGRESS", result[1][:kind]
  end

  test "room_metadata lit les métadonnées de la salle demandée, et seulement elle" do
    @sdk.rooms_response = LiveKit::Proto::ListRoomsResponse.new(
      rooms: [ LiveKit::Proto::Room.new(name: "room", metadata: '{"spotlight":"speaker-1"}') ]
    )
    assert_equal '{"spotlight":"speaker-1"}', @client.room_metadata(room: "room")
    method, request = @sdk.requests.last
    assert_equal :ListRooms, method
    assert_equal [ "room" ], request.names.to_a
  end

  test "room_metadata : chaîne vide pour une salle sans métadonnées, nil pour une salle inconnue" do
    @sdk.rooms_response = LiveKit::Proto::ListRoomsResponse.new(rooms: [ LiveKit::Proto::Room.new(name: "room") ])
    assert_equal "", @client.room_metadata(room: "room")

    @sdk.rooms_response = LiveKit::Proto::ListRoomsResponse.new
    assert_nil @client.room_metadata(room: "room")
  end

  test "list_participants retourne un tableau vide quand la salle n'a pas de participant" do
    assert_equal [], @client.list_participants(room: "room")
    method, request = @sdk.requests.last
    assert_equal :ListParticipants, method
    assert_equal "room", request.room
  end

  # Dispatches du transcripteur nommé : protobuf construit par le SDK installé, sans HTTP.
  class CapturingDispatchSdk < LiveKit::AgentDispatchServiceClient
    attr_reader :requests
    attr_accessor :failure, :dispatches

    def initialize
      @requests = []
      @dispatches = []
      @api_key = "test-key"
      @api_secret = "test-secret"
    end

    def rpc!(method, request, **)
      @requests << [ method, request ]
      raise failure if failure

      case method
      when :CreateDispatch, :DeleteDispatch
        LiveKit::Proto::AgentDispatch.new(id: request.try(:dispatch_id).presence || "AD_new", room: request.room,
                                          agent_name: request.try(:agent_name).to_s)
      when :ListDispatch
        LiveKit::Proto::ListAgentDispatchResponse.new(agent_dispatches: dispatches)
      end
    end
  end

  test "dispatches d'agent : création nommée, liste avec état des jobs, suppression" do
    sdk = CapturingDispatchSdk.new
    client = RoomServiceClient.new(api_key: "test-key", api_secret: "test-secret", twirp_client: @sdk, dispatch_client: sdk)
    job = LiveKit::Proto::Job.new(id: "AJ_1", state: LiveKit::Proto::JobState.new(status: :JS_RUNNING, started_at: 7))
    sdk.dispatches = [ LiveKit::Proto::AgentDispatch.new(id: "AD_1", agent_name: "transcriber", room: "room",
                                                         state: LiveKit::Proto::AgentDispatchState.new(created_at: 5, jobs: [ job ])) ]

    assert_equal "transcriber", client.create_agent_dispatch(room: "room", agent_name: "transcriber")[:agent_name]
    listed = client.list_agent_dispatches(room: "room").sole
    client.delete_agent_dispatch(room: "room", dispatch_id: "AD_1")

    assert_equal [ "AD_1", "transcriber", "5", "JS_RUNNING", "7" ],
                 [ listed[:id], listed[:agent_name], listed.dig(:state, :created_at),
                   listed.dig(:state, :jobs, 0, :state, :status), listed.dig(:state, :jobs, 0, :state, :started_at) ]
    assert_equal %i[CreateDispatch ListDispatch DeleteDispatch], sdk.requests.map(&:first)
    assert_equal [ "room", "transcriber" ], [ sdk.requests.first.last.room, sdk.requests.first.last.agent_name ]
    assert_equal [ "room", "AD_1" ], [ sdk.requests.last.last.room, sdk.requests.last.last.dispatch_id ]
  end

  test "dispatches d'agent : refus LiveKit porté par son code, entrées vides refusées sans appel" do
    sdk = CapturingDispatchSdk.new
    client = RoomServiceClient.new(api_key: "test-key", api_secret: "test-secret", twirp_client: @sdk, dispatch_client: sdk)

    assert_raises(RoomServiceClient::Error) { client.create_agent_dispatch(room: "room", agent_name: "") }
    assert_raises(RoomServiceClient::Error) { client.delete_agent_dispatch(room: "", dispatch_id: "AD_1") }
    assert_empty sdk.requests

    sdk.failure = LiveKit::ServerError.new("not_found", "dispatch ID not found")
    error = assert_raises(RoomServiceClient::RemoteError) { client.delete_agent_dispatch(room: "room", dispatch_id: "AD_1") }
    assert_equal "not_found", error.code
  end

  test "errors_surface_loud with remote code and operation but no credentials" do
    @sdk.failure = LiveKit::ServerError.new("unauthenticated", "denied test-key test-secret")
    error = assert_raises(RoomServiceClient::RemoteError) { @client.remove_participant(room: "room", identity: "viewer-42") }
    assert_match "remove_participant", error.message
    assert_match "unauthenticated", error.message
    assert_equal "unauthenticated", error.code
    assert_match "denied", error.message
    assert_not_includes error.message, "test-key"
    assert_not_includes error.message, "test-secret"
    assert_nil error.cause
  end

  test "network and unexpected SDK errors remain observable adapter errors" do
    [ Errno::ECONNREFUSED.new, Faraday::TimeoutError.new("timed out"), RuntimeError.new("bad response") ].each do |failure|
      @sdk.failure = failure
      error = assert_raises(RoomServiceClient::Error) { @client.mute_track(room: "room", identity: "viewer", track_sid: "TR_1") }
      assert_match "mute_track", error.message
      assert_match failure.class.name, error.message
    end
  end

  test "missing_credentials prevents any SDK calls" do
    [ [ "", "secret" ], [ "key", "" ], [ " ", "secret" ] ].each do |key, secret|
      client = RoomServiceClient.new(api_key: key, api_secret: secret, twirp_client: @sdk)
      assert_raises(RoomServiceClient::MissingCredentials) { client.create_room(name: "room") }
    end
    assert_empty @sdk.requests
  end

  test "invalid inputs fail before any SDK mutation" do
    assert_raises(RoomServiceClient::Error) { @client.update_participant(room: "room", identity: "viewer", can_publish: "false") }
    assert_raises(RoomServiceClient::Error) { @client.remove_participant(room: "", identity: "viewer") }
    assert_raises(RoomServiceClient::Error) { @client.update_room_metadata(room: "room", metadata: "{}") }
    assert_raises(RoomServiceClient::Error) { @client.create_room(name: "room", empty_timeout: -1) }
    assert_raises(RoomServiceClient::Error) { @client.send_data(room: "room", data: {}, kind: :reliable) }
    assert_raises(RoomServiceClient::Error) { @client.send_data(room: "room", data: "x", kind: :unknown) }
    assert_raises(RoomServiceClient::Error) { @client.send_data(room: "room", data: "x", destination_identities: [ "" ]) }
    assert_empty @sdk.requests
  end

  test "factory reads credentials and default or configured host from environment" do
    original_constructor = LiveKit::RoomServiceClient.method(:new)
    previous = ENV.to_h.slice("LIVEKIT_HOST", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET")
    ENV["LIVEKIT_API_KEY"] = "environment-key"
    ENV["LIVEKIT_API_SECRET"] = "environment-secret"
    assertions = self
    sdk = @sdk
    [ nil, "http://configured.invalid:7880" ].each do |host|
      ENV["LIVEKIT_HOST"] = host
      constructor = lambda do |actual_host, api_key:, api_secret:|
        assertions.assert_equal(host || "http://livekit:7880", actual_host)
        assertions.assert_equal "environment-key", api_key
        assertions.assert_equal "environment-secret", api_secret
        sdk
      end
      LiveKit::RoomServiceClient.define_singleton_method(:new, constructor)
      client = Rails.configuration.x.room_service_client_factory.call
      assert_equal "room", client.create_room(name: "room")[:name]
    end
  ensure
    LiveKit::RoomServiceClient.define_singleton_method(:new, original_constructor)
    %w[LIVEKIT_HOST LIVEKIT_API_KEY LIVEKIT_API_SECRET].each { |key| ENV[key] = previous[key] }
  end
end
