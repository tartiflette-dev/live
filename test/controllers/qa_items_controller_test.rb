require "test_helper"

# File Q&R côté animation : seule l'animation (propriétaire,
# co-animateur) lit et traite la file ; chaque changement est signalé à la
# salle une fois ; la salle ne reçoit que la question affichée, jamais ses
# auteurs.
class QaItemsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include QaLlmStubbing

  class Broadcaster
    attr_reader :packets

    def initialize
      @packets = []
    end

    def send_data(room:, data:, kind:)
      @packets << JSON.parse(data)
      {}
    end
  end

  setup do
    @owner = User.create!(email: "marc@example.test", oidc_sub: "sub-marc")
    @guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co", email_verified: true,
                          email_verified_for: "co@partenaire.test")
    @webinar = Webinar.create!(title: "Café IA #8", host_sub: @owner.oidc_sub, visibility: "published",
                               state: "live", starts_at: 1.hour.ago)
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @message = @webinar.messages.create!(author_identity: "viewer-7", name: "Alice", body: "<b>Et le replay ?</b>")
    @item = QaItem.enqueue!(message: @message, label: "Où trouver le replay ?", source: "llm", llm_model: "glm-4-9b")
    @broadcaster = Broadcaster.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @broadcaster }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @previous_factory
  end

  test "liste : ouvertes d'abord, auteurs et messages d'origine, texte échappé, état réel de l'analyse" do
    answered = QaItem.enqueue!(message: @webinar.messages.create!(author_identity: "speaker-2", name: "Bob", body: "Q ?"),
                               label: "Déjà traitée", source: "manual")
    answered.answer!
    sign_in_as(@owner)

    with_llm(FakeLlmClient.new) { get webinar_qa_items_path(@webinar), as: :json }

    assert_response :success
    body = response.parsed_body
    assert_equal({ "enabled" => true, "outcome" => nil, "at" => nil, "duration_ms" => nil }, body["analysis"])
    assert_equal [ @item.id, answered.id ], body["items"].map { |item| item["id"] }
    first = body["items"].first
    assert_equal [ { "name" => "Alice", "role" => "viewer" } ], first["authors"]
    assert_equal "<b>Et le replay ?</b>", first["messages"].sole["body"]
    assert_not_includes response.body, "<b>"

    @webinar.update_columns(qa_llm_outcome: "timeout", qa_llm_at: Time.utc(2026, 10, 31, 11, 0), qa_llm_duration_ms: 15_002)
    get webinar_qa_items_path(@webinar), as: :json
    assert_equal({ "enabled" => false, "outcome" => "timeout", "at" => "2026-10-31T11:00:00.000000Z", "duration_ms" => 15_002 },
                 response.parsed_body["analysis"])
  end

  test "répondue, écartée, rouverte : chaque changement diffusé une fois, double clic inchangé" do
    sign_in_as(@guest, email_verified: true)

    post answer_webinar_qa_item_path(@webinar, @item), as: :json
    assert_response :success
    assert_equal [ "answered", "sent" ], response.parsed_body.values_at("status", "broadcast")
    post answer_webinar_qa_item_path(@webinar, @item), as: :json
    assert_equal "unchanged", response.parsed_body["broadcast"]

    post reopen_webinar_qa_item_path(@webinar, @item), as: :json
    post dismiss_webinar_qa_item_path(@webinar, @item), as: :json
    assert_equal "dismissed", @item.reload.status
    assert_equal 3, @broadcaster.packets.size
  end

  test "afficher à l'écran : la salle reçoit le libellé seul ; retirer ; refusé après le direct" do
    sign_in_as(@owner)

    post display_webinar_qa_item_path(@webinar, @item), as: :json
    assert_response :success
    assert response.parsed_body["displayed_at"]
    packet = @broadcaster.packets.last
    assert_equal "qa", packet["topic"]
    assert_equal %w[displayed_at id label], packet["displayed"].keys.sort
    assert_equal "Où trouver le replay ?", packet["displayed"]["label"]

    post hide_webinar_qa_item_path(@webinar, @item), as: :json
    assert_nil @broadcaster.packets.last["displayed"]

    @webinar.update!(state: "ended")
    post display_webinar_qa_item_path(@webinar, @item), as: :json
    assert_response :gone
    post answer_webinar_qa_item_path(@webinar, @item), as: :json
    assert_response :success, "la file reste traitable après le direct"
  end

  test "une question close ne s'affiche pas" do
    @item.dismiss!
    sign_in_as(@owner)
    post display_webinar_qa_item_path(@webinar, @item), as: :json
    assert_response :unprocessable_entity
    assert_equal "not_displayable", response.parsed_body["error"]
  end

  test "modifier la reformulation ; vide ou trop longue : 422, rien d'écrit" do
    sign_in_as(@owner)

    patch webinar_qa_item_path(@webinar, @item), params: { label: "Le replay sera-t-il public ?" }, as: :json
    assert_response :success
    assert_equal "Le replay sera-t-il public ?", @item.reload.label

    patch webinar_qa_item_path(@webinar, @item), params: { label: "x" * 501 }, as: :json
    assert_response :unprocessable_entity
    assert_equal "Le replay sera-t-il public ?", @item.reload.label
  end

  test "la reformulation corrigée n'apparaît jamais dans les journaux (filter_parameters)" do
    sign_in_as(@owner)
    io = StringIO.new
    previous = [ Rails.logger, ActionController::Base.logger ]
    Rails.logger = ActionController::Base.logger = ActiveSupport::Logger.new(io)

    patch webinar_qa_item_path(@webinar, @item), params: { label: "Question très personnelle de Chloé ?" }, as: :json

    assert_response :success
    assert_match(/Parameters: .*"label" *=> *"\[FILTERED\]"/, io.string)
    assert_no_match(/personnelle/, io.string)
  ensure
    Rails.logger, ActionController::Base.logger = previous
  end

  test "ajout manuel depuis un message : 201 puis 200 (déjà en file) ; message effacé ou d'un autre webinaire refusé" do
    sign_in_as(@owner)
    chat = @webinar.messages.create!(author_identity: "viewer-8", name: "Chloé", body: "On aura les slides ?")

    post webinar_qa_items_path(@webinar), params: { message_id: chat.id }, as: :json
    assert_response :created
    assert_equal [ "On aura les slides ?", "manual" ], response.parsed_body.values_at("label", "source")
    post webinar_qa_items_path(@webinar), params: { message_id: chat.id, label: "Autre" }, as: :json
    assert_response :ok
    assert_equal 2, @webinar.qa_items.count

    erased = @webinar.messages.create!(author_identity: "viewer-9", name: "x", body: "y")
    erased.update_columns(body: CrmErasure::ERASED_BODY)
    post webinar_qa_items_path(@webinar), params: { message_id: erased.id }, as: :json
    assert_response :unprocessable_entity

    other = Webinar.create!(title: "Autre", host_sub: @owner.oidc_sub, starts_at: 1.hour.ago)
    foreign = other.messages.create!(author_identity: "viewer-1", name: "Zoé", body: "Q ?")
    post webinar_qa_items_path(@webinar), params: { message_id: foreign.id }, as: :json
    assert_response :not_found
  end

  test "sans session : connexion ; sans rôle, ou item d'un autre webinaire : 404" do
    get webinar_qa_items_path(@webinar), as: :json
    assert_redirected_to sign_in_path

    sign_in_as(User.create!(email: "passant@example.test", oidc_sub: "sub-passant"))
    get webinar_qa_items_path(@webinar), as: :json
    assert_response :not_found
    post answer_webinar_qa_item_path(@webinar, @item), as: :json
    assert_response :not_found
    assert_predicate @item.reload, :open?

    sign_in_as(@owner)
    other = Webinar.create!(title: "Autre", host_sub: @owner.oidc_sub, starts_at: 1.hour.ago)
    post answer_webinar_qa_item_path(other, @item), as: :json
    assert_response :not_found
  end

  test "sans jeton CSRF : 422 JSON, rien d'écrit" do
    sign_in_as(@owner)
    ActionController::Base.allow_forgery_protection = true
    post answer_webinar_qa_item_path(@webinar, @item), as: :json
    assert_response :unprocessable_entity
    assert_predicate @item.reload, :open?
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
