# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

# Émetteur OIDC des tests (OidcProvider n'a pas de défaut) : les liens
# d'inscription des tests et la directive CSP `form-action` le citent. Posé
# ici, avant les initializers : `bin/rails test` charge l'environnement par
# `test:prepare` avant même test_helper.rb.
ENV["OIDC_ISSUER"] ||= "https://id.example.test"
# Groupe OIDC des animateurs du projet (User#project_host?, aucun défaut) :
# les tests « animateur du projet » transmettent ce groupe.
ENV["LIVE_ANIMATEURS_GROUP"] ||= "live-animateurs"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Jamais de vrai Nextcloud en test, même avec NEXTCLOUD_* exportées : remplace
  # la factory de config/application.rb ; la publication des épisodes n'écrit
  # que dans le faux client que chaque test injecte
  # (test/support/episode_publication_helpers.rb).
  config.x.nextcloud_client_factory = -> { nil }

  # Jamais d'appel au LLM local depuis les tests, même avec
  # QA_LLM_ENABLED exporté : chaque test de la file Q&R injecte son faux client.
  config.x.qa_llm_client_factory = -> { nil }
  config.x.chapter_llm_client_factory = -> { nil }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
