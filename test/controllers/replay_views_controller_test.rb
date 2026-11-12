require "test_helper"

# Battements du lecteur : la personne est décidée par le serveur, le débit
# est borné.
class ReplayViewsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-views")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    @key = session_key
    # Le compteur de débit est un fichier partagé par les tests d'un même
    # worker, et la clé (personne + id) se répète d'un test à l'autre : on
    # repart de zéro, comme pour la recherche des replays.
    ReplayViewsController::RATE_LIMIT_STORE.synchronize(&:clear)
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  def beat(from: 0, to: 12, playing: true, key: @key, **extra)
    post public_webinar_replay_beats_path(@webinar.slug),
         params: { session: key, from: from, to: to, playing: playing, **extra }, as: :json
  end

  test "sans accès au replay : 404, rien d'écrit" do
    assert_no_difference -> { ReplayView.count } do
      beat
    end
    assert_response :not_found
  end

  test "inscrit : la séance est à son inscription, quoi que dise le corps" do
    registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
    post public_webinar_replay_access_path(@webinar.slug), params: { t: registration.token }

    beat(user_id: 42, registration_id: 999)

    assert_response :no_content
    view = ReplayView.sole
    assert_equal registration, view.registration
    assert_nil view.user
    assert_in_delta 12.0, view.watched_seconds
  end

  test "compte undust : la séance est au compte" do
    user = spectator_user
    sign_in_as(user, groups: [])

    beat
    assert_response :no_content
    assert_equal user, ReplayView.sole.user
  end

  test "compte connecté ET inscription ouverte dans ce navigateur : la séance est au compte" do
    registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
    post public_webinar_replay_access_path(@webinar.slug), params: { t: registration.token }
    user = spectator_user
    sign_in_as(user, groups: [])

    beat
    assert_equal [ user, nil ], [ ReplayView.sole.user, ReplayView.sole.registration ]
  end

  test "battement mal formé : 422 ; corps non JSON : 415" do
    sign_in_as(spectator_user, groups: [])

    beat(key: "pas-un-uuid")
    assert_response :unprocessable_entity
    beat(from: "abc")
    assert_response :unprocessable_entity
    post public_webinar_replay_beats_path(@webinar.slug), params: { session: @key, from: 0, to: 1 }
    assert_response :unsupported_media_type
    assert_equal 0, ReplayView.count
  end

  test "séance d'une autre personne : 409" do
    other = User.create!(email: "autre@example.test", oidc_sub: "sub-autre")
    @replay.views.create!(user: other, session_key: @key, started_at: Time.current, last_seen_at: Time.current)
    sign_in_as(spectator_user, groups: [])

    beat
    assert_response :conflict
  end

  test "débit borné : au-delà de 20 battements par minute, 429" do
    # Compteurs des tests précédents du processus (même id de compte après
    # retour en arrière de la transaction) : expirés.
    travel 2.minutes
    sign_in_as(spectator_user, groups: [])

    20.times { beat(key: session_key) }
    assert_response :no_content
    beat(key: session_key)
    assert_response :too_many_requests
  end
end
