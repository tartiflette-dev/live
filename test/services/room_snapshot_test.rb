require "test_helper"

# Régie : lecture serveur de la salle, sans y entrer.
class RoomSnapshotTest < ActiveSupport::TestCase
  class FakeRoom
    attr_accessor :metadata, :participants, :error
    attr_reader :calls

    def initialize(metadata: "", participants: [])
      @metadata = metadata
      @participants = participants
      @calls = []
    end

    def room_metadata(room:)
      @calls << :room_metadata
      raise error if error

      metadata
    end

    def list_participants(room:)
      @calls << :list_participants
      raise error if error

      participants
    end
  end

  setup do
    @webinar = Webinar.create!(title: "Café IA #8", starts_at: Time.current, host_sub: "sub-marc")
  end

  def participant(identity, kind: "STANDARD", name: "", can_publish: false, sources: [])
    { identity: identity, kind: kind, name: name, permission: { can_publish: can_publish },
      tracks: sources.map { |source| { sid: "TR_#{source}", source: source } } }
  end

  test "compte les présents humains, liste qui est sur scène et lit la mise en avant" do
    room = FakeRoom.new(
      metadata: '{"spotlight":"speaker-7"}',
      participants: [
        participant("host-sub-marc", name: "Marc", can_publish: true, sources: %w[CAMERA MICROPHONE]),
        participant("speaker-7", name: "Basile", can_publish: true, sources: %w[CAMERA SCREEN_SHARE]),
        participant("viewer-3", name: "Ana"),
        participant("viewer-4", name: "Léa"),
        participant("agent-AJ_x", kind: "AGENT", can_publish: true),
        participant("EG_rec", kind: "EGRESS")
      ]
    )

    snapshot = RoomSnapshot.new(@webinar, client: room).call

    assert_equal "open", snapshot[:room]
    assert_equal 4, snapshot[:present]
    assert_equal "speaker-7", snapshot[:spotlight]
    assert_equal [
      { identity: "host-sub-marc", name: "Marc", camera: true, screen_share: false, awaiting_consent: false },
      { identity: "speaker-7", name: "Basile", camera: true, screen_share: true, awaiting_consent: false }
    ], snapshot[:on_stage]
  end

  test "caméra éteinte (publiée mais coupée) : pas de caméra sur scène" do
    room = FakeRoom.new(participants: [
      participant("speaker-7", name: "Basile", can_publish: true)
        .merge(tracks: [ { sid: "TR_cam", source: "CAMERA", muted: true } ]),
      participant("speaker-8", name: "Chloé", can_publish: true)
        .merge(tracks: [ { sid: "TR_cam2", source: "CAMERA", muted: false } ])
    ])

    on_stage = RoomSnapshot.new(@webinar, client: room).call[:on_stage]

    assert_equal [ [ "speaker-7", false ], [ "speaker-8", true ] ], on_stage.map { |person| person.values_at(:identity, :camera) }
  end

  # Sans accord à l'image, la salle ne laisse pas
  # publier un intervenant ni un co-animateur invité ; ils restent sur scène,
  # en attente d'accord, pour que l'animation les voie et puisse les mettre en
  # avant. Un spectateur sans publication n'y monte pas.
  test "intervenant et co-animateur sans accord : sur scène, en attente d'accord ; spectateur non" do
    room = FakeRoom.new(participants: [
      participant("speaker-8", name: "Mathilde"),
      participant("host-sub-camille", name: "Camille"),
      participant("viewer-3", name: "Ana")
    ])

    on_stage = RoomSnapshot.new(@webinar, client: room).call[:on_stage]

    assert_equal [ [ "speaker-8", true ], [ "host-sub-camille", true ] ],
                 on_stage.map { |person| person.values_at(:identity, :awaiting_consent) }
  end

  # La régie modère les intervenants et les
  # spectateurs présents, jamais l'animation ni les agents.
  test "participants modérables : intervenants et spectateurs présents, micro ouvert ou non" do
    room = FakeRoom.new(participants: [
      participant("host-sub-marc", name: "Marc", can_publish: true, sources: %w[MICROPHONE]),
      participant("speaker-7", name: "Basile", can_publish: true).merge(
        tracks: [ { sid: "TR_mic", type: "AUDIO", source: "MICROPHONE", muted: false } ]
      ),
      participant("viewer-3", name: "Ana", can_publish: true).merge(
        tracks: [ { sid: "TR_old", type: "AUDIO", source: "MICROPHONE", muted: true } ]
      ),
      participant("viewer-4"),
      participant("speaker-legacy-abc", name: "Ancien lien"),
      participant("agent-AJ_x", kind: "AGENT", can_publish: true)
    ])

    assert_equal [
      { identity: "speaker-7", name: "Basile", role: "speaker", microphone: true },
      { identity: "viewer-3", name: "Ana", role: "viewer", microphone: false },
      { identity: "viewer-4", name: "Spectateur", role: "viewer", microphone: false }
    ], RoomSnapshot.new(@webinar, client: room).call[:participants]
  end

  test "une personne sans nom affiché est nommée par son rôle, jamais par son identité" do
    room = FakeRoom.new(participants: [ participant("viewer-12", can_publish: true) ])

    assert_equal "Spectateur", RoomSnapshot.new(@webinar, client: room).call[:on_stage].first[:name]
  end

  test "salle inconnue de LiveKit : fermée, personne, sans lire les participants" do
    room = FakeRoom.new(metadata: nil)
    snapshot = RoomSnapshot.new(@webinar, client: room).call

    assert_equal({ room: "closed", present: 0, on_stage: [], participants: [], spotlight: nil }, snapshot)
    assert_equal [ :room_metadata ], room.calls
  end

  test "refus not_found : salle fermée" do
    room = FakeRoom.new
    room.error = RoomServiceClient::RemoteError.new("absente", code: "not_found")

    assert_equal "closed", RoomSnapshot.new(@webinar, client: room).call[:room]
  end

  test "LiveKit injoignable : salle illisible, sans nombre inventé" do
    room = FakeRoom.new
    room.error = RoomServiceClient::Error.new("connexion refusée")

    assert_equal({ room: "unavailable", present: nil, on_stage: [], participants: [], spotlight: nil },
                 RoomSnapshot.new(@webinar, client: room).call)
  end

  test "lecture en cache 3 s par webinaire, échec compris ; une écriture de la salle l'invalide" do
    with_memory_cache do
      room = FakeRoom.new(participants: [ participant("viewer-1") ])
      2.times { RoomSnapshot.new(@webinar, client: room).call }
      assert_equal %i[room_metadata list_participants], room.calls, "deux onglets, une seule lecture LiveKit"

      other = Webinar.create!(title: "Autre", starts_at: Time.current, host_sub: "sub-marc")
      RoomSnapshot.new(other, client: room).call
      assert_equal 4, room.calls.size, "le cache est propre à chaque webinaire"

      RoomSnapshot.expire(@webinar)
      room.participants = []
      assert_equal 0, RoomSnapshot.new(@webinar, client: room).call[:present]

      travel 4.seconds do
        room.error = RoomServiceClient::Error.new("connexion refusée")
        room.calls.clear
        2.times { assert_equal "unavailable", RoomSnapshot.new(@webinar, client: room).call[:room] }
        assert_equal [ :room_metadata ], room.calls, "un LiveKit injoignable n'est interrogé qu'une fois par période"
      end
    end
  end

  test "la mise en avant invalide la lecture en cache" do
    with_memory_cache do
      RoomSnapshot.new(@webinar, client: FakeRoom.new(metadata: "")).call
      writer = Class.new { def update_room_metadata(**) = {} }.new
      RoomSpotlight.new(@webinar, client: writer).feature("speaker-7")

      fresh = FakeRoom.new(metadata: '{"spotlight":"speaker-7"}')
      assert_equal "speaker-7", RoomSnapshot.new(@webinar, client: fresh).call[:spotlight]
    end
  end

  private

  def with_memory_cache
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous
  end
end
