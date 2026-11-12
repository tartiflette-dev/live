# Chapitres tels que l'animation les saisit dans l'écran de relecture
# (WebinarChaptersController) : une ligne indexée par chapitre — instant dans la vidéo
# (« 12:34 » ou « 1:02:09 »), titre, thèmes séparés par des virgules, case
# « retirer ». Une ligne sans instant ni titre est ignorée (lignes vides
# d'ajout) ; une ligne à moitié remplie ou à l'instant illisible est une
# erreur, et rien n'est enregistré.
#
# Les instants sont relatifs à `origin` (ChapterSet#origin, le début de la
# vidéo) ; les chapitres enregistrés portent l'heure réelle.
class ChapterRevision
  Row = Data.define(:timecode, :title, :themes, :remove) do
    def blank? = timecode.blank? && title.blank?
  end

  BLANK_ROWS = 3
  TIMECODE = /\A(?:(?<hours>\d{1,2}):)?(?<minutes>\d{1,3}):(?<seconds>[0-5]\d)\z/

  attr_reader :rows, :errors

  # Lignes de l'écran pour les chapitres enregistrés, plus BLANK_ROWS vides.
  def self.for(chapter_set)
    origin = chapter_set.origin
    rows = chapter_set.chapters.map do |chapter|
      Row.new(timecode: DurationFormat.timecode(chapter.starts_at - origin), title: chapter.title,
              themes: chapter.themes.join(", "), remove: false)
    end
    new(chapter_set, rows + blank_rows)
  end

  # @param params [ActionController::Parameters, nil] lignes du formulaire,
  #   indexées (`chapters[0][title]`…)
  def self.from_params(chapter_set, params)
    return new(chapter_set, []) unless params.is_a?(ActionController::Parameters)

    keys = params.keys.sort_by(&:to_i).first(ChapterProposal::MAX_CHAPTERS + BLANK_ROWS)
    rows = keys.filter_map do |key|
      row = params[key]
      next unless row.is_a?(ActionController::Parameters)

      row = row.permit(:timecode, :title, :themes, :remove)
      Row.new(timecode: row[:timecode].to_s.strip, title: row[:title].to_s.squish, themes: row[:themes].to_s,
              remove: row[:remove] == "1")
    end
    new(chapter_set, rows)
  end

  def self.blank_rows
    Array.new(BLANK_ROWS) { Row.new(timecode: "", title: "", themes: "", remove: false) }
  end

  def initialize(chapter_set, rows)
    @chapter_set = chapter_set
    @rows = rows
    @errors = []
  end

  # @return [Array<ChapterSet::Draft>, nil] nil si une ligne est invalide
  def drafts
    origin = @chapter_set.origin
    @errors = []
    kept = @rows.each_with_index.filter_map do |row, index|
      next if row.remove || row.blank?

      draft(row, index + 1, origin)
    end
    @errors.empty? ? kept.sort_by(&:starts_at) : nil
  end

  # Lignes à réafficher après une erreur : celles saisies, plus des vides.
  def rows_for_display
    @rows.reject(&:blank?) + self.class.blank_rows
  end

  private

  def draft(row, number, origin)
    seconds = parse(row.timecode)
    @errors << "Ligne #{number} : instant illisible (ex. 12:34 ou 1:02:09)." if seconds.nil?
    @errors << "Ligne #{number} : titre manquant." if row.title.blank?
    @errors << "Ligne #{number} : titre de plus de #{Chapter::TITLE_LIMIT} caractères." if row.title.length > Chapter::TITLE_LIMIT
    return if seconds.nil? || row.title.blank? || row.title.length > Chapter::TITLE_LIMIT

    ChapterSet::Draft.new(starts_at: origin + seconds, title: row.title,
                          themes: Chapter.clean_themes(row.themes.split(/[,;]/)))
  end

  def parse(timecode)
    match = TIMECODE.match(timecode)
    return nil unless match

    match[:hours].to_i * 3600 + match[:minutes].to_i * 60 + match[:seconds].to_i
  end
end
