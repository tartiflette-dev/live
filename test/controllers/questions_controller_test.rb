require "test_helper"

# Toutes les questions, tous cafés confondus : direct et replay, filtrables
# par café et par origine ; chacun ne voit que les cafés qu'il anime ; le
# compteur des questions du replay à traiter est dans le chrome animateur.
class QuestionsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("questions")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @cafe = @replay.webinar
    @owner = User.find_by!(oidc_sub: @cafe.host_sub)
    message = @cafe.messages.create!(author_identity: "viewer-77", name: "Bob", body: "Et l'hébergement ?",
                                     created_at: @replay.recording.started_at + 300)
    @live = QaItem.enqueue!(message: message, label: "Peut-on auto-héberger ?", source: "llm")
    @live.update_columns(created_at: message.created_at)
    @asked = QaItem.ask_from_replay!(replay: @replay, viewer: confirmed_registration(@cafe, "ines@example.test", name: "Inès"),
                                     label: "Et pour les PME ?", at: 754.2)
    @asked.update_columns(created_at: message.created_at + 1.day)

    @other_owner = User.create!(email: "autre-hote@example.test", oidc_sub: "sub-autre-hote")
    @other_cafe = Webinar.create!(title: "Café d'un autre", starts_at: 2.days.ago, host_sub: @other_owner.oidc_sub, state: "ended")
    other_message = @other_cafe.messages.create!(author_identity: "viewer-78", name: "Zoé", body: "Secret ?")
    @foreign = QaItem.enqueue!(message: other_message, label: "Question d'un autre café", source: "mention")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  def listed
    css_select("[data-role=question] .question-libelle").map { |node| node.text.strip }
  end

  test "l'animateur voit les questions du direct et du replay de ses cafés, jamais celles des autres" do
    sign_in_as(@owner, groups: [])

    get questions_path

    assert_response :success
    assert_equal [ "Et pour les PME ?", "Peut-on auto-héberger ?" ], listed
    assert_select "[data-role=question][data-origin=replay]", text: /Inès/
    assert_select "[data-role=question][data-origin=direct]", text: /Bob/
    assert_select "[data-role=question-replay-link][href=?]", public_webinar_replay_path(@cafe.slug, instant: 754), text: /12:34/
    assert_select "[data-role=question-replay-link][href=?]", public_webinar_replay_path(@cafe.slug, instant: 300), text: /5:00/
  end

  test "filtres : par origine, par café ; un café qu'il n'anime pas ne montre rien" do
    sign_in_as(@owner, groups: [])

    get questions_path(origine: "replay")
    assert_equal [ "Et pour les PME ?" ], listed
    get questions_path(origine: "direct")
    assert_equal [ "Peut-on auto-héberger ?" ], listed
    get questions_path(cafe: @cafe.slug, origine: "replay")
    assert_equal [ "Et pour les PME ?" ], listed
    get questions_path(cafe: @other_cafe.slug)
    assert_equal [], listed
    assert_select "[data-role=questions-empty]"
  end

  test "compteur : questions du replay encore à traiter, dans la page et le lien du chrome" do
    sign_in_as(@owner, groups: [])

    get questions_path
    assert_select "[data-role=questions-replay-pending] strong", "1"
    assert_select "[data-role=chrome-questions]", "Questions (1)"

    @asked.answer!
    get questions_path
    assert_select "[data-role=questions-replay-pending]", count: 0
    assert_select "[data-role=chrome-questions]", "Questions"
  end

  test "spectateur connecté : 404, pas de lien dans le chrome ; anonyme : renvoyé à la connexion" do
    get questions_path
    assert_response :redirect

    sign_in_as(spectator_user, groups: [])
    get questions_path
    assert_response :not_found
    get replays_path
    assert_select "[data-role=chrome-questions]", count: 0
  end
end
