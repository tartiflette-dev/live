# frozen_string_literal: true

# Noms du front de pré-production, lus dans STAGING_HOSTS (posée par le
# déploiement de cette instance seulement, liste séparée par des virgules) :
# le nom canonique en tête, puis les anciens noms restés servis en alias par
# le proxy. Sans STAGING_HOSTS, aucune instance n'est le staging. L'instance
# staging se reconnaît à son APP_HOST, jamais à Rails.env (le staging tourne
# en RAILS_ENV=production).
#
# Hors autoload (config/application.rb) : config/environments/production.rb
# s'en sert pour monter LegacyHostRedirect, avant que l'autoloader soit prêt.
module StagingHost
  # Chemins machine jamais redirigés depuis un ancien nom : santé (/up, sonde
  # de supervision), jeton LiveKit (/api), webhooks LiveKit et transcripteur
  # (/webhooks : le LiveKit et le transcripteur de staging peuvent viser
  # encore un ancien nom, et le GET /webhooks/transcripts/enabled ne suit pas
  # de 301), websocket (/cable). /rtc et /agent sont routés par le proxy vers
  # le LiveKit de staging avant Rails ; listés quand même pour qu'une route
  # proxy manquante ne devienne pas une redirection : la sonde des routes proxy
  # détecte ce cas à la page HTML que Rails renvoie, un 301 le masquerait.
  MACHINE_PATHS = %w[/up /api /webhooks /cable /rtc /agent].freeze

  def self.names
    ENV["STAGING_HOSTS"].to_s.split(",").map(&:strip).reject(&:empty?)
  end

  def self.current?(app_host = ENV["APP_HOST"])
    names.include?(app_host.to_s)
  end

  # Options de LegacyHostRedirect pour l'instance staging : toute requête
  # GET/HEAD humaine reçue sur un ancien nom repart en 301 vers le nom
  # canonique (même chemin, même query), pour que la connexion OIDC démarre
  # et revienne sur le même nom (cookie d'état OIDC). nil hors staging, ou
  # sans ancien nom : la prod ne monte pas le middleware.
  def self.legacy_redirect(app_host = ENV["APP_HOST"])
    return unless current?(app_host)

    canonical, *legacy = names
    return if legacy.empty?

    { from: legacy, to: canonical, exclude_prefixes: MACHINE_PATHS }
  end
end
