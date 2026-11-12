# frozen_string_literal: true

require "test_helper"

# EgressClient. Client egress MOCKÉ (contrat YAML).
# On n'atteint JAMAIS un vrai livekit-server dans ces tests : l'intégration
# réelle est validée sur l'hôte de production par un test d'isolation de l'egress,
# au déploiement.
#
# On assert :
#   • le start renvoie egress_id + status normalisé (symbole lisible)
#   • le stop renvoie même contrat
#   • une erreur Twirp est ré-émise en RemoteError (fail-loud, invariant spec)
#   • une panne réseau est ré-émise en RemoteError
#   • absence de creds → MissingCredentials (jamais un appel silencieux)
class EgressClientTest < ActiveSupport::TestCase
  # Duck-type minimal qui imite `LiveKit::EgressServiceClient` — on
  # n'hérite PAS de la vraie classe pour éviter d'ouvrir une connexion
  # Faraday inutile.
  class StubTwirp
    def initialize(start: nil, stop: nil)
      @start = start
      @stop  = stop
      @calls = []
    end

    attr_reader :calls

    def start_room_composite_egress(room_name, output, layout: nil)
      @calls << [ :start, room_name, output, layout ]
      raise @start if @start.is_a?(Exception)
      @start || FakeInfo.new(egress_id: "EG_stub_start", status: :EGRESS_STARTING)
    end

    def start_track_egress(room_name, output, track_id)
      @calls << [ :track, room_name, output, track_id ]
      raise @start if @start.is_a?(Exception)
      @start || FakeInfo.new(egress_id: "EG_track", status: :EGRESS_STARTING)
    end

    def stop_egress(egress_id)
      @calls << [ :stop, egress_id ]
      raise @stop if @stop.is_a?(Exception)
      @stop || FakeInfo.new(egress_id: egress_id, status: :EGRESS_ENDING)
    end
  end

  class CapturingSDK < LiveKit::EgressServiceClient
    attr_reader :request, :rpc_method

    def rpc!(method, request, **)
      @rpc_method = method
      @request = request
      LiveKit::Proto::EgressInfo.new(egress_id: "EG_wire", status: :EGRESS_STARTING)
    end
  end

  # `ended_at` et `error` ajoutés :
  # `normalize` les lit désormais pour la réconciliation. Nil par défaut,
  # les tests n'ont pas besoin de les positionner explicitement.
  FakeInfo = Struct.new(:egress_id, :status, :ended_at, :error, keyword_init: true)

  FakeListResponse = Struct.new(:items, keyword_init: true)

  test "list_egress: not_found côté twirp → nil (egress introuvable, jamais RemoteError)" do
    # Sondé sur un serveur réel : livekit répond `twirp error unknown:
    # egress does not exist` avec code `not_found` lorsqu'on interroge
    # un egress_id GC'd. On veut nil (→ Recording marqué failed avec
    # message explicite côté reconcile), PAS de RemoteError qui ferait
    # tomber reconcile en fail-safe (Recording laissé en l'état).
    twirp = Object.new
    twirp.define_singleton_method(:list_egress) do |egress_id:|
      raise LiveKit::ServerError.new("not_found", "egress does not exist")
    end
    client = EgressClient.new(twirp_client: twirp,
                              api_key: "APIfake", api_secret: "sekretsekretsekretsekretsekretsekret")
    result = client.list_egress(egress_id: "EG_gone")
    assert_nil result, "twirp not_found doit être traduit en nil (egress introuvable)"
  end

  test "list_egress: items vide → nil" do
    twirp = Object.new
    twirp.define_singleton_method(:list_egress) do |egress_id:|
      FakeListResponse.new(items: [])
    end
    client = EgressClient.new(twirp_client: twirp,
                              api_key: "APIfake", api_secret: "sekretsekretsekretsekretsekretsekret")
    assert_nil client.list_egress(egress_id: "EG_missing")
  end

  test "list_egress: item présent → normalize (status/ended_at/error exposés)" do
    info = FakeInfo.new(egress_id: "EG_1", status: :EGRESS_COMPLETE, ended_at: 42, error: "Source closed")
    twirp = Object.new
    twirp.define_singleton_method(:list_egress) do |egress_id:|
      FakeListResponse.new(items: [ info ])
    end
    client = EgressClient.new(twirp_client: twirp,
                              api_key: "APIfake", api_secret: "sekretsekretsekretsekretsekretsekret")
    result = client.list_egress(egress_id: "EG_1")
    assert_equal :complete, result[:status]
    assert_equal 42, result[:ended_at]
    assert_equal "Source closed", result[:error]
  end

  setup do
    @prev_key    = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_KEY"]    = "APIfake"
    ENV["LIVEKIT_API_SECRET"] = "sekret-32bytes-long-enough-abcdef"
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
  end

  # ---- Contrat start ----

  test "start_room_composite passes room + filepath to twirp and normalizes result" do
    twirp  = StubTwirp.new(start: FakeInfo.new(egress_id: "EG_123", status: :EGRESS_STARTING))
    client = EgressClient.new(twirp_client: twirp)

    result = client.start_room_composite(room_name: "webinaire-alpha",
                                          filepath:  "/data/webinaire-alpha/x.mp4")

    assert_equal "EG_123", result[:egress_id]
    assert_equal :starting, result[:status]
    assert_equal 1, twirp.calls.size

    kind, room, output, layout = twirp.calls.first
    assert_equal :start, kind
    assert_equal "webinaire-alpha", room
    assert_kind_of LiveKit::Proto::EncodedFileOutput, output
    assert_equal "/data/webinaire-alpha/x.mp4", output.filepath
    # file_type MP4 = 1 (cf. livekit_egress_pb.rb EncodedFileType).
    assert_equal :MP4, output.file_type
    # Layout composite explicite (jamais le défaut `grid` du template :
    # partage d'écran illisible en replay) — validé de bout en bout.
    assert_equal "speaker", layout
    assert_equal EgressClient::COMPOSITE_LAYOUT, layout
  end

  test "start_room_composite raises RemoteError on LiveKit::ServerError (fail-loud)" do
    # Le SDK LiveKit lève ServerError (StandardError) via `rpc!` — jamais
    # Twirp::Error direct côté appelant. Notre adaptateur ré-émet en
    # RemoteError avec code + message conservés (invariant fail-loud).
    twirp  = StubTwirp.new(start: LiveKit::ServerError.new("internal", "nope"))
    client = EgressClient.new(twirp_client: twirp)

    err = assert_raises(EgressClient::RemoteError) do
      client.start_room_composite(room_name: "r", filepath: "/data/r/x.mp4")
    end
    assert_match(/nope/,     err.message)
    assert_match(/internal/, err.message)
  end

  test "start_room_composite raises RemoteError on network failure" do
    twirp  = StubTwirp.new(start: Errno::ECONNREFUSED.new("livekit down"))
    client = EgressClient.new(twirp_client: twirp)

    err = assert_raises(EgressClient::RemoteError) do
      client.start_room_composite(room_name: "r", filepath: "/data/r/x.mp4")
    end
    assert_match(/injoignable/, err.message)
  end

  test "disabled egress refuses both starts and stops before RPC" do
    previous = ENV["EGRESS_ENABLED"]
    ENV["EGRESS_ENABLED"] = "false"
    twirp = StubTwirp.new
    client = EgressClient.new(twirp_client: twirp)
    error = assert_raises(EgressClient::Error) do
      client.start_room_composite(room_name: "staging-demo", filepath: "/data/demo/x.mp4")
    end
    assert_includes error.message, "désactivé"
    assert_raises(EgressClient::Error) do
      client.start_track_egress(room_name: "staging-demo", track_id: "TR_staging", filepath: "/data/demo/native")
    end
    assert_raises(EgressClient::Error) { client.stop(egress_id: "EG_production") }
    assert_empty twirp.calls
  ensure
    ENV["EGRESS_ENABLED"] = previous
  end

  test "start_track_egress forwards DirectFileOutput and preserves normalized response" do
    info = FakeInfo.new(egress_id: "EG_track", status: :EGRESS_STARTING)
    twirp = StubTwirp.new(start: info)
    result = EgressClient.new(twirp_client: twirp).start_track_egress(
      room_name: "webinar", track_id: "TR_camera", filepath: "/data/webinar/speaker-camera-unique"
    )
    # ended_at et error nils sur un egress qui vient de démarrer (fix/
    # room-recording-join-and-reconcile — normalize enrichit le hash).
    assert_equal({ egress_id: "EG_track", status: :starting, ended_at: nil, error: nil, raw: info, files: [] }, result)
    operation, room, output, track = twirp.calls.fetch(0)
    assert_equal :track, operation
    assert_equal "webinar", room
    assert_equal "TR_camera", track
    assert_kind_of LiveKit::Proto::DirectFileOutput, output
    assert_equal "/data/webinar/speaker-camera-unique", output.filepath
  end

  test "real SDK builds TrackEgressRequest for native file output" do
    sdk = CapturingSDK.new("http://livekit.invalid", api_key: "fake", api_secret: "fake")
    result = EgressClient.new(twirp_client: sdk).start_track_egress(
      room_name: "room", track_id: "TR_native", filepath: "/data/room/native"
    )
    assert_equal "EG_wire", result[:egress_id]
    assert_equal :StartTrackEgress, sdk.rpc_method
    assert_kind_of LiveKit::Proto::TrackEgressRequest, sdk.request
    assert_equal "TR_native", sdk.request.track_id
    assert_equal "room", sdk.request.room_name
    assert_equal "/data/room/native", sdk.request.file.filepath
    assert_equal "", sdk.request.websocket_url
  end

  test "track failures preserve remote errors and refuse missing credentials" do
    [ LiveKit::ServerError.new("not_found", "track gone"), Faraday::TimeoutError.new("timeout") ].each do |failure|
      client = EgressClient.new(twirp_client: StubTwirp.new(start: failure))
      assert_raises(EgressClient::RemoteError) do
        client.start_track_egress(room_name: "r", track_id: "TR_x", filepath: "/data/r/track")
      end
    end
    twirp = StubTwirp.new
    client = EgressClient.new(api_key: "", twirp_client: twirp)
    assert_raises(EgressClient::MissingCredentials) do
      client.start_track_egress(room_name: "r", track_id: "TR_x", filepath: "/data/r/track")
    end
    assert_empty twirp.calls
  end

  test "track output refuses traversal and paths outside mount before RPC" do
    twirp = StubTwirp.new
    client = EgressClient.new(twirp_client: twirp)
    [ "/etc/file", "/data/r/../../file", "/data/r/file/extra", "/data/r/file%2f", "" ].each do |filepath|
      assert_raises(ArgumentError) do
        client.start_track_egress(room_name: "r", track_id: "TR_x", filepath: filepath)
      end
    end
    assert_empty twirp.calls
  end

  # ---- Contrat stop ----

  test "staging rejects production media even when recording is enabled" do
    previous = ENV.to_h.slice("APP_HOST", "EGRESS_ENABLED", "STAGING_HOSTS")
    ENV["EGRESS_ENABLED"] = "true"
    ENV["STAGING_HOSTS"] = "edge.live.example.org,old-edge.live.example.org"
    # Nom canonique ET ancien nom resté servi : la garde vaut pour les deux.
    %w[edge.live.example.org old-edge.live.example.org].each do |staging_host|
      ENV["APP_HOST"] = staging_host
      twirp = StubTwirp.new
      client = EgressClient.new(host: "http://livekit:7880", twirp_client: twirp)
      assert_raises(EgressClient::Error, staging_host) { client.stop(egress_id: "EG_production") }
      assert_raises(EgressClient::Error, staging_host) do
        client.start_room_composite(room_name: "demo", filepath: "/data/demo/test.mp4")
      end
      assert_empty twirp.calls, staging_host

      isolated = EgressClient.new(host: "http://livekit-staging:7880", twirp_client: twirp)
      assert_equal "EG_stub_start", isolated.start_room_composite(room_name: "staging-demo", filepath: "/data/demo/test.mp4")[:egress_id]
    end
  ensure
    %w[APP_HOST EGRESS_ENABLED STAGING_HOSTS].each { |name| ENV[name] = previous[name] }
  end

  test "stop calls twirp with egress_id and normalizes status" do
    twirp  = StubTwirp.new(stop: FakeInfo.new(egress_id: "EG_42", status: :EGRESS_ENDING))
    client = EgressClient.new(twirp_client: twirp)

    result = client.stop(egress_id: "EG_42")
    assert_equal "EG_42",   result[:egress_id]
    assert_equal :ending,   result[:status]
    assert_equal [ [ :stop, "EG_42" ] ], twirp.calls
  end

  test "stop raises ArgumentError on empty egress_id (never a silent no-op)" do
    client = EgressClient.new(twirp_client: StubTwirp.new)
    assert_raises(ArgumentError) { client.stop(egress_id: "") }
    assert_raises(ArgumentError) { client.stop(egress_id: nil) }
  end

  test "stop raises RemoteError on ServerError not_found (fail-loud, jamais silencieux)" do
    twirp  = StubTwirp.new(stop: LiveKit::ServerError.new("not_found", "unknown egress"))
    client = EgressClient.new(twirp_client: twirp)
    err = assert_raises(EgressClient::RemoteError) { client.stop(egress_id: "EG_x") }
    assert_match(/not_found/, err.message)
  end

  test "all egress operations redact credentials and discard the original exception" do
    key = "API-private-key"
    secret = "private-egress-secret"
    operations = {
      start_room_composite: { room_name: "room", filepath: "/data/room/composite.mp4" },
      start_track_egress: { room_name: "room", track_id: "TR_native", filepath: "/data/room/native" },
      stop: { egress_id: "EG_native" }
    }
    operations.each do |operation, arguments|
      [ LiveKit::ServerError.new("denied", "#{key} #{secret}"), Faraday::ConnectionFailed.new("#{key} #{secret}") ].each do |failure|
        client = EgressClient.new(api_key: key, api_secret: secret, twirp_client: StubTwirp.new(start: failure, stop: failure))
        error = assert_raises(EgressClient::RemoteError) { client.public_send(operation, **arguments) }
        assert_nil error.cause
        assert_includes error.message, "[FILTERED]"
        assert_not_includes error.full_message, key
        assert_not_includes error.full_message, secret
      end
    end
  end

  # ---- Credentials ----

  test "missing credentials raises MissingCredentials (jamais un call vide)" do
    ENV["LIVEKIT_API_KEY"] = nil
    client = EgressClient.new(twirp_client: StubTwirp.new)

    assert_raises(EgressClient::MissingCredentials) do
      client.start_room_composite(room_name: "r", filepath: "/data/r/x.mp4")
    end
  end
end
