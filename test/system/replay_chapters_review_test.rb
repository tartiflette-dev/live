require "application_system_test_case"

# Relecture des chapitres par l'animation : la proposition du LLM est
# corrigée puis validée ; les spectateurs voient alors les chapitres et les
# thèmes, et l'animation retrouve le café dans la vue « thèmes ».
class ReplayChaptersReviewTest < ApplicationSystemTestCase
  include OidcSignIn
  include ReplayHelpers
  include ChapterHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("chapters-review")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    segment(@webinar, "09:41:06", "Le videur de boîte laisse passer les agents")
    chapters_for(@webinar, [ [ "09:31:06", "Introduction", [ "accueil" ] ], [ "09:41:06", "Développement et outils", [ "outils" ] ] ],
                 validated: false)
    @host = User.create!(email: "luc@example.test", oidc_sub: "sub-luc", admin: true)
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "corriger, ajouter, retirer, valider ; les spectateurs voient les chapitres ; la vue thèmes retrouve le café" do
    sign_in_as(@host, groups: [])
    visit webinar_replay_path(@webinar)
    click_link "Chapitres"
    assert_selector "[data-role=chapters-proposed]"

    fill_in "chapters_1_title", with: "Le videur de boîte"
    fill_in "chapters_1_themes", with: "agents, gatekeeper"
    check "chapters_0_remove"
    fill_in "chapters_2_timecode", with: "40:00"
    fill_in "chapters_2_title", with: "Questions de la salle"
    click_button "Valider : montrer aux spectateurs"

    assert_selector "[data-role=chapters-validated]"
    assert_field "chapters_0_title", with: "Le videur de boîte"
    assert_field "chapters_1_timecode", with: "40:00"

    visit public_webinar_replay_path(@webinar.slug)
    assert_selector "[data-role=replay-chapter]", count: 2
    assert_selector "[data-role=replay-chapter]", text: /10:00\s+Le videur de boîte/

    visit animation_themes_path(q: "gatekeeper")
    assert_selector "[data-role=theme-entry]", text: "Le videur de boîte"
  end
end
