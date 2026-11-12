require "ipaddr"

# Connexion de développement : l'animateur se connecte par sa seule adresse,
# sans fournisseur OpenID Connect, pour essayer l'application en local
# (docs/quickstart.md). Le compte ouvert est administrateur : la voie est
# fermée par trois verrous cumulés.
#
#   1. Environnement : active en développement, ou hors production avec
#      LIVE_DEV_LOGIN=1 ; jamais en production, où ce drapeau empêche même le
#      démarrage (config/initializers/dev_login.rb).
#   2. Origine de la requête : loopback seulement, plus les réseaux privés
#      déclarés dans LIVE_DEV_LOGIN_ALLOWED_NETWORKS (le quickstart y met les
#      plages des réseaux Docker, d'où arrive le navigateur de l'hôte par le
#      port publié sur 127.0.0.1). L'adresse jugée est le pair TCP brut
#      (REMOTE_ADDR), jamais `request.remote_ip` : Rails croit par défaut les
#      en-têtes de transfert venus des plages privées, qu'un poste du réseau
#      local peut donc forger. Une requête qui porte un en-tête de transfert
#      n'est admise que d'un pair loopback (mandataire local), et seulement si
#      chaque adresse transférée est elle-même admise.
#   3. Réseaux déclarés : une plage hors loopback et hors adresses privées
#      empêche le démarrage. La voie ne s'ouvre jamais à Internet, quelle que
#      soit l'interface sur laquelle le serveur écoute.
#
# L'interface d'écoute elle-même n'est pas contrôlée : dans un conteneur, le
# serveur doit écouter sur 0.0.0.0 pour que le port publié l'atteigne, et ce
# qui l'expose vraiment (le port publié) n'est pas visible de l'application.
# Le verrou 2 rend cette écoute sans effet sur la connexion de dev.
#
# Chargé au boot, hors autoload (config/application.rb), comme OidcProvider :
# l'initializer l'appelle avant que l'autoloader soit prêt.
module DevLogin
  FLAG = "LIVE_DEV_LOGIN"
  NETWORKS_VAR = "LIVE_DEV_LOGIN_ALLOWED_NETWORKS"
  # Préfixe des `oidc_sub` créés par cette voie : un sub d'un vrai
  # fournisseur ne le porte jamais (le callback OIDC le refuse), les deux
  # populations restent distinctes.
  SUB_PREFIX = "dev-login|"

  LOOPBACK = %w[127.0.0.0/8 ::1/128].map { |cidr| IPAddr.new(cidr) }.freeze

  FORWARDING_HEADERS = %w[HTTP_X_FORWARDED_FOR HTTP_X_REAL_IP HTTP_CLIENT_IP HTTP_FORWARDED].freeze

  class ForbiddenInProduction < StandardError; end
  class UnsafeNetwork < StandardError; end

  module_function

  def enabled?(env: Rails.env, vars: ENV)
    return false if env.production?

    env.development? || vars[FLAG] == "1"
  end

  # Active ET demandée depuis une origine admise : ce que vérifient la route
  # et l'écran de connexion, sur l'environnement Rack de la requête.
  def available_to?(rack_env, env: Rails.env, vars: ENV)
    enabled?(env: env, vars: vars) && allowed_origin?(rack_env, vars: vars)
  end

  def allowed_origin?(rack_env, vars: ENV)
    peer = rack_env["REMOTE_ADDR"]
    return false unless allowed_address?(peer, vars: vars)

    forwarded = forwarded_addresses(rack_env)
    return true if forwarded.nil?

    loopback?(peer) && forwarded.any? && forwarded.all? { |address| allowed_address?(address, vars: vars) }
  end

  # nil sans en-tête de transfert ; sinon chaque adresse annoncée, telle que
  # lue (une valeur illisible ou obfusquée échoue ensuite à allowed_address?).
  def forwarded_addresses(rack_env)
    present = FORWARDING_HEADERS.select { |header| rack_env[header].present? }
    return nil if present.empty?

    present.flat_map do |header|
      elements = rack_env[header].split(",").map(&:strip)
      header == "HTTP_FORWARDED" ? elements.map { |element| forwarded_for(element) } : elements
    end
  end

  # RFC 7239 : `for=192.0.2.4:5678`, `for="[2001:db8::1]:80"`, `for=unknown`.
  def forwarded_for(element)
    value = element[/for=\s*"?\[?([^\]";\s]+)/i, 1].to_s
    value.count(":") == 1 ? value.split(":").first : value
  end

  def loopback?(address)
    ip = IPAddr.new(address.to_s).native
    LOOPBACK.any? { |network| network.include?(ip) }
  rescue IPAddr::Error
    false
  end

  def allowed_address?(address, vars: ENV)
    address = IPAddr.new(address.to_s).native
    allowed_networks(vars: vars).any? { |network| network.include?(address) }
  rescue IPAddr::Error
    false
  end

  def allowed_networks(vars: ENV)
    LOOPBACK + declared_networks(vars: vars)
  end

  # Toute valeur non vide refuse le démarrage en production, même « 0 » : le
  # drapeau n'a rien à faire dans l'environnement d'une instance publique.
  def assert_not_in_production!(env: Rails.env, vars: ENV)
    return unless env.production? && vars[FLAG].present?

    raise ForbiddenInProduction,
          "#{FLAG} is set in production: the development sign-in must never run on a public instance. Unset it."
  end

  def assert_safe_networks!(vars: ENV)
    unsafe = declared_networks(vars: vars).reject { |network| within_private?(network) }
    return if unsafe.empty?

    raise UnsafeNetwork,
          "#{NETWORKS_VAR} may only list private networks: #{unsafe.map { |n| "#{n}/#{n.prefix}" }.join(', ')}"
  rescue IPAddr::Error => e
    raise UnsafeNetwork, "#{NETWORKS_VAR} is not a comma-separated list of networks: #{e.message}"
  end

  def declared_networks(vars: ENV)
    vars[NETWORKS_VAR].to_s.split(",").map(&:strip).reject(&:empty?).map { |cidr| IPAddr.new(cidr) }
  end

  # Plages privées d'IPAddr#private? (RFC 1918, RFC 4193) ou loopback. Les
  # blocs CIDR étant alignés, deux bornes dans le même ensemble suffisent.
  def within_private?(network)
    range = network.to_range
    [ range.first, range.last ].all? { |bound| bound.private? || bound.loopback? }
  end
end
