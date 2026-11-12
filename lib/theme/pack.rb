# frozen_string_literal: true

require "yaml"

module Theme
  # Pack de thème local, dossier themes/<nom>/ : identité (theme.yml), jetons
  # (tokens.css), retouches facultatives (chrome.css) et fichiers servis
  # (assets/). Le chrome est celui de l'app (app/views/theme/default/, feuille
  # app/assets/tailwind/theme_default.css). Contrat : docs/theme-pack.md.
  #
  # Seul `assets/` est servi (chemin d'assets Propshaft) : logo, favicon,
  # polices. tokens.css et chrome.css ne sont pas servis tels quels, `theme:sync`
  # les fait inliner par Tailwind dans tailwind.css ; leurs url() s'écrivent
  # donc comme vues depuis `assets/` (`url("fonts/…")`). README, theme.yml,
  # preview/ restent dans le dépôt, hors du site.
  #
  # Un pack est du code de confiance : son logo.svg est
  # injecté tel quel dans les pages, son CSS s'applique partout.
  #
  # Seuls theme.yml et ses clés obligatoires sont exigés : sans tokens.css,
  # assets/logo.svg ou assets/favicon.svg, le pack reçoit les substituts neutres
  # de l'app (contrat complet : docs/theme-pack.md).
  class Pack
    MODES = %w[light dark].freeze
    NEUTRAL_TOKENS = "../../../themes/neutre_tokens.css"
    NEUTRAL_FAVICON = "live-neutre-favicon.svg"
    NEUTRAL_LOGO = Pathname(__dir__).join("../../app/assets/images/live-neutre-logo.svg").expand_path

    attr_reader :root

    def initialize(root)
      @root = Pathname(root)
      return if @root.join("theme.yml").file?

      raise ArgumentError, "BRAND_THEME=#{slug} : thème introuvable, #{@root.join("theme.yml")} manque."
    end

    def slug
      root.basename.to_s
    end

    def identity
      @identity ||= YAML.safe_load_file(root.join("theme.yml"), symbolize_names: true)
    end

    # Valeurs de marque par défaut ; config/brand.yml puis BRAND_* priment.
    def brand
      values = { favicon: default_favicon }.merge(identity.slice(:product_name, :credit, :links, :favicon))
      check_urls!(values)
      values
    end

    def theme_color
      identity.fetch(:theme_color)
    end

    # Mode sans cookie : `default_mode` du theme.yml (light par défaut).
    def default_mode
      identity.fetch(:default_mode, MODES.first)
    end

    # Contenu d'app/assets/tailwind/theme.css, écrit par `theme:sync` et
    # importé par application.css.
    def stylesheet
      tokens = root.join("tokens.css").file? ? "../../../themes/#{slug}/tokens.css" : NEUTRAL_TOKENS
      imports = [ tokens, "./theme_default.css" ]
      imports << "../../../themes/#{slug}/chrome.css" if root.join("chrome.css").file?
      imports.map { |path| %(@import "#{path}";\n) }.join
    end

    def sync_assets!; end

    def asset_paths = [ root.join("assets") ]

    def view_helper = ModeHelper
    def mode_switch = ModeSwitch

    def fonts_tag(_view) = nil
    def ecran_accueil_tags(_view) = nil
    def error_page(view, locals) = view.render("theme/default/error_page", locals)
    def glyphe(view, nom, classe:) = view.render("theme/default/glyphe", nom: nom.to_s, classe: classe)

    # Logo du pack en ligne (currentColor possible), fichier du dépôt. Il
    # double le nom du produit écrit à côté : décoratif, ses attributs
    # d'accessibilité (role, aria-label, title) sont remplacés par aria-hidden.
    def monogramme(_view, classe:)
      @logo ||= logo_source.read
                    .sub(/<svg\b[^>]*>/) { |open| open.gsub(/\s(?:class|role|aria-[\w-]+|focusable)="[^"]*"/, "") }
                    .gsub(%r{<title>.*?</title>}m, "")
      attrs = %(class="#{ERB::Util.html_escape(classe)}" aria-hidden="true" focusable="false")
      @logo.sub(/<svg\b/) { "<svg #{attrs}" }.html_safe
    end

    def default_favicon
      root.join("assets/favicon.svg").file? ? "favicon.svg" : NEUTRAL_FAVICON
    end
    private :default_favicon

    def logo_source
      logo = root.join("assets/logo.svg")
      logo.file? ? logo : NEUTRAL_LOGO
    end
    private :logo_source

    # Crédit et liens du theme.yml : http(s) seulement, refus au démarrage.
    def check_urls!(values)
      urls = [ values.dig(:credit, :url), *values.fetch(:links, {}).values ].compact
      bad = urls.reject { |url| url.to_s.match?(%r{\Ahttps?://}i) }
      return if bad.empty?

      raise ArgumentError, "BRAND_THEME=#{slug} : URL refusée dans theme.yml (http(s) seulement) : #{bad.join(", ")}"
    end
    private :check_urls!

    # Mode clair/sombre lu dans le cookie `theme` (seul store).
    module ModeHelper
      def current_theme
        MODES.include?(cookies[:theme]) ? cookies[:theme] : Theme.current.default_mode
      end
    end

    # POST /theme : cookie permanent, 204 pour un fetch, retour à la page sinon.
    module ModeSwitch
      def update
        mode = MODES.include?(params[:theme]) ? params[:theme] : Theme.current.default_mode
        cookies.permanent[:theme] = { value: mode, same_site: :lax, secure: request.ssl? }
        return head(:no_content) if request.xhr? || request.format.json?

        redirect_back fallback_location: root_path
      end
    end
  end
end
