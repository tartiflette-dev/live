require "test_helper"

# Discussion du direct, côté participants : qui lit, qui
# écrit, ce que le serveur décide seul, le curseur, l'anti-spam et le CSRF.
# La diffusion LiveKit est remplacée par un enregistreur : aucun appel réseau.
class MessagesControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  class Broadcaster
    attr_accessor :failure
    attr_reader :calls

    def initialize
      @calls = []
    end

    def send_data(**arguments)
      @calls << arguments
      raise RoomServiceClient::RemoteError, "détail d'infrastructure privé" if failure

      {}
    end
  end

  setup do
    # Sub unique : la clé anti-spam d'un animateur en dérive, et le store
    # fichier est partagé par les workers de test parallèles.
    @host = User.create!(email: "marc@example.test", oidc_sub: "host-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #7", host_sub: @host.oidc_sub, visibility: "published",
                               state: "live", starts_at: 1.hour.ago)
    @other = Webinar.create!(title: "Autre", host_sub: "autre", visibility: "published", state: "live",
                             starts_at: 1.hour.ago)
    @registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test")
    @broadcaster = Broadcaster.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @broadcaster }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @previous_factory
    ActionController::Base.allow_forgery_protection = false
  end

  test "sans inscription ni rôle, ni lecture ni écriture" do
    get public_webinar_messages_path(@webinar.slug), as: :json
    assert_response :forbidden

    assert_no_difference "Message.count" do
      post_message(body: "Bonjour", author_identity: "host-#{@host.oidc_sub}", name: "Marc")
    end
    assert_response :forbidden
    assert_equal "participant_required", response.parsed_body.fetch("error")
    assert_empty @broadcaster.calls
  end

  test "spectateur confirmé : auteur, nom et nature décidés serveur, texte échappé, puis diffusion" do
    confirm_viewer

    assert_difference "Message.count", 1 do
      post_message(body: "@animateur <script>alert(1)</script>", name: "Mallory", kind: "chat",
                   author_identity: "host-#{@host.oidc_sub}", answered_at: Time.current, pinned_at: Time.current)
    end

    assert_response :created
    result = response.parsed_body
    assert_equal [ "Alice", "viewer", "question", "sent" ], result.values_at("name", "author_role", "kind", "broadcast")
    assert_nil result["answered_at"]
    assert_nil result["pinned_at"]
    assert_equal "viewer-#{@registration.id}", Message.find(result.fetch("id")).author_identity
    assert_equal "@animateur <script>alert(1)</script>", result.fetch("body")
    refute_includes response.body, "<script>", "le JSON échappe < et > (rendu texte côté client)"

    broadcast = @broadcaster.calls.sole
    assert_equal [ @webinar.room_name, :reliable ], broadcast.values_at(:room, :kind)
    envelope = JSON.parse(broadcast.fetch(:data))
    assert_equal "chat", envelope.fetch("topic")
    assert_equal result.except("broadcast"), envelope.fetch("message")
  end

  test "échappement maintenu même si le réglage global le coupe" do
    confirm_viewer
    @webinar.messages.create!(author_identity: "viewer-9", name: "Bob", body: "<b>gras</b>")
    previous = ActiveSupport.escape_html_entities_in_json
    ActiveSupport.escape_html_entities_in_json = false

    get public_webinar_messages_path(@webinar.slug), as: :json

    assert_equal "<b>gras</b>", messages_in_response.sole.fetch("body")
    refute_includes response.body, "<b>"
  ensure
    ActiveSupport.escape_html_entities_in_json = previous
  end

  test "spectateur : salle fermée avant le direct, lecture seule après la fin" do
    confirm_viewer
    @webinar.update!(state: "draft")
    get public_webinar_messages_path(@webinar.slug), as: :json
    assert_response :forbidden
    post_message(body: "Trop tôt")
    assert_response :forbidden

    @webinar.update!(state: "ended")
    get public_webinar_messages_path(@webinar.slug), as: :json
    assert_response :success
    assert_no_difference "Message.count" do
      post_message(body: "Trop tard")
    end
    assert_response :gone
  end

  test "spectateur : cookie d'un autre webinaire, inscription non payée ou webinaire non publié, refusés" do
    confirm_viewer
    get public_webinar_messages_path(@other.slug), as: :json
    assert_response :forbidden

    @webinar.update!(price_cents: 9900)
    post_message(body: "Pas encore payé")
    assert_response :forbidden
    @registration.update!(paid_confirmed_at: Time.current)
    post_message(body: "Payé")
    assert_response :created

    @webinar.update!(visibility: "draft")
    get public_webinar_messages_path(@webinar.slug), as: :json
    assert_response :forbidden
  end

  # Retiré de la salle depuis la régie, le spectateur
  # perd aussi la discussion, en lecture comme en écriture.
  test "spectateur retiré de la salle : discussion fermée" do
    confirm_viewer
    post_message(body: "Avant le retrait")
    assert_response :created

    @registration.reload.remove_from_room!
    post_message(body: "Après le retrait")
    assert_response :forbidden
    assert_equal "participant_required", response.parsed_body.fetch("error")
    get public_webinar_messages_path(@webinar.slug), as: :json
    assert_response :forbidden
    assert_equal [ "Avant le retrait" ], @webinar.messages.pluck(:body)
  end

  test "intervenant nominatif actif par en-tête ; révoqué, étranger ou jeton dans l'URL, refusés" do
    speaker = @webinar.speakers.create!(name: "Basile")
    post_message(body: "Bonjour la salle", speaker_token: speaker.token)
    assert_response :created
    assert_equal [ "Basile", "speaker" ], response.parsed_body.values_at("name", "author_role")
    assert_equal "speaker-#{speaker.id}", Message.last.author_identity

    get public_webinar_messages_path(@webinar.slug, speaker_token: speaker.token), as: :json
    assert_response :forbidden, "le jeton ne s'accepte qu'en en-tête, jamais dans l'URL"

    speaker.revoke!
    post_message(body: "Révoqué", speaker_token: speaker.token)
    assert_response :forbidden
    foreign = @other.speakers.create!(name: "Eve")
    post_message(body: "Étranger", speaker_token: foreign.token)
    assert_response :forbidden
  end

  test "animation : alias sans l'email complet, y compris avant le direct ; sans rôle, refusé" do
    @webinar.update!(state: "draft")
    sign_in_as(@host)
    post_message(body: "On commence dans deux minutes")
    assert_response :created
    assert_equal [ "marc", "host" ], response.parsed_body.values_at("name", "author_role")
    refute_includes response.body, @host.email

    project_host = User.create!(email: "regie@example.test", oidc_sub: "regie-#{SecureRandom.hex(4)}", admin: true)
    sign_in_as(project_host)
    post_message(body: "Régie")
    assert_response :created

    sign_in_as(User.create!(email: "passant@example.test", oidc_sub: "passant-#{SecureRandom.hex(4)}"))
    get public_webinar_messages_path(@webinar.slug), as: :json
    assert_response :forbidden
  end

  test "diffusion indisponible : message conservé, dégradation signalée sans détail interne, rattrapé au poll" do
    confirm_viewer
    @broadcaster.failure = true

    assert_difference "Message.count", 1 do
      post_message(body: "Toujours là au prochain poll")
    end

    assert_response :created
    assert_equal "unavailable", response.parsed_body.fetch("broadcast")
    refute_includes response.body, "infrastructure"
    get public_webinar_messages_path(@webinar.slug), as: :json
    assert_equal [ "Toujours là au prochain poll" ], messages_in_response.map { |message| message.fetch("body") }
  end

  test "lecture paginée par 50, bornée au webinaire, reprise au curseur (updated_at, id)" do
    confirm_viewer
    55.times { |i| @webinar.messages.create!(author_identity: "viewer-9", name: "Bob", body: "message #{i}") }
    @other.messages.create!(author_identity: "viewer-9", name: "Eve", body: "privé")

    get public_webinar_messages_path(@webinar.slug), as: :json
    first_page = messages_in_response
    assert_equal 50, first_page.size
    last = first_page.last

    get public_webinar_messages_path(@webinar.slug, updated_since: last.fetch("updated_at"), updated_since_id: last.fetch("id")), as: :json
    assert_equal (50..54).map { |i| "message #{i}" }, messages_in_response.map { |message| message.fetch("body") }
  end

  test "curseur partiel, mal formé ou impossible : 400, jamais corrigé" do
    confirm_viewer
    [ { updated_since: "2026-10-30T08:00:00.000000Z" },
      { updated_since_id: 1 },
      { updated_since: "2026-02-31T00:00:00.000000Z", updated_since_id: 1 },
      { updated_since: "2026-10-30T08:00:00.000Z", updated_since_id: 1 },
      { updated_since: "2026-10-30T08:00:00.000000Z", updated_since_id: "1 OR 1=1" } ].each do |cursor|
      get public_webinar_messages_path(@webinar.slug, cursor), as: :json
      assert_response :bad_request, cursor.inspect
      assert_equal "invalid_cursor", response.parsed_body.fetch("error")
    end
  end

  test "texte invalide, trop long ou formulaire non JSON : rien n'est enregistré" do
    confirm_viewer
    assert_no_difference "Message.count" do
      post_message(body: [ "pas une chaîne" ])
      assert_response :unprocessable_entity
      post_message(body: "x" * 1001)
      assert_response :unprocessable_entity
      post_message(body: "   ")
      assert_response :unprocessable_entity
      post public_webinar_messages_path(@webinar.slug), params: { body: "formulaire" }
      assert_response :unsupported_media_type
    end
  end

  test "anti-spam par auteur : 5 messages par 10 s, 20 par minute, sans toucher un autre spectateur" do
    confirm_viewer
    5.times { post_message(body: "rafale") }
    assert_response :created
    assert_no_difference "Message.count" do
      post_message(body: "une de trop")
    end
    assert_response :too_many_requests
    assert_equal "rafale", Message.last.body

    # Autre personne, autre navigateur (même IP) : un navigateur garde
    # l'inscription qu'il porte déjà à ce webinaire.
    neighbour = @webinar.registrations.create!(name: "Bruno", email: "bruno@example.test")
    neighbour_browser = open_session
    neighbour_browser.post confirm_registration_path(neighbour.token)
    neighbour_browser.post public_webinar_messages_path(@webinar.slug), params: { body: "Même NAT, autre personne" }, as: :json
    assert_equal 201, neighbour_browser.response.status

    [ 11, 22, 33 ].each do |seconds|
      travel seconds.seconds do
        5.times { post_message(body: "soutenu") }
        assert_response :created
      end
    end
    travel 44.seconds do
      post_message(body: "vingt et unième")
      assert_response :too_many_requests
    end
  end

  test "CSRF actif : sans jeton, refus JSON 422 (jamais la page 500) ; avec le jeton de la page, accepté" do
    confirm_viewer
    ActionController::Base.allow_forgery_protection = true

    assert_no_difference "Message.count" do
      post_message(body: "Sans jeton")
    end
    assert_response :unprocessable_entity
    assert_equal "invalid_authenticity_token", response.parsed_body.fetch("error")

    get public_webinar_path(slug: @webinar.slug)
    token = response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
    assert token, "la salle doit poser le jeton CSRF que lit le client"
    post public_webinar_messages_path(@webinar.slug), params: { body: "Avec jeton" },
      headers: { "X-CSRF-Token" => CGI.unescapeHTML(token) }, as: :json
    assert_response :created
  end

  # File Q&R : chaque message enfile QaExtractionJob ; une
  # file indisponible ne fait jamais échouer l'envoi, et rien du texte ne
  # part au journal.
  test "l'envoi réussit même si la mise en file de l'extraction Q&R échoue" do
    post confirm_registration_path(@registration.token)
    original = QaExtractionJob.method(:perform_later)
    QaExtractionJob.define_singleton_method(:perform_later) { |*| raise ActiveRecord::StatementTimeout, "file occupée" }
    io = StringIO.new
    previous_logger = Rails.logger
    previous_controller_logger = ActionController::Base.logger
    Rails.logger = ActionController::Base.logger = ActiveSupport::Logger.new(io)

    post_message(body: "@animateur une question confidentielle ?")

    assert_response :created
    assert_equal "@animateur une question confidentielle ?", @webinar.messages.sole.body
    assert_match(/\[qa_extraction\] enqueue_failed webinar=#{@webinar.id} message=\d+ ActiveRecord::StatementTimeout/, io.string)
    assert_match(/Parameters: .*"body" *=> *"\[FILTERED\]"/, io.string)
    assert_no_match(/confidentielle/, io.string, "le texte du chat n'apparaît jamais dans les journaux (filter_parameters)")
  ensure
    Rails.logger = previous_logger
    ActionController::Base.logger = previous_controller_logger
    QaExtractionJob.define_singleton_method(:perform_later, original)
  end

  private

  def confirm_viewer
    post confirm_registration_path(@registration.token)
    assert_response :redirect
  end

  def post_message(speaker_token: nil, **parameters)
    headers = speaker_token ? { "X-Speaker-Token" => speaker_token } : {}
    post public_webinar_messages_path(@webinar.slug), params: parameters, headers: headers, as: :json
  end

  def messages_in_response
    response.parsed_body.fetch("messages")
  end
end
