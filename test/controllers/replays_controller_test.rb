require "test_helper"

# Accès aux replays à deux étages : un compte undust voit tous les replays
# publiés ; une inscription confirmée, par son lien personnel puis le bouton
# de la page, voit celui de son café seulement.
class ReplaysControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replays-controller")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    @registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  def open_with_personal_link(registration = @registration, webinar = @webinar)
    post public_webinar_replay_access_path(webinar.slug), params: { t: registration.token }
  end

  # ---- Sans identité ----

  test "anonyme : page de connexion, qui ramène sur le replay après Pocket ID" do
    get public_webinar_replay_path(@webinar.slug)

    assert_response :success
    assert_select "[data-role=replay-sign-in-page]"
    assert_select "video", count: 0
    assert_equal public_webinar_replay_path(@webinar.slug), session[:return_to]
  end

  test "anonyme : /replays propose la connexion" do
    get replays_path
    assert_select "[data-role=replay-sign-in-page]"
  end

  test "replay non publié ou inexistant : 404, même pour un compte undust" do
    @replay.unpublish!
    get public_webinar_replay_path(@webinar.slug)
    assert_response :not_found

    sign_in_as(spectator_user, groups: [ "live-spectateurs" ])
    get public_webinar_replay_path(@webinar.slug)
    assert_response :not_found
    get public_webinar_replay_path("inconnu")
    assert_response :not_found
  end

  # ---- Compte undust ----

  test "compte spectateur : lecteur, sous-titres et liste de tous les replays publiés" do
    add_segment(@webinar, "Bonjour", at: @replay.recording.started_at + 5)
    hidden = replay_cafe(published: false)
    sign_in_as(spectator_user, groups: [ "live-spectateurs" ])

    get public_webinar_replay_path(@webinar.slug)
    assert_response :success
    assert_select "video[src=?]", public_webinar_replay_video_path(@webinar.slug)
    assert_select "track[kind=subtitles][src=?]", public_webinar_replay_subtitles_path(@webinar.slug)
    assert_select "[data-replay-subtitles]"
    assert_select "[data-replay-player][data-beats-url=?]", public_webinar_replay_beats_path(@webinar.slug)
    assert_select "[data-role=replay-account-invitation]", count: 0

    get replays_path
    assert_select "[data-replay=?]", @webinar.slug
    assert_select "[data-replay=?]", hidden.webinar.slug, count: 0
  end

  test "l'animation voit son replay avant publication" do
    @replay.unpublish!
    sign_in_as(User.find_by!(oidc_sub: @webinar.host_sub), groups: [])

    get public_webinar_replay_path(@webinar.slug)
    assert_response :success
    assert_select "[data-role=replay-unpublished]"
  end

  # ---- Inscription confirmée ----

  test "lien personnel : GET sans effet (page à bouton), le POST ouvre le replay sans jeton dans l'URL" do
    get public_webinar_replay_path(@webinar.slug, t: @registration.token)
    assert_response :success
    assert_select "[data-role=replay-access] form[action=?]", public_webinar_replay_access_path(@webinar.slug)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "strict-origin", response.headers["Referrer-Policy"]
    assert_nil cookies["replay_access_#{@webinar.id}"], "un GET ne donne aucune identité"

    get public_webinar_replay_path(@webinar.slug)
    assert_select "[data-role=replay-sign-in-page]"

    open_with_personal_link
    assert_redirected_to public_webinar_replay_path(@webinar.slug)
    follow_redirect!
    assert_select "video"
    assert_select "[data-role=replay-account-invitation]"
    assert_equal replays_path, session[:return_to], "se connecter depuis l'invitation mène à tous les replays"
  end

  test "lien personnel déjà ouvert par ce navigateur : droit au lecteur" do
    open_with_personal_link
    get public_webinar_replay_path(@webinar.slug, t: @registration.token)
    assert_redirected_to public_webinar_replay_path(@webinar.slug)
  end

  test "l'inscription ouvre le replay de SON café, pas celui d'un autre" do
    other = replay_cafe
    open_with_personal_link

    get public_webinar_replay_path(other.webinar.slug)
    assert_select "[data-role=replay-sign-in-page]"
    get public_webinar_replay_video_path(other.webinar.slug)
    assert_response :not_found

    get replays_path
    assert_select "[data-replay=?]", @webinar.slug
    assert_select "[data-replay=?]", other.webinar.slug, count: 0
    assert_select "[data-role=replay-account-invitation]"
  end

  test "le jeton d'un autre café n'ouvre pas ce replay" do
    other = replay_cafe
    foreign = confirmed_registration(other.webinar, "autre@example.test")

    post public_webinar_replay_access_path(@webinar.slug), params: { t: foreign.token }
    assert_response :not_found
  end

  test "inscription non confirmée, retirée de la salle ou pierre tombale : le lien n'ouvre rien" do
    pending = @webinar.registrations.create!(email: "attente@example.test", name: "Attente")
    removed = confirmed_registration(@webinar, "retire@example.test")
    removed.update!(room_removed_at: Time.current)

    [ pending, removed ].each do |registration|
      get public_webinar_replay_path(@webinar.slug, t: registration.token)
      assert_response :not_found
      assert_select "[data-role=replay-invalid-link]"
      open_with_personal_link(registration)
      assert_response :not_found
    end
  end

  test "retirée de la salle APRÈS l'ouverture : le cookie n'ouvre plus le replay" do
    open_with_personal_link
    @registration.update!(room_removed_at: Time.current)

    get public_webinar_replay_path(@webinar.slug)
    assert_select "[data-role=replay-sign-in-page]"
  end

  test "un navigateur qui porte déjà une autre inscription la garde" do
    open_with_personal_link
    other = confirmed_registration(@webinar, "tiers@example.test", name: "Tiers")

    open_with_personal_link(other)
    follow_redirect!
    assert_match "garde", flash[:alert].to_s

    post public_webinar_replay_beats_path(@webinar.slug), params: { session: session_key, from: 0, to: 5, playing: true }, as: :json
    assert_equal @registration, ReplayView.last.registration
  end

  test "replay retiré : le lien d'un inscrit n'ouvre plus rien" do
    open_with_personal_link
    @replay.unpublish!

    get public_webinar_replay_path(@webinar.slug)
    assert_response :not_found
  end

  test "le jeton du lien n'apparaît pas dans le journal" do
    log = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    begin
      get public_webinar_replay_path(@webinar.slug, t: @registration.token)
      open_with_personal_link
    ensure
      Rails.logger = previous
    end

    assert_not_includes log.string, @registration.token
  end

  test "lien de création de compte : affiché seulement s'il pointe vers notre Pocket ID" do
    open_with_personal_link

    with_env("LIVE_SPECTATOR_SIGNUP_URL" => "https://id.example.test/st/abc") do
      get public_webinar_replay_path(@webinar.slug)
      assert_select "a[data-role=replay-signup][href=?]", "https://id.example.test/st/abc"
    end
    with_env("LIVE_SPECTATOR_SIGNUP_URL" => "https://ailleurs.example/st/abc") do
      get public_webinar_replay_path(@webinar.slug)
      assert_select "a[data-role=replay-signup]", count: 0
      assert_select "[data-role=replay-sign-in]"
    end
  end

  private

  def with_env(values)
    previous = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
