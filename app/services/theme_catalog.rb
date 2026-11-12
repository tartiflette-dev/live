# frozen_string_literal: true

# Thèmes abordés à travers les cafés, pour l'animation du projet
# (Animation::ThemesController) : « les jours où on a parlé de X ». Un thème
# = les thèmes des chapitres qui ont la même clé (Chapter.theme_key : casse,
# accents et espaces ignorés), libellé sous sa forme la plus fréquente, avec
# chaque chapitre qui le porte. Les chapitres proposés mais pas encore
# validés y figurent, marqués comme tels : l'animation les voit, pas les
# spectateurs.
class ThemeCatalog
  Entry = Data.define(:webinar, :chapter, :validated)
  Theme = Data.define(:key, :label, :entries) do
    def webinars = entries.map(&:webinar).uniq
  end

  # @param filter [String, nil] ne garde que les thèmes dont la clé contient
  #   celle du filtre
  # @return [Array<Theme>] les plus partagés entre cafés d'abord
  def self.themes(filter: nil)
    wanted = filter.present? ? Chapter.theme_key(filter) : nil
    tagged = ChapterSet.includes(:chapters, webinar: { replay: :recording }).flat_map do |set|
      set.chapters.flat_map do |chapter|
        chapter.themes.map { |theme| [ Chapter.theme_key(theme), theme, Entry.new(set.webinar, chapter, set.validated?) ] }
      end
    end
    tagged.select { |key, _, _| wanted.nil? || key.include?(wanted) }.group_by(&:first).map do |key, list|
      label = list.map { |_, theme, _| theme }.tally.max_by { |_, count| count }.first
      entries = list.map(&:last).sort_by { |entry| [ -entry.webinar.starts_at.to_i, entry.chapter.starts_at ] }
      Theme.new(key: key, label: label, entries: entries)
    end.sort_by { |theme| [ -theme.webinars.size, theme.key ] }
  end
end
