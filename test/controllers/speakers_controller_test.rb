require "test_helper"

class SpeakersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host = User.create!(email: "host@example.com", oidc_sub: "speaker-host", admin: true)
    @other = User.create!(email: "other@example.com", oidc_sub: "speaker-other")
    @webinar = Webinar.create!(title: "Speakers", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    @speaker = @webinar.speakers.create!(name: "Basile")
  end

  test "speaker_create_and_revoke exposes a named link only while active" do
    sign_in_as(@host)
    assert_difference "Speaker.count", 1 do
      post webinar_speakers_path(@webinar), params: { speaker: { name: "Marc" } }
    end
    assert_redirected_to webinar_path(@webinar)
    created = @webinar.speakers.find_by!(name: "Marc")
    follow_redirect!
    assert_select "[data-speaker-id='#{created.id}'] button[data-role='speaker-copy'][data-copy-link=?]",
                  join_webinar_url(slug: @webinar.slug, t: created.token)

    post revoke_webinar_speaker_path(@webinar, created)
    assert_redirected_to webinar_path(@webinar)
    assert created.reload.revoked_at
    follow_redirect!
    assert_select "[data-speaker-id='#{created.id}'] input", count: 0
    assert_select "[data-speaker-id='#{created.id}'] button[data-role='speaker-copy']", count: 0
    assert_not_includes response.body, created.token
    assert_select "[data-speaker-id='#{@speaker.id}'] button[data-role='speaker-copy']"
  end

  test "anonymous cannot create or revoke invitations" do
    assert_no_difference "Speaker.count" do
      post webinar_speakers_path(@webinar), params: { speaker: { name: "Intruder" } }
    end
    assert_redirected_to sign_in_path
    post revoke_webinar_speaker_path(@webinar, @speaker)
    assert_redirected_to sign_in_path
    assert_nil @speaker.reload.revoked_at
  end

  test "another host cannot create or revoke on this webinar" do
    sign_in_as(@other)
    assert_no_difference "Speaker.count" do
      post webinar_speakers_path(@webinar), params: { speaker: { name: "Intruder" } }
    end
    assert_response :not_found
    post revoke_webinar_speaker_path(@webinar, @speaker)
    assert_response :not_found
    assert_nil @speaker.reload.revoked_at
  end

  test "speaker id is scoped to the URL webinar even for the same host" do
    sign_in_as(@host)
    other_webinar = Webinar.create!(title: "Other", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    post revoke_webinar_speaker_path(other_webinar, @speaker)
    assert_response :not_found
    assert_nil @speaker.reload.revoked_at
  end

  test "creation only accepts name and escapes its HTML output" do
    sign_in_as(@host)
    post webinar_speakers_path(@webinar), params: {
      speaker: { name: "<script>alert(1)</script>", token: "attacker", webinar_id: 999, revoked_at: Time.current }
    }
    created = @webinar.speakers.order(:id).last
    assert_not_equal "attacker", created.token
    assert_nil created.revoked_at
    follow_redirect!
    assert_select "[data-speaker-id='#{created.id}'] th[scope='row']", text: "<script>alert(1)</script>"
    assert_select "[data-speaker-id='#{created.id}'] script", count: 0
  end

  test "blank names do not create an invitation and show validation feedback" do
    sign_in_as(@host)
    assert_no_difference "Speaker.count" do
      post webinar_speakers_path(@webinar), params: { speaker: { name: " " } }
    end
    assert_redirected_to webinar_path(@webinar)
    assert flash[:alert].present?
  end

  test "join accepts active invitations and rejects revoked or foreign invitations" do
    get join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    assert_response :success
    assert_select "#livekit-room[data-speaker-token=?]", @speaker.token
    @speaker.revoke!
    get join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    assert_response :not_found
    # Un ancien signed_id (purpose:speaker) ne résout plus —
    # ni sur le bon webinaire ni sur un autre.
    legacy_token = @webinar.signed_id(purpose: :speaker)
    other_webinar = Webinar.create!(title: "Other", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    get join_webinar_path(slug: other_webinar.slug, t: legacy_token)
    assert_response :not_found
    get join_webinar_path(slug: @webinar.slug, t: legacy_token)
    assert_response :not_found
  end

  test "l'adresse d'un intervenant se saisit à l'ajout ou après, normalisée ; elle seule est modifiable" do
    sign_in_as(@host)
    post webinar_speakers_path(@webinar), params: { speaker: { name: "Tristan", email: " Tristan@Example.TEST " } }
    assert_equal "tristan@example.test", @webinar.speakers.find_by!(name: "Tristan").email

    patch webinar_speaker_path(@webinar, @speaker), params: { speaker: { email: "basile@example.test", name: "Autre", token: "x" } }
    assert_redirected_to webinar_path(@webinar)
    assert_equal "Adresse de l'intervenant enregistrée.", flash[:notice]
    @speaker.reload
    assert_equal [ "basile@example.test", "Basile" ], [ @speaker.email, @speaker.name ]
    follow_redirect!
    assert_select "[data-speaker-id='#{@speaker.id}'] [data-role='speaker-email-form'] input[type=email][value='basile@example.test']"

    patch webinar_speaker_path(@webinar, @speaker), params: { speaker: { email: "" } }
    assert_nil @speaker.reload.email
  end

  test "une adresse invalide est refusée ; un autre animateur ne modifie rien" do
    sign_in_as(@host)
    patch webinar_speaker_path(@webinar, @speaker), params: { speaker: { email: "pas-une-adresse" } }
    assert flash[:alert].present?
    assert_nil @speaker.reload.email

    sign_in_as(@other)
    patch webinar_speaker_path(@webinar, @speaker), params: { speaker: { email: "intrus@example.test" } }
    assert_response :not_found
    assert_nil @speaker.reload.email
  end

  test "régénérer révoque l'ancien lien, publie le nouveau, et marque remplacé" do
    sign_in_as(@host)
    registration = @webinar.registrations.create!(name: "Basile", email: "basile@example.test")
    @speaker.update!(email: "basile@example.test", declared_email: "basile@example.test", registration: registration)
    old_token = @speaker.token

    assert_difference -> { Speaker.count }, 1 do
      post regenerate_webinar_speaker_path(@webinar, @speaker)
    end
    assert_redirected_to webinar_path(@webinar)
    assert_equal "Lien intervenant régénéré. L'ancien ne fonctionne plus.", flash[:notice]

    successor = @webinar.speakers.active.find_by!(name: "Basile")
    @speaker.reload
    assert @speaker.revoked_at
    assert_nil @speaker.registration_id
    assert_equal successor, @speaker.replaced_by
    assert_equal [ "basile@example.test", registration ], [ successor.email, successor.registration ]
    assert_not_equal old_token, successor.token

    follow_redirect!
    assert_select "[data-speaker-id='#{@speaker.id}'] [data-role='speaker-replaced']", text: "Remplacé"
    assert_select "[data-speaker-id='#{@speaker.id}']", text: /Lien révoqué/, count: 0
    assert_select "[data-speaker-id='#{@speaker.id}'] input", count: 0
    assert_select "[data-speaker-id='#{successor.id}'] button[data-role='speaker-copy'][data-copy-link=?]",
                  join_webinar_url(slug: @webinar.slug, t: successor.token)
    assert_not_includes response.body, old_token

    get join_webinar_path(slug: @webinar.slug, t: old_token)
    assert_response :not_found
    get join_webinar_path(slug: @webinar.slug, t: successor.token)
    assert_response :success
    assert_select "#livekit-room[data-speaker-token=?]", successor.token
  end

  test "régénérer est refusé aux anonymes, aux autres animateurs, et hors webinaire" do
    assert_no_difference -> { Speaker.count } do
      post regenerate_webinar_speaker_path(@webinar, @speaker)
    end
    assert_redirected_to sign_in_path
    assert_nil @speaker.reload.revoked_at

    sign_in_as(@other)
    post regenerate_webinar_speaker_path(@webinar, @speaker)
    assert_response :not_found
    assert_nil @speaker.reload.revoked_at

    sign_in_as(@host)
    other_webinar = Webinar.create!(title: "Other", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    post regenerate_webinar_speaker_path(other_webinar, @speaker)
    assert_response :not_found
    assert_nil @speaker.reload.revoked_at
  end

  test "régénérer un lien déjà révoqué n'en crée pas un autre" do
    sign_in_as(@host)
    @speaker.revoke!
    assert_no_difference -> { Speaker.count } do
      post regenerate_webinar_speaker_path(@webinar, @speaker)
    end
    assert_redirected_to webinar_path(@webinar)
    assert_equal "Cet intervenant est déjà révoqué.", flash[:alert]
    assert_nil @speaker.reload.replaced_by
  end

  test "régénérer expulse l'ancienne identité pendant le direct, pas avant" do
    fake = stub_room_service
    sign_in_as(@host)

    post regenerate_webinar_speaker_path(@webinar, @speaker)
    assert_empty fake.removed

    fresh = @webinar.speakers.active.find_by!(name: "Basile")
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    post regenerate_webinar_speaker_path(@webinar, fresh)
    assert_equal [ [ @webinar.room_name, "speaker-#{fresh.id}" ] ], fake.removed
  ensure
    restore_room_service
  end

  test "une expulsion LiveKit en échec laisse le nouveau lien et le dit" do
    stub_room_service(raise_on_remove: RoomServiceClient::Error.new("boom"))
    sign_in_as(@host)
    @webinar.update!(state: "live", started_at: 1.minute.ago)

    assert_difference -> { Speaker.count }, 1 do
      post regenerate_webinar_speaker_path(@webinar, @speaker)
    end
    assert_match(/expulsion LiveKit a échoué/, flash[:alert])
    assert @speaker.reload.revoked_at
    assert @webinar.speakers.active.exists?(name: "Basile")
  ensure
    restore_room_service
  end

  test "un intervenant déjà parti de la salle n'est pas une erreur d'expulsion" do
    stub_room_service(raise_on_remove: RoomServiceClient::RemoteError.new("absent", code: "not_found"))
    sign_in_as(@host)
    @webinar.update!(state: "live", started_at: 1.minute.ago)

    post regenerate_webinar_speaker_path(@webinar, @speaker)
    assert_equal "Lien intervenant régénéré. L'ancien ne fonctionne plus.", flash[:notice]
  ensure
    restore_room_service
  end

  test "query invitation and token fields are filtered without hiding title" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal({ "t" => "[FILTERED]", "token" => "[FILTERED]", "title" => "Speakers" },
      filter.filter({ "t" => @speaker.token, "token" => @speaker.token, "title" => "Speakers" }))
  end

  class FakeRoomService
    attr_reader :removed

    def initialize(raise_on_remove: nil)
      @raise = raise_on_remove
      @removed = []
    end

    def remove_participant(room:, identity:)
      @removed << [ room, identity ]
      raise @raise if @raise
    end
  end

  def stub_room_service(**opts)
    @prev_room = Rails.configuration.x.room_service_client_factory
    fake = FakeRoomService.new(**opts)
    Rails.configuration.x.room_service_client_factory = -> { fake }
    fake
  end

  def restore_room_service
    Rails.configuration.x.room_service_client_factory = @prev_room if defined?(@prev_room)
  end

  private

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub, info: { email: user.email }
    )
    get "/auth/pocket_id/callback"
  ensure
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end
end
