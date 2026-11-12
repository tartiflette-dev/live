require "test_helper"

# Sondages du direct dans le replay, côté spectateur : la personne est
# décidée par le serveur, un inscrit ne répond que sur SON café, l'anonyme
# jamais ; débit borné.
class ReplayPollsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-polls")
    ENV["RECORDINGS_ROOT"] = @tmp
    # Compteurs de débit propres à chaque test : les ids reviennent après le
    # retour en arrière de la transaction, les clés aussi.
    FileUtils.rm_rf(Pathname.new(RegistrationRateLimitStore.storage_root).join("replay_interaction_rate_limits"))
    @replay = replay_cafe
    @webinar = @replay.webinar
    origin = @replay.recording.started_at
    @poll = @webinar.polls.create!(position: 1, kind: "choice", label: "Ça vous parle ?", options: %w[Oui Non],
                                   opened_at: origin + 600, closed_at: origin + 720)
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

  def answer(value = [ 1 ], poll: @poll, webinar: @webinar, **extra)
    post public_webinar_replay_poll_responses_path(webinar.slug, poll.id), params: { value: value, **extra }, as: :json
  end

  test "anonyme : 404 à la lecture comme à la réponse, rien d'écrit" do
    get public_webinar_replay_polls_path(@webinar.slug)
    assert_response :not_found

    answer
    assert_response :not_found
    assert_equal 0, PollResponse.count
  end

  test "inscrit à un AUTRE café : ni la liste ni la réponse sur celui-ci" do
    other_replay = replay_cafe
    other = confirmed_registration(other_replay.webinar, "autre@example.test")
    open_replay_as(other, other_replay.webinar)

    get public_webinar_replay_polls_path(@webinar.slug)
    assert_response :not_found
    answer
    assert_response :not_found
    assert_equal 0, PollResponse.count
  end

  test "un sondage d'un autre webinaire ne se répond pas par ce replay" do
    other_replay = replay_cafe
    foreign = other_replay.webinar.polls.create!(position: 1, kind: "choice", label: "?", options: %w[A B],
                                                 opened_at: other_replay.recording.started_at + 60)
    open_replay_as(@ines)

    answer(poll: foreign)
    assert_response :not_found
    assert_equal 0, PollResponse.count
  end

  test "inscrit de ce café : la liste, puis sa réponse — à son inscription, quoi que dise le corps" do
    open_replay_as(@ines)

    get public_webinar_replay_polls_path(@webinar.slug)
    assert_response :success
    listed = response.parsed_body["polls"].sole
    assert_equal [ @poll.id, 600.0, 720.0, nil, nil ], listed.values_at("id", "start", "end", "my_response", "results")

    answer([ 1 ], registration_id: 999, user_id: 42, origin: "live")
    assert_response :created
    body = response.parsed_body
    assert_equal({ "value" => [ 1 ], "origin" => "replay" }, body["my_response"])
    assert_equal({ "respondents" => 1, "counts" => [ 0, 1 ], "live" => 0, "replay" => 1 }, body["results"])
    response_row = PollResponse.sole
    assert_equal [ "replay", @ines, nil ], [ response_row.origin, response_row.registration, response_row.user ]
  end

  test "compte undust : répond sur tout replay publié" do
    user = spectator_user
    sign_in_as(user, groups: [])

    answer([ 0 ])
    assert_response :created
    assert_equal [ user, "account-#{user.id}" ], [ PollResponse.sole.user, PollResponse.sole.respondent_identity ]
  end

  test "déjà répondu au direct : 409, la réponse du direct reste" do
    @poll.responses.create!(respondent_identity: "viewer-#{@ines.id}", name: "Inès", value: [ 0 ], registration: @ines)
    open_replay_as(@ines)

    answer([ 1 ])
    assert_response :conflict
    assert_equal "answered_live", response.parsed_body["error"]
    assert_equal [ [ "live", [ 0 ] ] ], PollResponse.pluck(:origin, :value)
  end

  test "réponse hors format : 422 ; corps non JSON : 415 ; sondage jamais lancé : 404" do
    open_replay_as(@ines)

    answer([ 5 ])
    assert_response :unprocessable_entity
    post public_webinar_replay_poll_responses_path(@webinar.slug, @poll.id), params: { value: [ 0 ] }
    assert_response :unsupported_media_type
    planned = @webinar.polls.create!(position: 2, kind: "choice", label: "Prévu", options: %w[A B])
    answer([ 0 ], poll: planned)
    assert_response :not_found
    assert_equal 0, PollResponse.count
  end

  test "personne effacée pendant l'envoi : 404, jamais « déjà répondu au direct »" do
    open_replay_as(@ines)
    PollResponse.where(registration: @ines).delete_all
    Registration.where(id: @ines.id).delete_all

    answer
    assert_response :not_found
    assert_equal 0, PollResponse.count
  end

  test "CSRF actif : sans jeton, refus JSON 422, rien d'écrit" do
    open_replay_as(@ines)
    ActionController::Base.allow_forgery_protection = true

    answer
    assert_response :unprocessable_entity
    assert_equal "invalid_authenticity_token", response.parsed_body.fetch("error")
    assert_equal 0, PollResponse.count
  end

  test "replay non publié : l'animation le voit mais n'y répond pas" do
    @replay.unpublish!
    sign_in_as(User.find_by!(oidc_sub: "publication-host"))

    get public_webinar_replay_polls_path(@webinar.slug)
    assert_response :success
    answer
    assert_response :not_found
    assert_equal 0, PollResponse.count
  end

  test "débit borné : au-delà de 10 réponses par minute, 429" do
    open_replay_as(@ines)

    10.times { answer }
    assert_response :created
    answer
    assert_response :too_many_requests
  end
end
