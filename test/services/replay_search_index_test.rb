require "test_helper"

# Index plein texte des replays (FTS5) : ce qui est indexé, ce qu'une
# requête trouve, dans quels replays, à quel instant.
class ReplaySearchIndexTest < ActiveSupport::TestCase
  include ReplayHelpers
  include ChapterHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-search")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    segment(@webinar, "09:41:06", "On parle de la sécurité des agents et de leurs droits admin")
    segment(@webinar, "09:50:00", "Le RAG souverain sur de petits modèles")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  def search(query, replays = [ @replay ])
    ReplaySearchIndex.search(query, replays)
  end

  test "accents et casse ignorés ; mots de 3 lettres et plus cherchés en préfixe ; tous les mots exigés" do
    ReplaySearchIndex.refresh(@webinar)

    assert_equal 1, search("SECURITE").count
    assert_equal 1, search("agent").count, "« agent » trouve « agents »"
    assert_equal 1, search("sécurité droits").count
    assert_equal 0, search("sécurité RAG").count
    assert_equal 0, search("zzz").count
  end

  test "résultat : café, instant dans la vidéo, extrait balisé sans HTML" do
    ReplaySearchIndex.refresh(@webinar)

    group = search("souverain").groups.sole
    hit = group.hits.sole
    assert_equal @replay, group.replay
    assert_equal "transcript", hit.kind
    assert_in_delta 18 * 60 + 54, hit.offset, 0.01, "09:50:00 dans une vidéo commencée à 09:31:06"
    assert_includes hit.extract, "#{ReplaySearchIndex::MARK_START}souverain#{ReplaySearchIndex::MARK_END}"
  end

  test "seuls les replays donnés (l'accès) ; un webinaire sans replay n'est pas indexé" do
    other = replay_cafe
    segment(other.webinar, "09:40:00", "La sécurité encore")
    ReplaySearchIndex.refresh(@webinar)
    ReplaySearchIndex.refresh(other.webinar)
    no_replay = ended_cafe
    segment(no_replay, "09:40:00", "sécurité sans replay")
    ReplaySearchIndex.refresh(no_replay)

    assert_equal [ @replay ], search("securite").groups.map(&:replay)
    assert_equal 2, search("securite", [ @replay, other ]).groups.size
    assert_equal 0, search("securite", []).count
    assert_equal 0, ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM replay_search_entries WHERE webinar_id = #{no_replay.id}"
    )
  end

  test "chapitres et thèmes indexés seulement une fois validés ; chapitres avant la transcription dans un café" do
    set = chapters_for(@webinar, [ [ "09:41:00", "Sécurité et confidentialité", [ "carte bleue" ] ] ], validated: false)
    ReplaySearchIndex.refresh(@webinar)
    assert_equal 0, search("carte bleue").count

    set.update!(validated_at: Time.current)
    ReplaySearchIndex.refresh(@webinar)
    assert_equal 1, search("carte bleue").count
    hits = search("securite").groups.sole.hits
    assert_equal %w[chapter transcript], hits.map(&:kind)
  end

  test "rafraîchir remplace les lignes du webinaire ; purge les retire" do
    ReplaySearchIndex.refresh(@webinar)
    ReplaySearchIndex.refresh(@webinar)
    assert_equal 1, search("souverain").count

    ReplaySearchIndex.purge([ @webinar.id ])
    assert_equal 0, search("souverain").count
  end

  test "aucune syntaxe FTS5 ne passe : guillemets, opérateurs, jokers sont des mots ou rien" do
    ReplaySearchIndex.refresh(@webinar)

    [ %("), %(sécurité" OR "), "NEAR(agents RAG)", "*", "-agents", "agents:", "{body}: x", "(" ].each do |query|
      assert_nothing_raised { search(query) }
    end
    assert_nil search("  ?! … "), "sans aucun mot : pas de recherche"
    assert_equal 0, search(%(agents" OR "RAG)).count, "OR reste un mot exigé, jamais un opérateur"
  end

  test "regroupement : au plus HITS_PER_REPLAY passages montrés, le total compté" do
    8.times { |index| segment(@webinar, format("10:%02d:00", index), "agents numéro #{index}") }
    ReplaySearchIndex.refresh(@webinar)

    group = search("agents").groups.sole
    assert_equal ReplaySearchIndex::HITS_PER_REPLAY, group.hits.size
    assert_equal 9, group.hits_count
    assert_equal group.hits.map(&:offset).sort, group.hits.map(&:offset)
  end

  test "saisie décomposée (NFD) : trouvée comme la forme composée" do
    ReplaySearchIndex.refresh(@webinar)

    assert_equal 1, search("sécurité".unicode_normalize(:nfd)).count
    assert_equal "securite", ReplaySearchIndex.normalize("Sécurité".unicode_normalize(:nfd))
  end

  test "normalize : requête du journal sans casse, accents ni espaces superflus" do
    assert_equal "securite des agents", ReplaySearchIndex.normalize("  Sécurité   des AGENTS ")
    assert_equal ReplaySearchIndex::QUERY_LIMIT, ReplaySearchIndex.normalize("a" * 500).length
  end
end
