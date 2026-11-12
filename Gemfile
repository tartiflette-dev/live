source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3", ">= 8.1.3.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use sqlite3 as the database for Active Record
gem "sqlite3", ">= 2.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Bundle and transpile JavaScript [https://github.com/rails/jsbundling-rails]
gem "jsbundling-rails"

# tailwindcss-rails compile app/assets/tailwind/application.css (feuille du
# thème écrite par theme:sync) ; esbuild garde le bundle LiveKit.
gem "tailwindcss-rails"
# Traductions fr du framework (messages ActiveRecord, dates) : locale par
# défaut fr (config/application.rb).
gem "rails-i18n", "~> 8.0"
# Gems propres à une distribution (thème tiré d'une forge privée…) : pas ici,
# dans un Gemfile.distribution qui évalue celui-ci (config/boot.rb le prend
# d'office quand il existe).

# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

gem "csv"

# Agenda public (/agenda.ics, /w/:slug.ics) — iCalendar RFC 5545 : pliage
# à 75 octets, échappement TEXT, CRLF. Enveloppe unique de la dépendance
# vendeur : aucun `Icalendar::` hors de WebinarCalendar.
gem "icalendar", "~> 2.12"

# LiveKit server SDK — émission des access tokens (JWT HS256) via
# LivekitTokenService. Enveloppe unique de la dépendance
# vendeur : aucun `require "livekit"` hors du service
# et de son initializer.
gem "livekit-server-sdk", "~> 1.0"

# Auth animateur — Pocket ID OIDC. Provider `:pocket_id`
# monté par config/initializers/omniauth.rb ; `omniauth-rails_csrf_protection`
# force le POST sur la request phase (bouton `button_to`).
gem "omniauth", "~> 2.1"
gem "omniauth_openid_connect", "~> 0.8"
gem "omniauth-rails_csrf_protection", "~> 1.0"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end
