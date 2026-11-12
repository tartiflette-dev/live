require "test_helper"

class HandRaisesControllerTest < ActionDispatch::IntegrationTest
  class SimulatedCrash < Exception; end
  class FakeRoom
    attr_accessor :error
    attr_reader :calls
    def initialize
      @calls = []
    end
    def update_participant(**arguments)
      @calls << arguments
      raise error if error
      {}
    end

    # « Terminer le direct » cherche le transcripteur dans la salle.
    def list_participants(room:)
      []
    end

    def list_agent_dispatches(room:)
      []
    end
  end

  setup do
    @host = User.create!(email: "host@example.test", oidc_sub: "host", admin: true)
    @other_host = User.create!(email: "other@example.test", oidc_sub: "other")
    @webinar = Webinar.create!(title: "Live", starts_at: Time.current, host_sub: @host.oidc_sub,
      visibility: "published", state: "live")
    @registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: Time.current)
    # Accord à l'image déjà donné : la parole accordée ouvre la publication
    # (sans lui, voir « parole donnée sans accord »).
    ParticipantConsent.grant!(@registration, recording: true, excerpts: false, adult: true)
    @client = FakeRoom.new
    @old_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @client }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @old_factory
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "raising requires scoped confirmed registration and ignores forged identity" do
    post public_hand_raises_path(@webinar.slug), as: :json
    assert_response :forbidden
    post confirm_registration_path(@registration.token)
    assert_difference "HandRaise.count", 1 do
      post public_hand_raises_path(@webinar.slug), params: { registration_id: 999, state: "granted" }, as: :json
    end
    assert_response :created
    assert_equal @registration.id, response.parsed_body.fetch("registration_id")
    assert_equal "waiting", response.parsed_body.fetch("state")
    assert_no_difference "HandRaise.count" do
      post public_hand_raises_path(@webinar.slug), as: :json
    end
    other = Webinar.create!(title: "Other", starts_at: Time.current, host_sub: @host.oidc_sub, visibility: "published", state: "live")
    post public_hand_raises_path(other.slug), as: :json
    assert_response :forbidden
    assert_empty @client.calls
  end

  test "viewer reads only their own active hand without creating one" do
    get public_hand_raises_path(@webinar.slug), as: :json
    assert_response :forbidden
    post confirm_registration_path(@registration.token)
    assert_no_difference "HandRaise.count" do
      get public_hand_raises_path(@webinar.slug), as: :json
      assert_response :success
      assert_nil response.parsed_body.fetch("hand_raise")
    end
    hand = raise_hand
    hand.update!(state: "uncertain", last_error: "RoomServiceClient::Error")
    other_registration = @webinar.registrations.create!(name: "Other private", email: "other@example.test", confirmed_at: Time.current)
    HandRaiseControl.new(@webinar).raise_hand(other_registration)
    assert_no_difference "HandRaise.count" do
      get public_hand_raises_path(@webinar.slug), params: { registration_id: other_registration.id }, as: :json
    end
    assert_equal hand.id, response.parsed_body.fetch("hand_raise").fetch("id")
    assert_equal "uncertain", response.parsed_body.fetch("hand_raise").fetch("state")
    refute_includes response.body, "Other private"
    get webinar_hand_raises_path(@webinar), as: :json
    assert_response :redirect
    other_webinar = Webinar.create!(title: "Other", starts_at: Time.current, host_sub: @host.oidc_sub, visibility: "published")
    get public_hand_raises_path(other_webinar.slug), as: :json
    assert_response :forbidden
    assert_empty @client.calls
  end

  test "grant and revoke use server identity and preserve honest timestamps" do
    hand = raise_hand
    sign_in_as(@host)
    post grant_webinar_hand_raise_path(@webinar, hand), params: { identity: "host-other" }, as: :json
    assert_response :success
    assert_equal({ room: @webinar.room_name, identity: "viewer-#{@registration.id}", can_publish: true,
                   sources: PublishPermission::SOURCES }, @client.calls.last)
    assert hand.reload.granted_at
    assert_equal "granted", hand.state
    # Ré-accorder une main accordée repousse la permission (participant
    # revenu avec un jeton émis avant l'accord).
    post grant_webinar_hand_raise_path(@webinar, hand), as: :json
    assert_response :success
    assert_equal 2, @client.calls.size
    assert_equal true, @client.calls.last.fetch(:can_publish)
    assert_equal "granted", hand.reload.state
    get webinar_hand_raises_path(@webinar), as: :json
    assert_equal "Alice", response.parsed_body.first.fetch("name")
    refute_includes response.body, @registration.email
    refute_includes response.body, @registration.token
    post revoke_webinar_hand_raise_path(@webinar, hand), as: :json
    assert_response :success
    assert_equal false, @client.calls.last.fetch(:can_publish)
    assert hand.reload.revoked_at
    assert_equal "revoked", hand.state
  end

  test "parole donnée sans accord à l'image : main accordée, rien d'ouvert côté LiveKit ; l'accord l'ouvre" do
    ParticipantConsent.current_for(@registration).withdraw!
    hand = raise_hand
    sign_in_as(@host)

    post grant_webinar_hand_raise_path(@webinar, hand), as: :json

    assert_response :success
    assert_equal "granted", hand.reload.state
    assert_empty @client.calls, "la parole accordée n'ouvre pas la publication sans accord"

    ParticipantConsent.grant!(@registration, recording: true, excerpts: false, adult: true)
    assert PublishPermission.new(@webinar, client: @client).open!(@registration)
    assert_equal [ true, PublishPermission::SOURCES ], @client.calls.last.values_at(:can_publish, :sources)
  end

  # La régie signale l'inscrit « participant », qui veut
  # intervenir en vidéo, parmi les mains levées.
  test "la file signale qui s'est inscrit pour intervenir en vidéo" do
    raise_hand
    sign_in_as(@host)

    get webinar_hand_raises_path(@webinar), as: :json
    assert_equal false, response.parsed_body.sole.fetch("wants_video")

    @registration.update!(participation: "participant")
    get webinar_hand_raises_path(@webinar), as: :json
    assert_equal true, response.parsed_body.sole.fetch("wants_video")
  end

  test "another host cannot inspect or mutate the hand" do
    hand = raise_hand
    sign_in_as(@other_host)
    get webinar_hand_raises_path(@webinar), as: :json
    assert_response :not_found
    post grant_webinar_hand_raise_path(@webinar, hand), as: :json
    assert_response :not_found
    assert_empty @client.calls
  end

  test "participant can lower a granted hand and cannot lower others" do
    hand = raise_hand
    other_registration = @webinar.registrations.create!(name: "Other", email: "other@example.test", confirmed_at: Time.current)
    other_hand = HandRaiseControl.new(@webinar, client: @client).raise_hand(other_registration)
    HandRaiseControl.new(@webinar, client: @client).grant(hand.id)
    delete public_hand_raises_path(@webinar.slug), params: { registration_id: other_registration.id }, as: :json
    assert_response :no_content
    assert_equal false, @client.calls.last.fetch(:can_publish)
    assert_equal "revoked", hand.reload.state
    assert_equal "waiting", other_hand.reload.state
  end

  test "SDK refusal and disconnect return 502 without a false grant or revoke" do
    hand = raise_hand
    sign_in_as(@host)
    @client.error = RoomServiceClient::RemoteError.new("participant disconnected")
    post grant_webinar_hand_raise_path(@webinar, hand), as: :json
    assert_response :bad_gateway
    assert_equal "permission_update_failed", response.parsed_body.fetch("error")
    assert_nil hand.reload.granted_at
    assert_equal "uncertain", hand.state
    @client.error = nil
    post grant_webinar_hand_raise_path(@webinar, hand), as: :json
    assert_response :success
    @client.error = RoomServiceClient::Error.new("network timeout")
    post revoke_webinar_hand_raise_path(@webinar, hand), as: :json
    assert_response :bad_gateway
    assert_nil hand.reload.revoked_at
    assert_equal "uncertain", hand.state
  end

  # Retiré de la salle, le spectateur ne lève plus la
  # main et l'animation ne peut plus lui donner la parole.
  test "removed viewer can neither raise a hand nor be granted the floor" do
    hand = raise_hand
    @registration.remove_from_room!

    post public_hand_raises_path(@webinar.slug), as: :json
    assert_response :forbidden
    assert_equal "registration_required", response.parsed_body.fetch("error")

    sign_in_as(@host)
    post grant_webinar_hand_raise_path(@webinar, hand), as: :json
    assert_response :conflict
    assert_equal "waiting", hand.reload.state
    assert_empty @client.calls
  end

  test "non-live webinar refuses raising and granting" do
    hand = raise_hand
    @webinar.update!(state: "ended")
    post public_hand_raises_path(@webinar.slug), as: :json
    assert_response :conflict
    sign_in_as(@host)
    post grant_webinar_hand_raise_path(@webinar, hand), as: :json
    assert_response :conflict
    assert_empty @client.calls
  end

  test "paid webinars require payment both to raise and to grant" do
    @webinar.update!(price_cents: 1000)
    post confirm_registration_path(@registration.token)
    assert_no_difference "HandRaise.count" do
      post public_hand_raises_path(@webinar.slug), as: :json
    end
    assert_response :forbidden
    assert_equal "payment_required", response.parsed_body.fetch("error")
    @registration.update!(paid_confirmed_at: Time.current)
    hand = raise_hand
    @registration.update!(paid_confirmed_at: nil)
    sign_in_as(@host)
    post grant_webinar_hand_raise_path(@webinar, hand), as: :json
    assert_response :forbidden
    assert_nil hand.reload.granted_at
    assert_empty @client.calls
    @registration.update!(paid_confirmed_at: Time.current)
    post grant_webinar_hand_raise_path(@webinar, hand), as: :json
    assert_response :success
  end

  test "zero-price webinar attached to a pack still requires payment" do
    pack = Pack.create!(name: "Pack", price_cents: 5000, host_sub: @host.oidc_sub)
    @webinar.update!(price_cents: 0, pack: pack)
    post confirm_registration_path(@registration.token)
    post public_hand_raises_path(@webinar.slug), as: :json
    assert_response :forbidden
    assert_empty @client.calls
  end

  test "end failure is visible to the host without exposing warnings publicly" do
    hand = raise_hand
    HandRaiseControl.new(@webinar, client: @client).grant(hand.id)
    @client.error = RoomServiceClient::RemoteError.new("private SDK detail")
    sign_in_as(@host)
    post end_webinar_path(@webinar)
    assert_response :see_other
    assert @webinar.reload.ended?
    assert_includes flash[:alert], "autorisations de prise de parole"
    get public_webinar_state_path(@webinar.slug), as: :json
    assert_equal "ended", response.parsed_body.fetch("state")
    warnings = response.parsed_body.fetch("warnings")
    assert_equal "hand_permissions_uncertain", warnings.first.fetch("code")
    assert_equal %w[code message], warnings.first.keys.sort
    refute_includes response.body, "private SDK detail"
    refute_includes response.body, @registration.email
    assert_equal "no-store", response.headers["Cache-Control"]
    anonymous = open_session
    anonymous.get public_webinar_state_path(@webinar.slug), as: :json
    assert_equal 200, anonymous.response.status
    refute anonymous.response.parsed_body.key?("warnings")
    sign_in_as(@other_host)
    get public_webinar_state_path(@webinar.slug), as: :json
    refute response.parsed_body.key?("warnings")
  end

  test "draft visibility state is available only to its host" do
    @webinar.update!(visibility: "draft")
    get public_webinar_state_path(@webinar.slug), as: :json
    assert_response :not_found
    sign_in_as(@host)
    get public_webinar_state_path(@webinar.slug), as: :json
    assert_response :success
    assert_equal "live", response.parsed_body.fetch("state")
    sign_in_as(@other_host)
    get public_webinar_state_path(@webinar.slug), as: :json
    assert_response :not_found
  end

  test "end revokes granted hands and continues after a failed revocation" do
    hand = raise_hand
    HandRaiseControl.new(@webinar, client: @client).grant(hand.id)
    second_registration = @webinar.registrations.create!(name: "Bob", email: "bob@example.test", confirmed_at: Time.current)
    second = HandRaiseControl.new(@webinar, client: @client).raise_hand(second_registration)
    HandRaiseControl.new(@webinar, client: @client).grant(second.id)
    @client.error = RoomServiceClient::RemoteError.new("disconnected")
    @webinar.end!
    assert @webinar.reload.ended?
    assert_equal 2, @client.calls.count { |call| call[:can_publish] == false }
    assert_equal "uncertain", hand.reload.state
    assert_equal "uncertain", second.reload.state
    assert_nil hand.revoked_at
    @client.error = nil
    HandRaiseControl.new(@webinar, client: @client).revoke(hand.id)
    assert_equal "revoked", hand.reload.state
  end

  test "end reconciles a grant interrupted after its RPC began" do
    hand = raise_hand
    @client.error = SimulatedCrash.new("process interrupted")
    assert_raises(SimulatedCrash) { HandRaiseControl.new(@webinar, client: @client).grant(hand.id) }
    assert_equal "granting", hand.reload.state
    assert_nil hand.granted_at
    @client.error = nil
    @webinar.end!
    assert @webinar.reload.ended?
    assert_equal false, @client.calls.last.fetch(:can_publish)
    assert_equal "revoked", hand.reload.state
  end

  private

  def raise_hand
    post confirm_registration_path(@registration.token)
    post public_hand_raises_path(@webinar.slug), as: :json
    assert_response :created
    HandRaise.find(response.parsed_body.fetch("id"))
  end

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(provider: "pocket_id", uid: user.oidc_sub, info: { email: user.email })
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    get "/auth/pocket_id/callback"
    Rails.application.env_config.delete("omniauth.auth")
  end
end
