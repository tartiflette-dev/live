require "test_helper"

# ChapterProposalJob — faux client LLM : aucun appel réseau, aucun GPU.
#
#   proposition enregistrée + index de recherche à jour ; transcription
#   inchangée → rien redemandé ; jeu validé → jamais remplacé ; LLM coupé ou
#   en panne → aucun chapitre, la proposition précédente reste ; jamais
#   pendant un direct.
class ChapterProposalJobTest < ActiveJob::TestCase
  include ReplayHelpers
  include ChapterHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("chapter-job")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    segment(@webinar, "09:32:00", "Bonjour, on parle de sécurité des agents aujourd'hui")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  def search(query)
    ReplaySearchIndex.search(query, [ @replay ]).count
  end

  test "proposition enregistrée (non validée), modèle et issue posés ; index de recherche à jour" do
    client = chapter_llm([ { "line" => 1, "title" => "Sécurité des agents", "themes" => [ "agents" ] } ])

    with_chapter_llm(client) { ChapterProposalJob.perform_now(@webinar.id) }

    set = @webinar.reload.chapter_set
    assert_equal [ "Sécurité des agents" ], set.chapters.map(&:title)
    assert_not set.validated?
    assert_equal [ "ok", "glm-4-9b" ], [ set.llm_outcome, set.llm_model ]
    assert_equal 1, search("securite")
  end

  test "transcription inchangée : rien n'est redemandé, sauf « force »" do
    client = chapter_llm
    with_chapter_llm(client) do
      ChapterProposalJob.perform_now(@webinar.id)
      ChapterProposalJob.perform_now(@webinar.id)
      assert_equal 1, client.prompts.size

      segment(@webinar, "09:33:00", "Un segment rattrapé après la fin")
      ChapterProposalJob.perform_now(@webinar.id)
      assert_equal 2, client.prompts.size

      ChapterProposalJob.perform_now(@webinar.id, force: true)
      assert_equal 3, client.prompts.size
    end
  end

  test "jeu validé : jamais remplacé, même avec « force » ; l'index est quand même remis à jour" do
    chapters_for(@webinar, [ [ "09:32:00", "Titre de l'animation", [ "relu" ] ] ], validated: true)
    client = chapter_llm

    with_chapter_llm(client) { ChapterProposalJob.perform_now(@webinar.id, force: true) }

    assert_empty client.prompts
    assert_equal [ "Titre de l'animation" ], @webinar.reload.chapter_set.chapters.map(&:title)
    assert_equal 1, search("relu")
  end

  test "LLM coupé : aucun chapitre, issue posée, empreinte non retenue (le passage suivant réessaie)" do
    ChapterProposalJob.perform_now(@webinar.id)

    set = @webinar.reload.chapter_set
    assert_equal "llm_disabled", set.llm_outcome
    assert_empty set.chapters
    assert_nil set.transcript_digest

    with_chapter_llm(chapter_llm) { ChapterProposalJob.perform_now(@webinar.id) }
    assert_equal 1, set.reload.chapters.count
  end

  test "LLM injoignable : la proposition précédente reste, issue « unreachable »" do
    with_chapter_llm(chapter_llm) { ChapterProposalJob.perform_now(@webinar.id, force: true) }
    with_chapter_llm(FakeLlmClient.new(error: LocalLlmClient::Error.new("HTTP 502"))) do
      ChapterProposalJob.perform_now(@webinar.id, force: true)
    end

    set = @webinar.reload.chapter_set
    assert_equal "unreachable", set.llm_outcome
    assert_equal [ "Accueil" ], set.chapters.map(&:title)
  end

  test "tous les passages hors délai : traité comme LLM injoignable, proposition et empreinte gardées" do
    with_chapter_llm(chapter_llm) { ChapterProposalJob.perform_now(@webinar.id) }
    digest = @webinar.reload.chapter_set.transcript_digest

    with_chapter_llm(FakeLlmClient.new(error: LocalLlmClient::Timeout.new("GPU occupé"))) do
      ChapterProposalJob.perform_now(@webinar.id, force: true)
    end

    set = @webinar.reload.chapter_set
    assert_equal "unreachable", set.llm_outcome
    assert_equal [ "Accueil" ], set.chapters.map(&:title)
    assert_equal digest, set.transcript_digest
  end

  test "course : l'animation valide pendant que le LLM lit → rien n'est écrit, son travail reste validé" do
    animateur = User.create!(email: "anim@example.test", oidc_sub: "sub-anim", admin: true)
    client = FakeLlmClient.new do
      ChapterSet.find_by!(webinar: @webinar).revise!(
        [ ChapterSet::Draft.new(starts_at: Time.zone.parse("2030-01-17 09:32:00"), title: "Titre de l'animation", themes: []) ],
        by: animateur, validate: true
      )
      { "continues" => false, "chapters" => [ { "line" => 1, "title" => "Titre du LLM", "themes" => [] } ] }
    end

    with_chapter_llm(client) { ChapterProposalJob.perform_now(@webinar.id, force: true) }

    set = @webinar.reload.chapter_set
    assert set.validated?
    assert_equal animateur, set.validated_by
    assert_equal [ "Titre de l'animation" ], set.chapters.map(&:title)
  end

  test "course : l'animation enregistre sans montrer pendant que le LLM lit → sa relecture est gardée" do
    client = FakeLlmClient.new do
      ChapterSet.find_by!(webinar: @webinar).revise!(
        [ ChapterSet::Draft.new(starts_at: Time.zone.parse("2030-01-17 09:32:00"), title: "Relu", themes: []) ],
        by: nil, validate: false
      )
      { "continues" => false, "chapters" => [ { "line" => 1, "title" => "Titre du LLM", "themes" => [] } ] }
    end

    with_chapter_llm(client) { ChapterProposalJob.perform_now(@webinar.id, force: true) }

    set = @webinar.reload.chapter_set
    assert_not set.validated?
    assert_equal [ "Relu" ], set.chapters.map(&:title)
  end

  test "sans transcription : issue « no_transcript », LLM pas appelé" do
    other = replay_cafe.webinar
    client = chapter_llm

    with_chapter_llm(client) { ChapterProposalJob.perform_now(other.id) }

    assert_equal "no_transcript", other.reload.chapter_set.llm_outcome
    assert_empty client.prompts
  end

  test "un direct qui commence pendant la proposition l'arrête : rien d'écrit, remis à plus tard" do
    segment(@webinar, "09:45:00", "Un second passage")
    client = FakeLlmClient.new do
      Webinar.create!(title: "Direct", starts_at: Time.current, host_sub: "sub-x", state: "live", started_at: Time.current)
      { "continues" => false, "chapters" => [ { "line" => 1, "title" => "Accueil", "themes" => [] } ] }
    end

    with_chapter_llm(client) do
      assert_enqueued_with(job: ChapterProposalJob, args: [ @webinar.id, { force: false } ]) do
        ChapterProposalJob.perform_now(@webinar.id)
      end
    end
    assert_equal 1, client.prompts.size
    assert_empty @webinar.reload.chapter_set.chapters
    assert_nil @webinar.chapter_set.generated_at
  end

  test "un autre direct en cours : remis à plus tard ; ce café repris : rien" do
    live = Webinar.create!(title: "En direct", starts_at: Time.current, host_sub: "sub-x", state: "live", started_at: Time.current)
    client = chapter_llm

    with_chapter_llm(client) do
      assert_enqueued_with(job: ChapterProposalJob, args: [ @webinar.id, { force: false } ]) do
        ChapterProposalJob.perform_now(@webinar.id)
      end
      assert_empty client.prompts

      live.update!(state: "ended", ended_at: Time.current)
      @webinar.update_columns(state: "live")
      assert_no_enqueued_jobs(only: ChapterProposalJob) { ChapterProposalJob.perform_now(@webinar.id) }
    end
    assert_empty client.prompts
    assert_nil @webinar.reload.chapter_set
  end
end
