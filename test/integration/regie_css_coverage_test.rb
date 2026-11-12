require "test_helper"

# Régie : garde mécanique, sœur de room_css_coverage_test.
# La page est sous le chrome undust ; ses classes `regie…` vivent dans
# regie.css, chargée par la seule page régie. Une classe utilisée sans
# règle, une feuille non chargée, un hex hors tokens ou une règle qui fuit
# hors de la régie font rougir ce test.
class RegieCssCoverageTest < ActiveSupport::TestCase
  STYLESHEET = Rails.root.join("app/assets/stylesheets/regie.css")
  VIEW = Rails.root.join("app/views/webinar_regies/show.html.erb")
  SOURCES = [ VIEW, Rails.root.join("app/javascript/rooms/regie.jsx"),
              Rails.root.join("app/javascript/rooms/camera_quality_console.jsx") ].freeze

  def css_rules
    STYLESHEET.read.gsub(%r{/\*.*?\*/}m, "")
  end

  test "la page régie charge regie.css" do
    assert_match(/stylesheet_link_tag[ (]"regie"/, VIEW.read)
  end

  test "toute classe regie… utilisée a une définition dans regie.css" do
    used = SOURCES.flat_map { |path| path.read.scan(/class(?:Name)?=["']([^"']+)["']/).flatten }
                  .flat_map(&:split).uniq.select { |name| name.start_with?("regie") }
    assert used.any?, "aucune classe regie trouvée — scan cassé, pas un succès"

    undefined = used.reject { |name| css_rules.match?(/\.#{Regexp.escape(name)}(?![\w-])/) }
    assert_empty undefined, "classes de la régie sans règle dans regie.css : #{undefined.inspect}"
  end

  test "regie.css ne consomme que des tokens et reste scopée à la régie" do
    assert_empty css_rules.scan(/#[0-9a-fA-F]{3,8}\b/), "hex hors tokens dans regie.css"

    selectors = css_rules.scan(/([^{}]+)\{/).flatten.flat_map { |prelude| prelude.split(",") }.map(&:strip)
                         .reject { |selector| selector.empty? || selector.start_with?("@") }
                         .reject { |selector| selector.match?(/\A(?:from|to|\d+(?:\.\d+)?%(?:\s*,\s*\d+%)*)\z/) }
    # Seule exception : la fenêtre qui CONTIENT la régie (élargie sur écran large).
    leaking = selectors.reject { |selector| selector.match?(/\A(?:\.chrome-fenetre\s+)?\.regie/) }
                       .reject { |selector| selector == ".chrome-fenetre:has(> .regie)" }
    assert_empty leaking, "règles hors de la régie dans regie.css : #{leaking.inspect}"
  end
end
