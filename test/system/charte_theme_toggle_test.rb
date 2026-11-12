# frozen_string_literal: true

require "application_system_test_case"
# Thème undust seulement : la gem undust-charte fournit le contrat testé ;
# sous un autre thème, les tests sont sautés (comptés), pas retirés.
require "undust/charte/testing/theme_contract" if Theme.undust?

# Contrat `ThemeToggleContract` de la gem exécuté dans un vrai
# navigateur (JsSystemTestCase : rack_test ne supporte pas evaluate_script) :
# interrupteur clair/sombre (glyphes soleil/lune en viewBox 24, aria-pressed,
# data-undust-theme-toggle), clé `localStorage['u-theme']`, anti-FOUC avant
# la première feuille, color-scheme déclaré. La page de connexion rend le
# partial canonique `undust/charte/theme_toggle` via `shared/connexion_bas`
# — pas de session requise.
class CharteThemeToggleTest < JsSystemTestCase
  setup { require_undust_theme! }
  include Undust::Charte::Testing::ThemeContract if Theme.undust?
  include Undust::Charte::Testing::ThemeToggleContract if Theme.undust?

  test "l'interrupteur de thème de la gem tient son contrat et bascule les deux thèmes" do
    visit sign_in_path
    assert_theme_toggle!

    depart = page.evaluate_script("document.documentElement.dataset.theme")
    find("[data-undust-theme-toggle]").click
    autre = depart == "dark" ? "light" : "dark"
    assert_selector "html[data-theme='#{autre}']"
    assert_theme_toggle!
  end
end
