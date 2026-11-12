require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Thème choisi par BRAND_THEME (lib/theme.rb) : la gem undust-charte n'est
# chargée que pour le thème undust, l'app tourne sans elle pour les autres.
require_relative "../lib/theme"
require "undust/charte" if Theme.undust?

# Chargés au boot, hors autoload : config/environments/production.rb monte la
# redirection des anciens noms du staging avant que l'autoloader soit prêt.
require_relative "../lib/middleware/legacy_host_redirect"
require_relative "../lib/staging_host"
require_relative "../lib/oidc_provider"
require_relative "../lib/csp_network_origins"
require_relative "../lib/dev_login"

module FeatRailsBootstrap
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks middleware staging_host.rb theme.rb theme oidc_provider.rb csp_network_origins.rb dev_login.rb])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # Heure affichée = Paris (webinaires annoncés en heure locale ; la DB
    # reste en UTC). Sans ce réglage, « 9h » s'affiche « 07:00 ».
    config.time_zone = "Europe/Paris"
    # config.eager_load_paths << Rails.root.join("extras")

    # Deux langues en rotation (bouton de la bande basse), défaut fr.
    config.i18n.available_locales = [ :fr, :en ]
    config.i18n.default_locale = :fr

    # Pages d'erreur hors-session rendues par ErrorsController (registre Force).
    config.exceptions_app = ->(env) { ErrorsController.action(:show).call(env) }

    # Au niveau debug, ActionMailer journalise chaque mail en entier (destinataire, nom,
    # liens à jeton) : muet à tout niveau. Les arguments d'un job de mail peuvent porter
    # un destinataire. Le niveau debug reste à proscrire en production : le SQL y porte
    # ses valeurs.
    config.action_mailer.logger = nil
    config.active_job.log_arguments = false

    # Client Nextcloud de la publication des épisodes.
    # `nil` quand NEXTCLOUD_URL, NEXTCLOUD_USERNAME ou
    # NEXTCLOUD_APP_PASSWORD manque : la publication est désactivée, rien
    # d'autre ne change. Posé ici, avant les fichiers d'environnement :
    # config/environments/test.rb le remplace par une factory sans client.
    config.x.nextcloud_client_factory = -> { NextcloudClient.from_env }

    # Client du LLM local de la file Q&R (LocalLlmClient).
    # `nil` tant que QA_LLM_ENABLED n'est pas "true" : QaExtractionJob passe
    # en repli (mentions @animateur brutes). Remplacé en test, comme Nextcloud.
    config.x.qa_llm_client_factory = -> { LocalLlmClient.from_env }
    # Même LLM pour proposer les chapitres d'un replay (ChapterProposalJob),
    # avec un délai à la mesure d'un passage de transcription.
    config.x.chapter_llm_client_factory = -> { LocalLlmClient.from_env(ENV, ChapterProposal::LLM_TIMEOUT_SECONDS) }
  end
end
