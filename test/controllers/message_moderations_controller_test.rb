require "test_helper"

# Panneau « Questions » de l'animation : seule l'animation
# marque répondu, épingle et désépingle ; chaque changement est diffusé une
# fois, les doubles clics ne réécrivent rien.
class MessageModerationsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  class Broadcaster
    attr_reader :calls

    def initialize
      @calls = []
    end

    def send_data(**arguments)
      @calls << JSON.parse(arguments.fetch(:data)).fetch("message")
      {}
    end
  end

  setup do
    @owner = User.create!(email: "marc@example.test", oidc_sub: "sub-marc")
    @guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co", email_verified: true,
                          email_verified_for: "co@partenaire.test")
    @webinar = Webinar.create!(title: "Café IA #7", host_sub: @owner.oidc_sub, visibility: "published",
                               state: "live", starts_at: 1.hour.ago)
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @question = @webinar.messages.create!(author_identity: "viewer-1", name: "Alice", body: "@animateur pourquoi ?")
    @chat = @webinar.messages.create!(author_identity: "viewer-1", name: "Alice", body: "Bonjour")
    @broadcaster = Broadcaster.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @broadcaster }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @previous_factory
    ActionController::Base.allow_forgery_protection = false
  end

  test "marquer répondu : posé une fois, diffusé une fois, idempotent" do
    sign_in_as(@owner)

    post answer_webinar_message_path(@webinar, @question), as: :json
    assert_response :success
    answered_at = @question.reload.answered_at
    assert answered_at
    assert_equal "sent", response.parsed_body.fetch("broadcast")

    post answer_webinar_message_path(@webinar, @question), as: :json
    assert_response :success
    assert_equal "unchanged", response.parsed_body.fetch("broadcast")
    assert_equal answered_at, @question.reload.answered_at
    assert_equal [ @question.id ], @broadcaster.calls.map { |message| message.fetch("id") }
  end

  test "un simple message n'est pas une question à marquer répondue" do
    sign_in_as(@owner)
    post answer_webinar_message_path(@webinar, @chat), as: :json
    assert_response :not_found
    assert_nil @chat.reload.answered_at
  end

  test "épingler puis désépingler n'importe quel message, co-animateur compris" do
    sign_in_as(@guest, email_verified: true)

    post pin_webinar_message_path(@webinar, @chat), as: :json
    assert_response :success
    assert response.parsed_body.fetch("pinned_at")
    post unpin_webinar_message_path(@webinar, @chat), as: :json
    assert_response :success
    assert_nil @chat.reload.pinned_at
    assert_equal [ true, false ], @broadcaster.calls.map { |message| message.fetch("pinned_at").present? }
  end

  test "sans session : connexion ; sans rôle ou message d'un autre webinaire : 404" do
    post pin_webinar_message_path(@webinar, @chat), as: :json
    assert_redirected_to sign_in_path

    sign_in_as(User.create!(email: "passant@example.test", oidc_sub: "sub-passant"))
    post pin_webinar_message_path(@webinar, @chat), as: :json
    assert_response :not_found

    other = Webinar.create!(title: "Autre", host_sub: "autre", visibility: "published", state: "live", starts_at: 1.hour.ago)
    foreign = other.messages.create!(author_identity: "viewer-2", name: "Eve", body: "@animateur ailleurs")
    sign_in_as(@owner)
    post answer_webinar_message_path(@webinar, foreign), as: :json
    assert_response :not_found
    assert_nil foreign.reload.answered_at
    assert_empty @broadcaster.calls
  end

  test "après la fin du direct, le fil est figé" do
    @webinar.update!(state: "ended")
    sign_in_as(@owner)
    post pin_webinar_message_path(@webinar, @chat), as: :json
    assert_response :gone
    assert_nil @chat.reload.pinned_at
  end

  test "CSRF actif : sans jeton, refus JSON 422 et rien ne change" do
    sign_in_as(@owner)
    ActionController::Base.allow_forgery_protection = true

    post pin_webinar_message_path(@webinar, @chat), as: :json
    assert_response :unprocessable_entity
    assert_equal "invalid_authenticity_token", response.parsed_body.fetch("error")
    assert_nil @chat.reload.pinned_at
  end
end
