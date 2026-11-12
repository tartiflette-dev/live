# frozen_string_literal: true

# Façade des vues vers le thème choisi (lib/theme.rb) : une vue appelle
# `theme_*`, jamais la gem undust-charte directement. Les partials de la gem
# (chrome haut et bas, anti-FOUC, interrupteur) passent, eux, par les partials
# de dispatch app/views/theme/ : `render "theme/chrome_bas", …`.
module ThemeHelper
  include Theme.current.view_helper

  def theme_fonts_tag = Theme.current.fonts_tag(self)
  def theme_ecran_accueil_tags = Theme.current.ecran_accueil_tags(self)
  def theme_error_page(**locals) = Theme.current.error_page(self, locals)
  def theme_glyphe(nom, classe: "glyphe") = Theme.current.glyphe(self, nom, classe: classe)
  def theme_monogramme(classe:) = Theme.current.monogramme(self, classe: classe)

  # Couleur de la barre du navigateur = celle du manifest du thème :
  # une seule source, aucune couleur recopiée dans l'app.
  def theme_color_meta_tag
    tag.meta(name: "theme-color", content: Theme.current.theme_color)
  end
end
