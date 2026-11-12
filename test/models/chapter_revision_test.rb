require "test_helper"

# Saisie des chapitres par l'animation : instants relatifs à la vidéo,
# lignes vides ignorées, lignes retirées, erreurs sans rien enregistrer.
class ChapterRevisionTest < ActiveSupport::TestCase
  include ReplayHelpers
  include ChapterHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("chapter-revision")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @set = @replay.webinar.build_chapter_set
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  def revision(rows)
    params = ActionController::Parameters.new(rows.each_with_index.to_h { |row, index| [ index.to_s, row ] })
    ChapterRevision.from_params(@set, params)
  end

  test "instants « M:SS » et « H:MM:SS » relatifs au début de la vidéo ; triés ; thèmes nettoyés" do
    drafts = revision([
      { timecode: "1:02:09", title: "Clôture", themes: "" },
      { timecode: "4:05", title: "  Le   videur de boîte ", themes: "agents ; gatekeeper,  agents" },
      { timecode: "", title: "", themes: "" }
    ]).drafts

    assert_equal [ "Le videur de boîte", "Clôture" ], drafts.map(&:title)
    assert_equal @replay.recording.started_at + 245, drafts.first.starts_at
    assert_equal @replay.recording.started_at + 3729, drafts.last.starts_at
    assert_equal [ "agents", "gatekeeper" ], drafts.first.themes
  end

  test "ligne cochée « retirer » : écartée" do
    drafts = revision([ { timecode: "0:00", title: "Accueil" }, { timecode: "5:00", title: "Retiré", remove: "1" } ]).drafts
    assert_equal [ "Accueil" ], drafts.map(&:title)
  end

  test "instant illisible ou titre manquant : erreurs numérotées, aucun chapitre rendu" do
    form = revision([ { timecode: "douze", title: "Sans instant" }, { timecode: "3:00", title: "" },
                      { timecode: "3:75", title: "Secondes hors bornes" }, { timecode: "1:00", title: "x" * 121 } ])

    assert_nil form.drafts
    assert_equal [ 1, 2, 3, 4 ], form.errors.map { |message| message[/\ALigne (\d+)/, 1].to_i }
    assert_equal 4 + ChapterRevision::BLANK_ROWS, form.rows_for_display.size
  end

  test "écran : une ligne par chapitre enregistré, à son instant, plus des lignes vides" do
    set = chapters_for(@replay.webinar, [ [ "09:31:06", "Accueil", [ "accueil" ] ], [ "09:41:06", "Agents", [ "agents", "RAG" ] ] ])

    rows = ChapterRevision.for(set).rows
    assert_equal [ "0:00", "10:00", "", "", "" ], rows.map(&:timecode)
    assert_equal "agents, RAG", rows[1].themes
  end

  test "paramètres absents ou mal formés : aucune ligne" do
    assert_equal [], ChapterRevision.from_params(@set, nil).drafts
    assert_equal [], ChapterRevision.from_params(@set, ActionController::Parameters.new("0" => "texte")).drafts
  end
end
