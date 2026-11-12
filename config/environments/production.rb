require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Staging seulement (même RAILS_ENV, reconnu à son APP_HOST parmi
  # STAGING_HOSTS) : un ancien nom resté servi en alias renvoie en 301 vers
  # le nom canonique (GET/HEAD, chemins machine exclus). Sans cela, une
  # connexion OIDC lancée depuis l'ancien nom revient sur le nouveau
  # (redirect_uri dérivé d'APP_HOST) sans le cookie d'état OIDC. En prod,
  # legacy_redirect vaut nil : rien n'est monté.
  if (legacy_redirect = StagingHost.legacy_redirect)
    config.middleware.use LegacyHostRedirect, **legacy_redirect
  end

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  config.action_mailer.raise_delivery_errors = true

  # Asset builds have no deployment environment; runtime must provide APP_HOST.
  mail_host = ENV["SECRET_KEY_BASE_DUMMY"].present? ? ENV["APP_HOST"] : ENV.fetch("APP_HOST")
  config.action_mailer.default_url_options = { host: mail_host, protocol: "https" }

  # Port 465 uses implicit TLS. Missing credentials fail when mail is delivered.
  delivery_method = ENV.fetch("MAIL_DELIVERY_METHOD", "smtp")
  unless %w[smtp test].include?(delivery_method)
    raise ArgumentError, "MAIL_DELIVERY_METHOD must be smtp or test"
  end
  config.action_mailer.delivery_method = delivery_method.to_sym
  config.action_mailer.smtp_settings = {
    address:              ENV["SMTP_ADDRESS"],
    port:                 (ENV["SMTP_PORT"] || "465").to_i,
    user_name:            ENV["SMTP_USERNAME"],
    password:             ENV["SMTP_PASSWORD"],
    authentication:       :plain,
    tls:                  true,
    enable_starttls_auto: false
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Protection contre les attaques par l'en-tête Host (DNS rebinding,
  # réponses mises en cache pour un nom arbitraire) : l'application ne répond
  # qu'à son APP_HOST et, sur une instance de pré-production, aux noms de
  # STAGING_HOSTS (l'ancien nom doit lui parvenir pour que LegacyHostRedirect
  # le redirige). Liste vide pendant la compilation des assets (sans
  # APP_HOST) : aucune requête n'y est servie. Le contrôle de santé /up est
  # exempté : le proxy l'interroge sans le nom public.
  config.hosts = [ ENV["APP_HOST"], *StagingHost.names ].compact_blank.uniq
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
