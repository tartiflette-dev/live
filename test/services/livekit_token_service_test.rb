# frozen_string_literal: true

require "test_helper"
require "jwt"

# LivekitTokenService.
#
# Les done_when de la spec exigent que les grants soient assertés sur le
# JWT décodé (jamais sur les attributs internes du service). On décode donc
# le token avec la même clé factice et on vérifie la structure `video`
# (contrat LiveKit — cf. https://docs.livekit.io/home/get-started/authentication/).
class LivekitTokenServiceTest < ActiveSupport::TestCase
  FAKE_KEY = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @prev_key = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_KEY"] = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
  end

  teardown do
    ENV["LIVEKIT_API_KEY"] = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
  end

  # done_when : "Token viewer sans grant canPublish"
  test "viewer_token_cannot_publish" do
    jwt = LivekitTokenService.new(
      room: "webinaire-alpha",
      identity: "viewer-abc",
      role: :viewer
    ).call

    payload = decode(jwt)
    video = payload.fetch("video")

    assert_equal "webinaire-alpha", video["room"]
    assert_equal true, video["canSubscribe"]
    # « sans grant canPublish » = false ou absent. Ici on émet
    # explicitement `false` — on assert les deux formes pour rester
    # robuste si le SDK change son sérialisation des `false`.
    refute video["canPublish"], "viewer must not have canPublish (got #{video['canPublish'].inspect})"
    refute video["roomAdmin"], "viewer must not have roomAdmin"
    refute video["canUpdateOwnMetadata"], "viewer must not update its own metadata"
  end

  # Seul le serveur publie sur le data channel (chat, Q&R, sondages via
  # RoomService SendData). Chez LiveKit, une clé ABSENTE vaut true — d'où
  # l'égalité stricte, pour CHAQUE rôle humain.
  LivekitTokenService::ROLES.each do |role|
    test "#{role} token cannot publish data" do
      video = decode(LivekitTokenService.new(room: "webinaire-alpha", identity: "#{role}-abc", role: role).call).fetch("video")

      assert_equal false, video["canPublishData"]
    end
  end

  test "droit de publier donné par l'appelant : il remplace celui du rôle, sources limitées comprises" do
    closed = decode(LivekitTokenService.new(room: "r", identity: "speaker-7", role: :speaker, can_publish: false).call).fetch("video")
    assert_equal false, closed["canPublish"]
    assert_nil closed["canPublishSources"]

    opened = decode(LivekitTokenService.new(room: "r", identity: "viewer-7", role: :viewer, can_publish: true,
                                            publish_sources: PublishPermission::SOURCES).call).fetch("video")
    assert_equal true, opened["canPublish"]
    assert_equal %w[camera microphone screen_share screen_share_audio], opened["canPublishSources"]
  end

  # done_when : "Token host avec canPublish + roomAdmin"
  test "host_token_grants" do
    jwt = LivekitTokenService.new(
      room: "webinaire-alpha",
      identity: "host-marc",
      role: :host,
      name: "Marc"
    ).call

    payload = decode(jwt)
    video = payload.fetch("video")

    assert_equal "webinaire-alpha", video["room"]
    assert_equal true, video["canPublish"]
    assert_equal true, video["canSubscribe"]
    assert_equal true, video["roomAdmin"]
    assert_equal true, video["canUpdateOwnMetadata"]
    # `name` remonte dans les claims au top-level (SDK), pas sous `video`.
    assert_equal "Marc", payload["name"]
    assert_equal "host-marc", payload["sub"]
  end

  # done_when : "Token intervenant avec canPublish sans roomAdmin"
  test "speaker_token_grants" do
    jwt = LivekitTokenService.new(
      room: "webinaire-alpha",
      identity: "speaker-1",
      role: :speaker
    ).call

    payload = decode(jwt)
    video = payload.fetch("video")

    assert_equal "webinaire-alpha", video["room"]
    assert_equal true, video["canPublish"]
    assert_equal true, video["canSubscribe"]
    assert_equal true, video["canUpdateOwnMetadata"], "speaker must be able to set its display name (PreJoin)"
    # Distinctif face au host : roomAdmin doit être faux/absent.
    refute video["roomAdmin"], "speaker must not have roomAdmin"
  end

  # Garde-fou : un rôle inconnu doit péter tôt (à l'init), pas produire
  # un JWT vide qui ferait planter le client silencieusement.
  test "unknown_role_raises" do
    assert_raises(LivekitTokenService::UnknownRole) do
      LivekitTokenService.new(
        room: "r",
        identity: "i",
        role: :moderator
      )
    end
  end

  # Garde-fou : absence de clés = erreur à l'émission, pas au boot.
  test "missing_credentials_raises_on_call" do
    ENV["LIVEKIT_API_KEY"] = nil
    ENV["LIVEKIT_API_SECRET"] = nil

    svc = LivekitTokenService.new(
      room: "r",
      identity: "i",
      role: :viewer
    )
    assert_raises(LivekitTokenService::MissingCredentials) { svc.call }
  end

  # Le TTL par défaut est court (jamais de JWT figé longtemps dans un
  # favori) : 4h max.
  test "default_ttl_is_short" do
    jwt = LivekitTokenService.new(
      room: "r",
      identity: "i",
      role: :viewer
    ).call

    payload = decode(jwt)
    lifetime = payload["exp"].to_i - payload["nbf"].to_i
    # nbf = now - 5s, exp = now + ttl, donc lifetime = ttl + 5s.
    assert_operator lifetime, :<=, 4 * 3600 + 10
    assert_operator lifetime, :>=, 4 * 3600 - 10
  end

  # Défense stale-authorization : le TTL du
  # jeton :cohost est COURT (15 min) pour que le droit d'un co-animateur
  # retiré expire rapidement côté LiveKit même sans intervention du
  # webhook participant_joined (double garde).
  test "cohost_default_ttl_is_15_minutes" do
    jwt = LivekitTokenService.new(room: "r", identity: "i", role: :cohost).call
    payload = decode(jwt)
    lifetime = payload["exp"].to_i - payload["nbf"].to_i
    assert_operator lifetime, :<=, 15 * 60 + 10
    assert_operator lifetime, :>=, 15 * 60 - 10
  end

  # Lien participants : accord à l'image et parole
  # se retirent en cours de direct ; un jeton qui publie hors animation de
  # droit ne doit pas les rendre pendant 4 h.
  test "a_token_that_publishes_outside_the_hosts_gets_the_short_ttl" do
    lifetime = ->(role, can_publish) do
      payload = decode(LivekitTokenService.new(room: "r", identity: "i", role: role, can_publish: can_publish).call)
      payload["exp"].to_i - payload["nbf"].to_i
    end

    assert_operator lifetime.call(:viewer, true), :<=, LivekitTokenService::COHOST_TTL + 10
    assert_operator lifetime.call(:speaker, true), :<=, LivekitTokenService::COHOST_TTL + 10
    assert_operator lifetime.call(:viewer, false), :>=, LivekitTokenService::DEFAULT_TTL - 10
    assert_operator lifetime.call(:speaker, false), :>=, LivekitTokenService::DEFAULT_TTL - 10
    assert_operator lifetime.call(:host, true), :>=, LivekitTokenService::DEFAULT_TTL - 10
  end

  test "host_default_ttl_reste_long" do
    jwt = LivekitTokenService.new(room: "r", identity: "i", role: :host).call
    payload = decode(jwt)
    lifetime = payload["exp"].to_i - payload["nbf"].to_i
    assert_operator lifetime, :>=, 4 * 3600 - 10
  end

  private

  def decode(jwt)
    # verify: true — on VÉRIFIE la signature avec la clé factice pour
    # s'assurer que le service signe bien avec `LIVEKIT_API_SECRET`.
    JWT.decode(jwt, FAKE_SECRET, true, algorithm: "HS256").first
  end
end
