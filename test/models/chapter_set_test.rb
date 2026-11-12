require "test_helper"

# Chapitres d'un café : proposition du LLM, relecture par l'animation,
# validation, thèmes, empreinte de la transcription, calage sur la vidéo.
class ChapterSetTest < ActiveSupport::TestCase
  include ReplayHelpers
  include ChapterHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("chapter-set")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  def draft(at, title, themes = [])
    ChapterSet::Draft.new(starts_at: Time.zone.parse("2030-01-17 #{at}"), title: title, themes: themes)
  end

  test "propose! remplace une proposition ; jamais un jeu validé, ni un jeu relu depuis read_at" do
    set = chapters_for(@webinar, [ [ "09:40:00", "Ancien", [ "x" ] ] ], validated: false)
    read_at = set.reload.updated_at

    assert set.propose!([ draft("09:45:00", "Agents en boucle", [ "agents" ]), draft("09:32:00", "Accueil") ],
                        outcome: "partial", model: "glm-4-9b", digest: "3:abc", read_at: read_at)
    set.reload
    assert_equal [ "Accueil", "Agents en boucle" ], set.chapters.map(&:title)
    assert_equal [ "partial", "glm-4-9b", "3:abc" ], [ set.llm_outcome, set.llm_model, set.transcript_digest ]
    assert set.generated_at

    stale = ChapterSet.find(set.id)
    read_at = stale.updated_at
    set.revise!([ draft("09:32:00", "Relu par l'animation") ], by: nil, validate: false, now: 1.minute.from_now)
    assert_not stale.propose!([ draft("09:32:00", "Du LLM") ], outcome: "ok", model: "glm-4-9b", digest: "x", read_at: read_at)
    assert_equal [ "Relu par l'animation" ], set.reload.chapters.map(&:title)

    set.update!(validated_at: Time.current)
    assert_not set.propose!([ draft("09:32:00", "Du LLM") ], outcome: "ok", model: "glm-4-9b", digest: "x")
    assert_equal [ "Relu par l'animation" ], set.reload.chapters.map(&:title)
    assert set.validated?
  end

  test "revise! : enregistrer garde l'état, valider montre aux spectateurs ; l'empreinte suit la transcription" do
    animateur = User.create!(email: "anim@example.test", oidc_sub: "sub-anim", admin: true)
    segment(@webinar, "09:32:00", "Bonjour à tous")
    set = @webinar.build_chapter_set

    set.revise!([ draft("09:32:00", "Accueil") ], by: animateur, validate: false)
    assert set.persisted?
    assert_not set.validated?
    assert_equal ChapterSet.transcript_digest(@webinar), set.transcript_digest
    assert_not set.stale?(ChapterSet.transcript_digest(@webinar))

    set.revise!([ draft("09:32:00", "Accueil"), draft("09:50:00", "Le videur de boîte", [ "agents" ]) ],
                by: animateur, validate: true)
    assert set.reload.validated?
    assert_equal animateur, set.validated_by
    assert_equal 2, set.chapters.count

    set.unvalidate!
    assert_not set.reload.validated?
    assert_nil set.validated_by
  end

  test "stale? : une transcription changée relance une proposition, jamais un jeu validé" do
    segment(@webinar, "09:32:00", "Bonjour")
    set = chapters_for(@webinar, [ [ "09:32:00", "Accueil" ] ], validated: false)
    digest = ChapterSet.transcript_digest(@webinar)
    assert_not set.stale?(digest)

    segment(@webinar, "09:33:00", "Reprise après coupure")
    assert set.stale?(ChapterSet.transcript_digest(@webinar))

    set.update!(validated_at: Time.current)
    assert_not set.stale?(ChapterSet.transcript_digest(@webinar))
  end

  test "thèmes du café : ceux des chapitres, dans l'ordre, sans doublon de casse ni d'accent" do
    set = chapters_for(@webinar, [ [ "09:32:00", "A", [ "Sécurité des agents", "RAG" ] ],
                                   [ "09:50:00", "B", [ "securite des  agents", "Données synthétiques" ] ] ])

    assert_equal [ "Sécurité des agents", "RAG", "Données synthétiques" ], set.themes
  end

  test "origine : le début de la vidéo du replay, sinon le premier segment" do
    set = @webinar.build_chapter_set
    assert_equal @replay.recording.started_at, set.origin

    other = ended_cafe
    segment(other, "09:35:12", "Bonjour")
    assert_equal Time.zone.parse("2030-01-17 09:35:12"), other.build_chapter_set.origin
    assert_nil ended_cafe.build_chapter_set.origin
  end

  test "chapitre : titre obligatoire et borné, thèmes = chaînes courtes, au plus quatre" do
    set = chapters_for(@webinar, [])
    assert_not set.chapters.build(starts_at: Time.current, title: "", themes: []).valid?
    assert_not set.chapters.build(starts_at: Time.current, title: "x" * 121, themes: []).valid?
    assert_not set.chapters.build(starts_at: Time.current, title: "ok", themes: %w[a b c d e]).valid?
    assert_not set.chapters.build(starts_at: Time.current, title: "ok", themes: [ 42 ]).valid?
    assert set.chapters.build(starts_at: Time.current, title: "ok", themes: [ "RAG" ]).valid?
  end

  test "clean_themes : nettoie, dédoublonne, borne ; ignore ce qui n'est pas une chaîne" do
    assert_equal [ "RAG souverain", "Agents" ],
                 Chapter.clean_themes([ "  RAG   souverain ", "rag souverain", "", 7, nil, "Agents" ])
    assert_equal Chapter::MAX_THEMES, Chapter.clean_themes(%w[a b c d e f]).size
    assert_equal Chapter::THEME_LIMIT, Chapter.clean_themes([ "x" * 200 ]).first.length
  end
end
