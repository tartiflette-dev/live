require "ipaddr"

# Clé de limitation de débit d'un client à partir de son adresse IP.
#
# Une machine IPv6 dispose d'un /64 entier (2^64 adresses) : compter par
# adresse complète laisserait un attaquant contourner n'importe quelle
# limite en changeant d'adresse à chaque requête. L'IPv6 est donc ramenée
# à son préfixe /64 ; l'IPv4 (et l'IPv4 écrite en IPv6, `::ffff:a.b.c.d`)
# reste l'adresse elle-même, donc les clés IPv4 déjà en service ne changent
# pas.
module ClientNetwork
  IPV6_PREFIX_LENGTH = 64

  module_function

  # @param ip [String, nil] `request.remote_ip`
  # @return [String] l'adresse IPv4, le préfixe /64 d'une IPv6, ou l'entrée
  #   telle quelle si elle n'est pas une adresse
  def key(ip)
    address = IPAddr.new(ip.to_s).native
    address.ipv6? ? address.mask(IPV6_PREFIX_LENGTH).to_s : address.to_s
  rescue IPAddr::Error
    ip.to_s
  end
end
