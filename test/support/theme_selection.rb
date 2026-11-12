# Tests liés au thème undust (gem undust-charte : registre, manifest,
# chrome des pages animateur). Sous un autre thème (BRAND_THEME), la gem n'est
# pas chargée : ces tests sont sautés, avec le motif.
module ThemeSelection
  def require_undust_theme!
    skip "thème undust seulement (BRAND_THEME=#{Theme.selected})" unless Theme.undust?
  end
end

ActiveSupport::TestCase.include(ThemeSelection)
