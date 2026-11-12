require "test_helper"

# Journal des recherches : une ligne par requête, auteur compte OU
# inscription, résumés pour l'animation.
class ReplaySearchTest < ActiveSupport::TestCase
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-search-log")
    ENV["RECORDINGS_ROOT"] = @tmp
    @webinar = replay_cafe.webinar
    @user = spectator_user
    @registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  test "record! : requête nettoyée et normalisée, auteur compte ou inscription, jamais les deux" do
    by_user = ReplaySearch.record!(query: "  Sécurité   des agents ", author: @user, results_count: 3)
    by_registration = ReplaySearch.record!(query: "RAG", author: @registration, results_count: 0)

    assert_equal [ "Sécurité des agents", "securite des agents" ], [ by_user.query, by_user.normalized_query ]
    assert_equal @user, by_user.author
    assert_equal @registration, by_registration.author
    assert_raises(ActiveRecord::StatementInvalid) do
      ReplaySearch.create!(query: "x", normalized_query: "x", results_count: 0, user: @user, registration: @registration)
    end
  end

  test "résumés : les plus fréquentes d'abord, personnes distinctes ; sans résultat = la dernière n'a rien trouvé" do
    other = confirmed_registration(@webinar, "paul@example.test")
    ReplaySearch.record!(query: "agents", author: @user, results_count: 4)
    ReplaySearch.record!(query: "Agents", author: @registration, results_count: 4)
    ReplaySearch.record!(query: "agents", author: @registration, results_count: 4)
    ReplaySearch.record!(query: "impression 3D", author: other, results_count: 0)
    ReplaySearch.record!(query: "rag", author: other, results_count: 0)
    ReplaySearch.record!(query: "rag", author: @user, results_count: 2)

    frequent = ReplaySearch.summaries(since: 1.day.ago)
    assert_equal %w[agents rag impression\ 3d], frequent.map(&:normalized_query)
    assert_equal [ 3, 2 ], [ frequent.first.searches_count, frequent.first.people_count ]
    assert_equal [ "impression 3d" ], ReplaySearch.summaries(since: 1.day.ago, unanswered: true).map(&:normalized_query)
    assert_empty ReplaySearch.summaries(since: 1.minute.from_now)
  end

  test "l'effacement d'une inscription emporte ses recherches (clé étrangère en cascade)" do
    ReplaySearch.record!(query: "agents", author: @registration, results_count: 1)
    ReplaySearch.record!(query: "agents", author: @user, results_count: 1)

    CrmErasure.erase!("ines@example.test")

    assert_equal [ @user ], ReplaySearch.all.map(&:author)
  end
end
