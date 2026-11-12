require "test_helper"

# Bandeau « question en cours » : tout participant de la
# salle lit la question affichée — libellé seul ; personne d'autre.
class QaDisplaysControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  setup do
    @owner = User.create!(email: "marc@example.test", oidc_sub: "sub-marc")
    @webinar = Webinar.create!(title: "Café IA #8", host_sub: @owner.oidc_sub, visibility: "published",
                               state: "live", starts_at: 1.hour.ago)
    message = @webinar.messages.create!(author_identity: "viewer-7", name: "Alice Secret", body: "Le replay ?")
    @item = QaItem.enqueue!(message: message, label: "Où trouver le replay ?", source: "llm")
  end

  test "spectateur inscrit, intervenant, animateur : même réponse, sans auteurs" do
    @item.display!
    registration = @webinar.registrations.create!(name: "Bob", email: "bob@example.test")
    speaker = @webinar.speakers.create!(name: "Basile")

    post confirm_registration_path(registration.token)
    responses = []
    get public_qa_display_path(slug: @webinar.slug), as: :json
    responses << response
    reset!
    get public_qa_display_path(slug: @webinar.slug), headers: { "X-Speaker-Token" => speaker.token }, as: :json
    responses << response
    reset!
    sign_in_as(@owner)
    get public_qa_display_path(slug: @webinar.slug), as: :json
    responses << response

    responses.each do |each_response|
      assert_equal 200, each_response.status
      assert_equal({ "id" => @item.id, "label" => "Où trouver le replay ?" }, each_response.parsed_body["displayed"].except("displayed_at"))
      assert_not_includes each_response.body, "Alice"
    end
  end

  test "rien d'affiché : displayed null" do
    sign_in_as(@owner)
    get public_qa_display_path(slug: @webinar.slug), as: :json
    assert_response :success
    assert_equal({ "displayed" => nil }, response.parsed_body)
  end

  test "inconnu (ni inscription, ni jeton, ni rôle) : 403" do
    @item.display!
    get public_qa_display_path(slug: @webinar.slug), headers: { "X-Speaker-Token" => "faux" }, as: :json
    assert_response :forbidden
    assert_not_includes response.body, "replay"
  end
end
