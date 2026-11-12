require "test_helper"

# Fiche d'une personne sur tous les cafés : une adresse = ses inscriptions
# (casse ignorée) et le compte de même adresse.
class PersonActivityTest < ActiveSupport::TestCase
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("person-activity")
    ENV["RECORDINGS_ROOT"] = @tmp
    @first = replay_cafe
    @second = replay_cafe
    @registration = confirmed_registration(@first.webinar, "ines@example.test", name: "Inès", crm_contact_id: "78")
    @other_registration = confirmed_registration(@second.webinar, "Ines@Example.test", name: "Inès L.")
    @user = User.create!(email: "INES@example.test", oidc_sub: "sub-ines")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  def view(replay, viewer, intervals)
    replay.views.create!(**ReplayView.viewer_attributes(viewer), session_key: session_key, started_at: 1.hour.ago,
                         last_seen_at: 1.hour.ago, watched_seconds: intervals.sum { |(a, b)| b - a }, intervals: intervals)
  end

  test "clé d'URL : par inscription ou compte, jamais l'adresse ; clé inconnue → nil" do
    assert_equal "r#{@registration.id}", PersonActivity.key_for(@registration)
    assert_equal "u#{@user.id}", PersonActivity.key_for(@user)
    assert_equal "ines@example.test", PersonActivity.find("u#{@user.id}").email
    assert_equal "ines@example.test", PersonActivity.find("r#{@other_registration.id}").email
    assert_nil PersonActivity.find("r0")
    assert_nil PersonActivity.find("ines@example.test")
  end

  test "inscriptions et compte de même adresse, fiche CRM de l'inscription qui l'a" do
    person = PersonActivity.find(PersonActivity.key_for(@registration))

    assert_equal [ @registration, @other_registration ].to_set, person.registrations.to_set
    assert_equal @user, person.user
    assert_equal "78", person.crm_contact_id
  end

  test "visionnages par replay : séances par inscription et par compte réunies" do
    view(@first, @registration, [ [ 0.0, 600.0 ] ])
    view(@first, @user, [ [ 300.0, 900.0 ] ])
    view(@second, @other_registration, [ [ 0.0, 60.0 ] ])

    viewings = PersonActivity.new("ines@example.test").viewings.to_h
    assert_equal [ @first, @second ].to_set, viewings.keys.to_set
    row = viewings.fetch(@first)
    assert_equal 2, row.views_count
    assert_equal 1200.0, row.watched_seconds
    assert_equal [ [ 0.0, 900.0 ] ], row.intervals
    assert_in_delta 900.0 / @first.duration, row.ratio, 0.001
  end

  test "questions : mentions et messages de la file Q&R, jamais un message effacé ; réponses aux sondages ; recherches" do
    webinar = @first.webinar
    identity = "viewer-#{@registration.id}"
    question = webinar.messages.create!(author_identity: identity, name: "Inès", body: "@animateur comment on fait ?")
    retained = webinar.messages.create!(author_identity: identity, name: "Inès", body: "Et pour le RAG souverain")
    webinar.messages.create!(author_identity: identity, name: "Inès", body: "Merci à tous")
    webinar.messages.create!(author_identity: identity, name: "x", body: CrmErasure::ERASED_BODY, kind: "question")
    QaItem.enqueue!(message: retained, label: "Comment faire un RAG souverain ?", source: "llm", llm_model: "glm-4-9b")
    poll = webinar.polls.create!(position: 1, kind: "choice", label: "Vous codez avec ?", options: %w[Claude Copilot])
    poll.responses.create!(respondent_identity: identity, registration: @registration, name: "Inès", value: [ 1 ])
    ReplaySearch.record!(query: "agents", author: @user, results_count: 2)
    ReplaySearch.record!(query: "rag", author: @registration, results_count: 0)

    person = PersonActivity.new("ines@example.test")
    assert_equal [ retained.body, question.body ].to_set, person.questions.map(&:body).to_set
    answer = person.answers.sole
    assert_equal [ poll, [ 1 ] ], [ answer.poll, answer.value ]
    assert_equal %w[agents rag].to_set, person.searches.map(&:query).to_set
  end
end
