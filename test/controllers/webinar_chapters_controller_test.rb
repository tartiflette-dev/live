require "test_helper"

# Relecture des chapitres côté animation : propriétaire et animateurs du
# projet ; corriger, valider, retirer, redemander une proposition.
class WebinarChaptersControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers
  include ChapterHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("webinar-chapters")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    @owner = User.find_by!(oidc_sub: @webinar.host_sub)
    segment(@webinar, "09:41:06", "On parle du videur de boîte")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  def rows(*list)
    list.each_with_index.to_h { |(timecode, title, themes), index| [ index.to_s, { timecode: timecode, title: title, themes: themes.to_s } ] }
  end

  test "écran : la proposition du LLM à relire, sans rien écrire en base" do
    sign_in_as(@owner, groups: [])

    assert_no_difference -> { ChapterSet.count } do
      get webinar_chapters_path(@webinar)
    end
    assert_response :success
    assert_select "[data-role=chapters-llm]", /Pas encore de proposition/
    assert_select "[data-role=chapter-row]", ChapterRevision::BLANK_ROWS

    chapters_for(@webinar, [ [ "09:31:06", "Accueil", [ "accueil" ] ] ], validated: false)
    get webinar_chapters_path(@webinar)
    assert_select "[data-role=chapters-proposed]"
    assert_select "input[name='chapters[0][title]'][value=Accueil]"
    assert_select "input[name='chapters[0][timecode]'][value='0:00']"
  end

  test "valider : les chapitres sont montrés aux spectateurs et trouvés par la recherche" do
    sign_in_as(@owner, groups: [])

    patch webinar_chapters_path(@webinar),
          params: { validate: "1", chapters: rows([ "0:00", "Accueil", "" ], [ "10:00", "Le videur de boîte", "agents, gatekeeper" ]) }

    assert_redirected_to webinar_chapters_path(@webinar)
    set = @webinar.reload.chapter_set
    assert set.validated?
    assert_equal @owner, set.validated_by
    assert_equal [ "Accueil", "Le videur de boîte" ], set.chapters.map(&:title)
    assert_equal [ "agents", "gatekeeper" ], set.chapters.last.themes
    assert_equal 1, ReplaySearchIndex.search("gatekeeper", [ @replay ]).count
  end

  test "enregistrer sans montrer : le jeu reste une proposition ; erreurs : 422, rien n'est changé" do
    sign_in_as(@owner, groups: [])
    patch webinar_chapters_path(@webinar), params: { save: "1", chapters: rows([ "0:00", "Accueil", "" ]) }
    assert_not @webinar.reload.chapter_set.validated?

    patch webinar_chapters_path(@webinar), params: { validate: "1", chapters: rows([ "midi", "Mauvais instant", "" ]) }
    assert_response :unprocessable_entity
    assert_select "[data-role=chapters-errors]", /Ligne 1 : instant illisible/
    assert_select "input[name='chapters[0][title]'][value='Mauvais instant']"
    assert_equal [ "Accueil" ], @webinar.reload.chapter_set.chapters.map(&:title)
    assert_not @webinar.chapter_set.validated?
  end

  test "jeu validé : « Enregistrer (reste visible) », jamais « sans montrer » ; l'écran dit qu'il reste visible" do
    sign_in_as(@owner, groups: [])
    chapters_for(@webinar, [ [ "09:31:06", "Accueil", [ "accueil" ] ] ], validated: true)

    get webinar_chapters_path(@webinar)
    assert_select "[data-role=chapters-save][value=?]", "Enregistrer (reste visible)"
    assert_select "[data-role=chapters-validate]", 0
    assert_no_match(/Enregistrer sans montrer/, response.body)

    patch webinar_chapters_path(@webinar), params: { save: "1", chapters: rows([ "0:00", "Accueil corrigé", "" ]) }
    assert_equal "Chapitres enregistrés : toujours visibles des spectateurs.", flash[:notice]
    assert @webinar.reload.chapter_set.validated?
  end

  test "retirer aux spectateurs ; redemander une proposition : refusée tant que validés, sinon enfilée" do
    sign_in_as(@owner, groups: [])
    chapters_for(@webinar, [ [ "09:31:06", "Accueil", [ "accueil" ] ] ], validated: true)

    assert_no_enqueued_jobs(only: ChapterProposalJob) { post propose_webinar_chapters_path(@webinar) }
    assert_equal "Chapitres validés : retire-les aux spectateurs avant d'en redemander.", flash[:alert]

    post unvalidate_webinar_chapters_path(@webinar)
    assert_not @webinar.reload.chapter_set.validated?
    assert_equal 0, ReplaySearchIndex.search("accueil", [ @replay ]).count

    assert_enqueued_with(job: ChapterProposalJob, args: [ @webinar.id, { force: true } ]) do
      post propose_webinar_chapters_path(@webinar)
    end
  end

  test "animateur du projet : accès ; spectateur, propriétaire d'un autre café ou co-animateur de ce café : 404" do
    sign_in_as(User.create!(email: "projet@example.test", oidc_sub: "sub-projet", admin: true), groups: [])
    get webinar_chapters_path(@webinar)
    assert_response :success

    other_owner = User.create!(email: "autre@example.test", oidc_sub: "sub-autre")
    Webinar.create!(title: "Son café", starts_at: 1.day.from_now, host_sub: other_owner.oidc_sub)
    co_host = User.create!(email: "co@example.test", oidc_sub: "sub-co", email_verified: true)
    @webinar.webinar_hosts.create!(email: co_host.email, invited_by_sub: @owner.oidc_sub)
    [ spectator_user, other_owner, co_host ].each do |user|
      sign_in_as(user, groups: [])
      get webinar_chapters_path(@webinar)
      assert_response :not_found
      patch webinar_chapters_path(@webinar), params: { validate: "1", chapters: rows([ "0:00", "Intrus", "" ]) }
      assert_response :not_found
    end
    assert_nil @webinar.reload.chapter_set
  end

  test "la publication du replay enfile la proposition des chapitres" do
    replay = @replay
    replay.unpublish!
    sign_in_as(@owner, groups: [])

    assert_enqueued_with(job: ChapterProposalJob, args: [ @webinar.id ]) do
      post publish_webinar_replay_path(@webinar)
    end
    assert replay.reload.published?
  end
end
