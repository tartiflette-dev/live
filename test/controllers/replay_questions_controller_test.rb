require "test_helper"

# Question posée depuis le replay : la personne est décidée par le serveur,
# un inscrit ne pose que sur SON café, l'anonyme jamais ; débit borné.
class ReplayQuestionsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-questions")
    ENV["RECORDINGS_ROOT"] = @tmp
    # Compteurs de débit propres à chaque test : les ids reviennent après le
    # retour en arrière de la transaction, les clés aussi.
    FileUtils.rm_rf(Pathname.new(RegistrationRateLimitStore.storage_root).join("replay_interaction_rate_limits"))
    @replay = replay_cafe
    @webinar = @replay.webinar
    @ines = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
  end

  teardown do
    ActionController::Base.allow_forgery_protection = false
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  def open_replay_as(registration, webinar = @webinar)
    post public_webinar_replay_access_path(webinar.slug), params: { t: registration.token }
  end

  def ask(label: "Et pour les PME ?", at: 754.2, webinar: @webinar, **extra)
    post public_webinar_replay_questions_path(webinar.slug), params: { label: label, at: at, **extra }, as: :json
  end

  test "anonyme : 404, rien d'écrit" do
    ask
    assert_response :not_found
    assert_equal 0, QaItem.count
  end

  test "inscrit à un AUTRE café : 404 sur celui-ci" do
    other_replay = replay_cafe
    open_replay_as(confirmed_registration(other_replay.webinar, "autre@example.test"), other_replay.webinar)

    ask
    assert_response :not_found
    assert_equal 0, QaItem.count
  end

  test "inscrit de ce café : la question rejoint la file, à son nom, quoi que dise le corps" do
    open_replay_as(@ines)

    ask(registration_id: 999, user_id: 42, source: "manual")
    assert_response :created
    item = QaItem.sole
    assert_equal({ "id" => item.id, "label" => "Et pour les PME ?", "video_position" => 754.2 }, response.parsed_body)
    assert_equal [ @webinar, "replay", @ines, nil ], [ item.webinar, item.source, item.registration, item.user ]
  end

  test "compte undust : la question est au compte" do
    user = spectator_user
    sign_in_as(user, groups: [])

    ask
    assert_response :created
    assert_equal user, QaItem.sole.user
  end

  test "libellé vide, instant illisible : 422 ; corps non JSON : 415" do
    open_replay_as(@ines)

    ask(label: "  ")
    assert_response :unprocessable_entity
    ask(at: "abc")
    assert_response :unprocessable_entity
    ask(at: nil)
    assert_response :unprocessable_entity
    ask(label: %w[a b])
    assert_response :unprocessable_entity
    ask(label: { texte: "a" })
    assert_response :unprocessable_entity
    post public_webinar_replay_questions_path(@webinar.slug), params: { label: "Et ?", at: 1 }
    assert_response :unsupported_media_type
    assert_equal 0, QaItem.count
  end

  test "CSRF actif : sans jeton, refus JSON 422, rien d'écrit" do
    open_replay_as(@ines)
    ActionController::Base.allow_forgery_protection = true

    ask
    assert_response :unprocessable_entity
    assert_equal "invalid_authenticity_token", response.parsed_body.fetch("error")
    assert_equal 0, QaItem.count
  end

  test "replay non publié : l'animation ne pose pas de question dans sa propre relecture" do
    @replay.unpublish!
    sign_in_as(User.find_by!(oidc_sub: "publication-host"))

    ask
    assert_response :not_found
    assert_equal 0, QaItem.count
  end

  test "débit borné : au-delà de 5 questions en 10 minutes, 429" do
    open_replay_as(@ines)

    5.times { |index| ask(label: "Question #{index}") }
    assert_response :created
    ask(label: "Une de trop")
    assert_response :too_many_requests
    assert_equal 5, QaItem.count
  end
end
