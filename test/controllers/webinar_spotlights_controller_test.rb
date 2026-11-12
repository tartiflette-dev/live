require "test_helper"

# Mise en avant : seule l'animation écrit l'état
# diffusé. Chaque refus est vérifié SANS appel LiveKit.
class WebinarSpotlightsControllerTest < ActionDispatch::IntegrationTest
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

  setup do
    @owner = User.create!(email: "marc@example.test", oidc_sub: "sub-marc")
    @guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co", email_verified: true, email_verified_for: "co@partenaire.test")
    @stranger = User.create!(email: "autre@example.test", oidc_sub: "sub-autre")
    @webinar = Webinar.create!(title: "Café IA #7", starts_at: Time.current, host_sub: @owner.oidc_sub,
                               visibility: "published", state: "live")
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @speaker = @webinar.speakers.create!(name: "Basile Delmas")
    @room = FakeRoom.new
    @old_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @room }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @old_factory
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "le propriétaire met en avant puis retire : état écrit dans la salle du webinaire" do
    sign_in_as(@owner)

    post webinar_spotlight_path(@webinar), params: { identity: "speaker-#{@speaker.id}" }, as: :json
    assert_response :success
    assert_equal({ "spotlight" => "speaker-#{@speaker.id}" }, response.parsed_body)

    delete webinar_spotlight_path(@webinar), as: :json
    assert_response :success
    assert_equal({ "spotlight" => nil }, response.parsed_body)

    assert_equal [ { room: @webinar.room_name, metadata: { spotlight: "speaker-#{@speaker.id}" } },
                   { room: @webinar.room_name, metadata: { spotlight: nil } } ], @room.calls
  end

  test "un co-animateur invité peut mettre en avant (can_animate?)" do
    assert @webinar.can_animate?(@guest)
    sign_in_as(@guest, email_verified: true)

    post webinar_spotlight_path(@webinar), params: { identity: "host-#{@owner.oidc_sub}" }, as: :json
    assert_response :success
    assert_equal [ { room: @webinar.room_name, metadata: { spotlight: "host-#{@owner.oidc_sub}" } } ], @room.calls
  end

  test "anonyme : renvoyé vers la connexion, rien n'est écrit" do
    post webinar_spotlight_path(@webinar), params: { identity: "speaker-#{@speaker.id}" }, as: :json
    assert_redirected_to sign_in_path
    delete webinar_spotlight_path(@webinar), as: :json
    assert_redirected_to sign_in_path
    assert_empty @room.calls
  end

  test "utilisateur connecté sans rôle sur ce webinaire : 404, rien n'est écrit" do
    sign_in_as(@stranger)
    post webinar_spotlight_path(@webinar), params: { identity: "speaker-#{@speaker.id}" }, as: :json
    assert_response :not_found
    delete webinar_spotlight_path(@webinar), as: :json
    assert_response :not_found
    assert_empty @room.calls
  end

  test "un intervenant (lien t) ou un spectateur inscrit ne peut rien changer" do
    post webinar_spotlight_path(@webinar, t: @speaker.token), params: { identity: "speaker-#{@speaker.id}" }, as: :json
    assert_redirected_to sign_in_path

    registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: Time.current)
    post confirm_registration_path(registration.token)
    post webinar_spotlight_path(@webinar), params: { identity: "viewer-#{registration.id}" }, as: :json
    assert_redirected_to sign_in_path
    delete webinar_spotlight_path(@webinar), as: :json
    assert_redirected_to sign_in_path

    assert_empty @room.calls
  end

  test "identité refusée : 422 sans appel LiveKit" do
    sign_in_as(@owner)
    post webinar_spotlight_path(@webinar), params: { identity: "agent-AJ_testAgent001" }, as: :json
    assert_response :unprocessable_entity
    assert_equal({ "error" => "invalid_identity" }, response.parsed_body)
    post webinar_spotlight_path(@webinar), as: :json
    assert_response :unprocessable_entity
    assert_empty @room.calls
  end

  test "LiveKit injoignable : 502 explicite" do
    sign_in_as(@owner)
    @room.error = RoomServiceClient::Error.new("room update_room_metadata échoué (Faraday::ConnectionFailed)")
    post webinar_spotlight_path(@webinar), params: { identity: "speaker-#{@speaker.id}" }, as: :json
    assert_response :bad_gateway
    assert_equal({ "error" => "spotlight_update_failed" }, response.parsed_body)
  end

  private

  def sign_in_as(user, email_verified: false)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub,
      info: { email: user.email, email_verified: email_verified },
      extra: { raw_info: { email_verified: email_verified } }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    get "/auth/pocket_id/callback"
    Rails.application.env_config.delete("omniauth.auth")
  end
end
