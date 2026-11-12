# Chapitre d'un café : titre court, instant de début et thèmes abordés
# (ChapterSet). L'instant est une heure réelle, comme les segments de
# transcription d'où il vient : le replay le recale sur sa vidéo
# (Replay#offset_of).
class Chapter < ApplicationRecord
  TITLE_LIMIT = 120
  THEME_LIMIT = 60
  MAX_THEMES = 4

  belongs_to :chapter_set, inverse_of: :chapters

  validates :title, presence: true, length: { maximum: TITLE_LIMIT }
  validates :starts_at, presence: true
  validate :themes_are_short_strings

  # Clé de regroupement d'un thème : casse, accents et espaces ignorés
  # (« Sécurité des agents » = « securite des  agents »).
  def self.theme_key(theme)
    I18n.transliterate(theme.to_s).downcase.squish
  end

  # Thèmes saisis ou proposés : chaînes nettoyées, sans doublon (clé), au
  # plus MAX_THEMES de THEME_LIMIT caractères.
  def self.clean_themes(list)
    Array(list).filter_map { |theme| theme.to_s.squish.truncate(THEME_LIMIT, omission: "").presence if theme.is_a?(String) }
               .uniq { |theme| theme_key(theme) }.first(MAX_THEMES)
  end

  private

  def themes_are_short_strings
    return if themes.is_a?(Array) && themes.size <= MAX_THEMES &&
              themes.all? { |theme| theme.is_a?(String) && theme.present? && theme.length <= THEME_LIMIT }

    errors.add(:themes, :invalid, message: "au plus #{MAX_THEMES} thèmes de #{THEME_LIMIT} caractères")
  end
end
