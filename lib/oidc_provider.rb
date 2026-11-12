# Fournisseur OpenID Connect de l'authentification animateur : SOURCE UNIQUE
# de sa configuration. Lu par OmniAuth (config/initializers/omniauth.rb), la
# validation des liens de création de compte (HostInvitation, replays) et la
# directive `form-action` de la CSP (config/initializers/content_security_policy.rb) :
# des lecteurs qui ne peuvent pas diverger. Lu à chaque appel (l'ENV peut
# changer en test).
#
# Aucune valeur par défaut : l'émetteur et le client appartiennent à la
# configuration de l'instance (OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET ;
# docs/quickstart.md), jamais au code distribué.
#
# Chargé au boot, hors autoload (config/application.rb) : les initializers
# l'utilisent avant que l'autoloader soit prêt.
module OidcProvider
  SETTINGS = %w[OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET].freeze

  class IncompleteConfiguration < StandardError; end

  module_function

  def issuer = ENV["OIDC_ISSUER"].presence
  def client_id = ENV["OIDC_CLIENT_ID"].presence
  def client_secret = ENV["OIDC_CLIENT_SECRET"].presence

  def configured?
    missing_settings.empty?
  end

  # Des identifiants de client sans le reste ne doivent pas désactiver la
  # connexion en silence : appelé au boot de production (omniauth.rb), il
  # refuse de démarrer et nomme les variables manquantes. Un émetteur seul
  # ne porte aucun secret : sans client, l'instance n'a pas d'OIDC.
  def assert_complete!
    return if client_id.nil? && client_secret.nil?
    return if configured?

    raise IncompleteConfiguration, "OIDC partially configured, missing: #{missing_settings.join(', ')}"
  end

  def missing_settings
    SETTINGS.select { |name| ENV[name].blank? }
  end

  # Lien vers l'émetteur lui-même (même schéma, hôte et port, sans
  # identifiants) : seule cible admise pour un lien de création de compte.
  # Toujours faux sans émetteur configuré.
  # @param link [String, nil]
  def link?(link)
    return false if issuer.nil?

    uri = URI.parse(link.to_s)
    origin = URI.parse(issuer)
    uri.is_a?(URI::HTTP) && uri.userinfo.nil? && uri.scheme == origin.scheme &&
      uri.host.to_s.casecmp?(origin.host) && uri.port == origin.port
  rescue URI::InvalidURIError
    false
  end
end
