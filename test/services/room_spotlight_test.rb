require "test_helper"

class RoomSpotlightTest < ActiveSupport::TestCase
  class FakeRoom
    attr_reader :calls
    attr_accessor :error

    def initialize
      @calls = []
    end

    def update_room_metadata(room:, metadata:)
      @calls << { room: room, metadata: metadata }
      raise error if error

      {}
    end
  end

  # SDK twirp minimal : enregistre la requête que l'adaptateur réel
  # (RoomServiceClient) lui transmet, sans réseau.
  class RecordingSdk
    attr_reader :requests

    def initialize
      @requests = []
    end

    def update_room_metadata(room:, metadata:)
      @requests << metadata
      LiveKit::Proto::Room.new(name: room, metadata: metadata)
    end
  end

  setup do
    @webinar = Webinar.create!(title: "Café IA #7", starts_at: Time.current, host_sub: "sub-marc")
    @room = FakeRoom.new
    @spotlight = RoomSpotlight.new(@webinar, client: @room)
  end

  test "feature écrit l'identité dans les métadonnées de la salle du webinaire" do
    assert_equal "speaker-12", @spotlight.feature("speaker-12")
    assert_equal [ { room: @webinar.room_name, metadata: { spotlight: "speaker-12" } } ], @room.calls
  end

  test "clear écrit une mise en avant nulle" do
    assert_nil @spotlight.clear
    assert_equal [ { room: @webinar.room_name, metadata: { spotlight: nil } } ], @room.calls
  end

  test "les identités de scène émises par le serveur sont acceptées" do
    [ "host-3f2b9c1e-6d4a-4b8e-9a51-0c7d2e8f1a64", "speaker-7", "viewer-42" ].each do |identity|
      assert_equal identity, @spotlight.feature(identity)
    end
  end

  test "une identité d'agent, vide, mal formée ou non textuelle est refusée sans appel LiveKit" do
    [ "agent-AJ_testAgent001", "", "speaker-", "speaker-1 x", "viewer-1\n", "host-#{'a' * 201}",
      nil, [ "speaker-1" ], { "identity" => "speaker-1" } ].each do |identity|
      assert_raises(RoomSpotlight::InvalidIdentity, identity.inspect) { @spotlight.feature(identity) }
    end
    assert_empty @room.calls
  end

  test "un refus LiveKit remonte tel quel" do
    @room.error = RoomServiceClient::RemoteError.new("room update_room_metadata refusé (not_found)")
    assert_raises(RoomServiceClient::RemoteError) { @spotlight.feature("speaker-12") }
  end

  test "chaque changement accepté est horodaté pour le montage du replay, retrait compris" do
    travel_to Time.zone.parse("2026-11-10 08:40:00") do
      @spotlight.feature("speaker-12")
    end
    travel_to Time.zone.parse("2026-11-10 08:45:30") do
      @spotlight.clear
    end

    assert_equal [ [ "speaker-12", Time.zone.parse("2026-11-10 08:40:00") ], [ nil, Time.zone.parse("2026-11-10 08:45:30") ] ],
                 @webinar.spotlight_changes.chronological.pluck(:identity, :changed_at)
  end

  test "un changement refusé par LiveKit ou une identité invalide ne laisse aucune trace" do
    @room.error = RoomServiceClient::RemoteError.new("room update_room_metadata refusé (not_found)")
    assert_raises(RoomServiceClient::RemoteError) { @spotlight.feature("speaker-12") }
    assert_raises(RoomSpotlight::InvalidIdentity) { @spotlight.feature("agent-x") }

    assert_empty @webinar.spotlight_changes
  end

  # Contrat avec rooms/spotlight.jsx (parseSpotlight) : la chaîne que
  # LiveKit diffuse est exactement {"spotlight": <identité|null>}.
  test "la chaîne envoyée à LiveKit est le JSON lu par les clients" do
    sdk = RecordingSdk.new
    client = RoomServiceClient.new(api_key: "key", api_secret: "secret", twirp_client: sdk)
    spotlight = RoomSpotlight.new(@webinar, client: client)

    spotlight.feature("speaker-12")
    spotlight.clear

    assert_equal [ '{"spotlight":"speaker-12"}', '{"spotlight":null}' ], sdk.requests
  end

  test "identity_in relit l'identité écrite, et rien d'autre" do
    assert_equal "speaker-12", RoomSpotlight.identity_in('{"spotlight":"speaker-12"}')
    assert_nil RoomSpotlight.identity_in('{"spotlight":null}')
    assert_nil RoomSpotlight.identity_in("")
    assert_nil RoomSpotlight.identity_in(nil)
    assert_nil RoomSpotlight.identity_in("pas du json")
    assert_nil RoomSpotlight.identity_in('"speaker-12"')
    assert_nil RoomSpotlight.identity_in('{"spotlight":42}')
  end
end
