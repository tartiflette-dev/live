# frozen_string_literal: true

# Thème de la distribution, choisi par BRAND_THEME et figé au démarrage. Sans
# BRAND_THEME : undust si la gem undust-charte est dans le bundle (Gemfile
# d'une distribution, config/boot.rb), tartiflette sinon. `Theme.current` rend
# l'adaptateur du thème ; Brand, ThemeHelper, ThemesController et la tâche
# theme:sync lui parlent sans savoir lequel c'est.
#
#   - undust      → Theme::UndustCharte, adaptateur de la gem undust-charte
#                   (Gemfile.distribution du fork) ; identité dans
#                   themes/undust/theme.yml. Adaptateur et identité vivent
#                   avec la gem, dans le fork : chargés seulement pour ce thème.
#   - tout autre  → Theme::Pack, dossier themes/<nom>/ (contrat :
#                   docs/theme-pack.md) ; chrome par défaut de l'app.
#
# Deuxième aiguillage, assumé : les quatre partials de dispatch
# app/views/theme/_{anti_fouc,chrome_haut,chrome_bas,theme_toggle} testent
# `Theme.undust?`. Pour theme_toggle, charte-lint (R4) exige le nom du partial
# de la gem écrit en toutes lettres dans une vue atteinte depuis les layouts
# (R4 vise l'interrupteur de thème, pas l'anti-FOUC).
#
# Hors autoload (config/application.rb) : la sélection décide, avant
# Bundler.require, s'il faut charger la gem.
module Theme
  UNDUST = "undust"
  DEFAULT = "tartiflette"
  UNDUST_GEM = "undust-charte"
  NAME = /\A[a-z0-9][a-z0-9_-]*\z/

  class << self
    def selected
      @selected ||= name_from(ENV["BRAND_THEME"])
    end

    # Nom simple, dossier enfant direct de themes/ : refus explicite sinon.
    # `specs` : les gems du bundle (Bundler les a activées dans config/boot.rb).
    def name_from(value, specs = Gem.loaded_specs)
      undust_gem = specs.key?(UNDUST_GEM)
      name = value.to_s.strip.presence || (undust_gem ? UNDUST : DEFAULT)
      unless name.match?(NAME)
        raise ArgumentError, "BRAND_THEME=#{value.inspect} : nom de thème attendu (#{NAME.source}), dossier de themes/."
      end
      if name == UNDUST && !undust_gem
        raise ArgumentError, "BRAND_THEME=undust : la gem #{UNDUST_GEM} n'est pas dans le bundle (Gemfile d'une distribution, BUNDLE_GEMFILE)."
      end

      name
    end

    def undust?
      selected == UNDUST
    end

    def current
      @current ||= undust? ? undust_charte : Pack.new(root.join(selected))
    end

    def root
      Pathname(__dir__).join("..", "themes").expand_path
    end

    private

    def undust_charte
      require_relative "theme/undust_charte"
      UndustCharte.new(root.join(UNDUST))
    end
  end
end

require_relative "theme/pack"
