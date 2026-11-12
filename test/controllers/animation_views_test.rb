require "test_helper"

# Vues transverses de l'animation du projet : thèmes à travers les cafés,
# journal des recherches, fiche d'une personne. Animateurs du projet
# seulement ; tout autre compte reçoit 404.
class AnimationViewsTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers
  include ChapterHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("animation-views")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    @host = User.create!(email: "luc@example.test", oidc_sub: "sub-luc", admin: true)
    @registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès", crm_contact_id: "78")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  def paths
    [ animation_themes_path, animation_searches_path, animation_person_path(PersonActivity.key_for(@registration)) ]
  end

  test "spectateur, propriétaire d'un café sans être animateur du projet : 404 partout" do
    owner = User.find_by!(oidc_sub: @webinar.host_sub)
    [ spectator_user, owner ].each do |user|
      sign_in_as(user, groups: [])
      paths.each do |path|
        get path
        assert_response :not_found, path
      end
    end
  end

  test "thèmes : les cafés qui en ont parlé, lien à l'instant ; proposés marqués ; filtre et passages de transcription" do
    chapters_for(@webinar, [ [ "09:41:06", "Sécurité des agents", [ "Sécurité des agents" ] ] ], validated: true)
    other = replay_cafe(published: false).webinar
    chapters_for(other, [ [ "09:35:00", "Agents en boucle", [ "securite des agents", "RAG" ] ] ], validated: false)
    segment(other, "09:36:00", "Un RAG sur de petits modèles")
    ReplaySearchIndex.refresh(other)
    sign_in_as(@host, groups: [])

    get animation_themes_path
    assert_response :success
    theme = css_select("[data-theme='securite des agents']").sole
    assert_equal 2, theme.css("[data-role=theme-entry]").size
    assert_includes theme.text, "2 cafés"
    assert_includes theme.text, "chapitre proposé, pas encore validé"
    assert_select "[data-theme='securite des agents'] a[href=?]", public_webinar_replay_path(@webinar.slug, instant: 600)

    get animation_themes_path(q: "rag")
    assert_select "[data-role=theme]", 1
    assert_select "[data-role=replay-search-group][data-replay='#{other.slug}']", 1, "replay non publié compris"
    assert_no_difference(-> { ReplaySearch.count }) { get animation_themes_path(q: "agents") }
  end

  test "recherches : sans résultat, fréquentes, dernières avec leur auteur (lien vers sa fiche)" do
    ReplaySearch.record!(query: "impression 3D", author: @registration, results_count: 0)
    ReplaySearch.record!(query: "agents", author: @host, results_count: 3)
    ReplaySearch.record!(query: "agents", author: @registration, results_count: 3)
    sign_in_as(@host, groups: [])

    get animation_searches_path
    assert_response :success
    assert_equal [ "impression 3D" ], css_select("[data-role=searches-unanswered] [data-role=search-summary] td:first-child").map { |td| td.text.strip }
    assert_equal [ "agents", "impression 3D" ], css_select("[data-role=searches-frequent] [data-role=search-summary] td:first-child").map { |td| td.text.strip }
    assert_select "[data-role=searches-recent] a[href=?]", animation_person_path(PersonActivity.key_for(@registration))

    get animation_searches_path(periode: "inconnue")
    assert_response :success
  end

  test "fiche d'une personne : visionnages, inscriptions, recherches, lien CRM vers le CRM ; clé inconnue : 404" do
    @replay.views.create!(registration: @registration, session_key: session_key, started_at: 1.hour.ago,
                          last_seen_at: 1.hour.ago, watched_seconds: 300, intervals: [ [ 0.0, 300.0 ] ])
    ReplaySearch.record!(query: "agents", author: @registration, results_count: 3)
    sign_in_as(@host, groups: [])

    with_env("CRM_BASE_URL" => "https://ops.example.test/") do
      get animation_person_path(PersonActivity.key_for(@registration))
    end
    assert_response :success
    assert_select "[data-role=person-email]", /ines@example.test/
    assert_select "[data-role=person-viewing]", 1
    assert_select "[data-role=person-searches]", /agents/
    assert_select "[data-role=person-crm][href=?]", "https://ops.example.test/contacts/78"

    get animation_person_path("ines@example.test")
    assert_response :not_found
  end

  test "statistiques du replay : le nom mène à la fiche pour un animateur du projet seulement" do
    @replay.views.create!(registration: @registration, session_key: session_key, started_at: 1.hour.ago,
                          last_seen_at: 1.hour.ago, watched_seconds: 300, intervals: [ [ 0.0, 300.0 ] ])

    sign_in_as(@host, groups: [])
    get webinar_replay_path(@webinar)
    assert_select "[data-role=replay-stats-person][href=?]", animation_person_path(PersonActivity.key_for(@registration))

    sign_in_as(User.find_by!(oidc_sub: @webinar.host_sub), groups: [])
    get webinar_replay_path(@webinar)
    assert_select "[data-role=replay-stats-person]", 0
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
