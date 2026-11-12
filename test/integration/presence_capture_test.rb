require "test_helper"

# Tentatives vues par l'app, pour « est-ce que les gens ont essayé de se
# connecter ou pas » : page du café ou lien intervenant ouvert, accès à la
# salle délivré — sous l'identité LiveKit qui entrera, une fois par fenêtre.
class PresenceCaptureTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  setup do
    @host = User.create!(email: "host@example.test", oidc_sub: "host", admin: true)
    @webinar = Webinar.create!(title: "Café IA", starts_at: Time.current, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: Time.current,
                                                   participation_chosen_at: Time.current)
    @speaker = @webinar.speakers.create!(name: "Basile")
    @previous = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET")
    ENV["LIVEKIT_API_KEY"] = "APIfake"
    ENV["LIVEKIT_API_SECRET"] = "sekret-32bytes-long-enough-abcdef"
    # Le lien intervenant démarre l'enregistrement (RecordingSession) : ni
    # LiveKit ni egress réels ici.
    @previous_factories = Rails.configuration.x.then { |x| [ x.egress_client_factory, x.room_service_client_factory ] }
    egress = Object.new
    def egress.start_room_composite(**) = { egress_id: "EG_presence", status: :starting, raw: nil }
    def egress.list_egress(egress_id:) = { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    room = Object.new
    def room.create_room(**) = {}
    Rails.configuration.x.egress_client_factory = -> { egress }
    Rails.configuration.x.room_service_client_factory = -> { room }
  end

  teardown do
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET].each { |key| ENV[key] = @previous[key] }
    Rails.configuration.x.egress_client_factory, Rails.configuration.x.room_service_client_factory = @previous_factories
  end

  def journal
    @webinar.presence_events.chronological.pluck(:kind, :identity)
  end

  test "inscrit : page du café ouverte puis accès délivré, une fois même rechargés" do
    post confirm_registration_path(@registration.token)
    2.times do
      get public_webinar_path(slug: @webinar.slug)
      post "/api/token", params: { slug: @webinar.slug }, as: :json
    end

    assert_response :success
    identity = "viewer-#{@registration.id}"
    assert_equal [ [ "page_opened", identity ], [ "token_issued", identity ] ], journal
    assert_equal %w[app], @webinar.presence_events.distinct.pluck(:source)
  end

  test "inscrit venu avant le direct : la page ouverte est notée" do
    @webinar.update!(state: "draft", started_at: nil)
    post confirm_registration_path(@registration.token)

    get public_webinar_path(slug: @webinar.slug)

    assert_response :success
    assert_equal [ [ "page_opened", "viewer-#{@registration.id}" ] ], journal
  end

  test "animateur dont le navigateur porte une inscription : la page est ouverte en animation" do
    post confirm_registration_path(@registration.token)
    sign_in_as(@host)

    get public_webinar_path(slug: @webinar.slug)

    assert_equal [ [ "page_opened", "host-host" ] ], journal
  end

  test "animateur sans inscription sur la page publique : rien n'est noté" do
    sign_in_as(@host)

    get public_webinar_path(slug: @webinar.slug)

    assert_empty journal
  end

  test "visiteur inconnu ou accès refusé : rien n'est noté" do
    get public_webinar_path(slug: @webinar.slug)
    post "/api/token", params: { slug: @webinar.slug }, as: :json

    assert_response :forbidden
    assert_empty journal
  end

  test "lien intervenant : ouvert par l'intervenant, ou par l'animateur qui entrera en animation" do
    get join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    post "/api/token", params: { slug: @webinar.slug, speaker_token: @speaker.token }, as: :json
    assert_equal [ [ "page_opened", "speaker-#{@speaker.id}" ], [ "token_issued", "speaker-#{@speaker.id}" ] ], journal

    sign_in_as(@host)
    get join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    assert_equal [ "page_opened", "host-host" ], journal.last
  end

  test "journal indisponible : la page et le jeton sont servis quand même" do
    post confirm_registration_path(@registration.token)
    original = PresenceEvent.method(:record_attempt!)
    PresenceEvent.define_singleton_method(:record_attempt!) { |*, **| raise ActiveRecord::StatementInvalid, "database is locked" }

    begin
      get public_webinar_path(slug: @webinar.slug)
      assert_response :success
      post "/api/token", params: { slug: @webinar.slug }, as: :json
      assert_response :success
    ensure
      PresenceEvent.define_singleton_method(:record_attempt!, original)
    end
  end
end
