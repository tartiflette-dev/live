require "test_helper"

# Recherche dans les replays (/replays?q=), chapitres et thèmes montrés aux
# spectateurs, instant de départ du lecteur.
class ReplaysSearchTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers
  include ChapterHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replays-search")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    @other = replay_cafe
    segment(@webinar, "09:41:06", "La sécurité des agents, c'est la carte bleue")
    segment(@other.webinar, "09:45:00", "La sécurité encore, dans un autre café")
    ReplaySearchIndex.refresh(@webinar)
    ReplaySearchIndex.refresh(@other.webinar)
    @registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "compte : tous les replays publiés ; résultat = café, extrait surligné, lien à l'instant ; journalisé" do
    user = spectator_user
    sign_in_as(user, groups: [ "live-spectateurs" ])

    assert_difference -> { ReplaySearch.count } do
      get replays_path(q: "securite")
    end

    assert_response :success
    assert_select "[data-role=replay-search-group]", 2
    assert_select "[data-replay='#{@webinar.slug}'] [data-role=replay-search-link][href=?]",
                  public_webinar_replay_path(@webinar.slug, instant: 600)
    assert_select "[data-role=replay-search-hit] mark", /sécurité/i
    search = ReplaySearch.last
    assert_equal [ user, "securite", 2 ], [ search.author, search.normalized_query, search.results_count ]
  end

  test "inscrit sans compte : seulement le replay de SON café ; la recherche porte son nom" do
    post public_webinar_replay_access_path(@webinar.slug), params: { t: @registration.token }

    get replays_path(q: "sécurité")

    assert_select "[data-role=replay-search-group]", 1
    assert_select "[data-replay='#{@other.webinar.slug}']", 0
    assert_equal @registration, ReplaySearch.last.author
  end

  test "sans résultat : dit et journalisé (demande non couverte) ; sans mot : ni recherche ni journal" do
    sign_in_as(spectator_user, groups: [])

    get replays_path(q: "impression 3D")
    assert_select "[data-role=replay-search-empty]"
    assert_equal 0, ReplaySearch.last.results_count

    assert_no_difference -> { ReplaySearch.count } do
      get replays_path(q: "  ?!  ")
      get replays_path(q: "")
      get replays_path(q: [ "tableau" ])
    end
    assert_response :success
  end

  test "anonyme : pas de recherche, la page de connexion" do
    assert_no_difference -> { ReplaySearch.count } do
      get replays_path(q: "securite")
    end
    assert_select "[data-role=replay-sign-in-page]"
  end

  test "débit borné : au-delà de 30 recherches par minute, 429 sans journal" do
    sign_in_as(spectator_user, groups: [])
    ReplaysController::SEARCH_RATE_LIMIT_STORE.synchronize(&:clear)

    30.times { get replays_path(q: "agents") }
    assert_no_difference -> { ReplaySearch.count } do
      get replays_path(q: "agents")
    end
    assert_response :too_many_requests
    get replays_path
    assert_response :success
  ensure
    ReplaysController::SEARCH_RATE_LIMIT_STORE.synchronize(&:clear)
  end

  test "chapitres validés : liste cliquable et thèmes dans le lecteur et sur /replays ; proposés : rien" do
    sign_in_as(spectator_user, groups: [])
    set = chapters_for(@webinar, [ [ "09:31:06", "Accueil", [ "accueil" ] ],
                                   [ "09:41:06", "Sécurité des agents", [ "carte bleue", "droits admin" ] ] ], validated: false)

    get public_webinar_replay_path(@webinar.slug)
    assert_select "[data-role=replay-chapter]", 0
    get replays_path
    assert_select "[data-role=replay-themes]", 0

    set.update!(validated_at: Time.current)
    get public_webinar_replay_path(@webinar.slug)
    assert_select "[data-role=replay-chapter]", 2
    assert_select "[data-role=replay-chapter] [data-seek='600.0']", /10:00\s+Sécurité des agents/
    assert_select "[data-replay-navigation][data-duration='#{@replay.duration.to_f.round(3)}']"
    get replays_path
    assert_equal [ "accueil", "carte bleue", "droits admin" ],
                 css_select("[data-replay='#{@webinar.slug}'] [data-role=replay-themes] a").map(&:text)
  end

  test "instant de départ : borné à la vidéo, ignoré s'il est illisible ; gardé à travers la connexion" do
    sign_in_as(spectator_user, groups: [])
    get public_webinar_replay_path(@webinar.slug, instant: "600")
    assert_select "[data-replay-navigation][data-start='600.0']"
    get public_webinar_replay_path(@webinar.slug, instant: "999999")
    assert_select "[data-replay-navigation][data-start='#{@replay.duration.to_f.round(3)}']"
    get public_webinar_replay_path(@webinar.slug, instant: "abc")
    assert_select "[data-replay-navigation][data-start]", 0

    delete sign_out_path
    get public_webinar_replay_path(@webinar.slug, instant: "600")
    assert_equal public_webinar_replay_path(@webinar.slug, instant: 600), session[:return_to]
  end
end
