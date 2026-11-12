require "test_helper"

# Tout lien qui ouvre un autre onglet l'annonce aux lecteurs d'écran.
# `participant_consent.jsx` est gelé par le lot de publication : le
# signaler dans le rapport, ne pas le modifier ici.
class NewTabAnnouncementTest < ActiveSupport::TestCase
  SKIP = [ "app/javascript/rooms/participant_consent.jsx" ].freeze
  HINT = "(nouvel onglet)"

  test "chaque target=_blank hors fichier gelé porte le texte masqué" do
    offenders = Dir[Rails.root.join("app/**/*.{erb,jsx,js,html}")].flat_map { |path|
      rel = path.delete_prefix("#{Rails.root}/")
      next [] if SKIP.include?(rel) || rel.start_with?("app/assets/builds/")

      File.readlines(path).each_with_index.filter_map { |line, index|
        next unless line.match?(/target=["']_blank["']|target:\s*["']_blank["']/)

        window = File.readlines(path)[[ index - 3, 0 ].max..index + 4].join
        next if window.include?(HINT) || window.include?("new_tab_hint") || window.include?("NewTabHint")

        "#{rel}:#{index + 1}"
      }
    }

    assert_empty offenders, "lien nouvel onglet sans « (nouvel onglet) » : #{offenders.join(", ")}"
  end

  test "les deux thèmes définissent .visually-hidden" do
    pack = Rails.root.join("app/assets/tailwind/theme_default.css").read
    assert_match(/\.visually-hidden\s*\{/, pack)

    undust = Rails.root.join("app/assets/tailwind/undust_composants.css")
    skip "copie charte absente (pack sans gem)" unless undust.file?
    assert_match(/\.visually-hidden\s*\{/, undust.read)
  end
end
