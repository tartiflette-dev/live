# Origines réseau de la directive `connect-src`
# (config/initializers/content_security_policy.rb) : un hôte réseau donne
# ses deux schémas — le signal LiveKit (/rtc) et son repli HTTP
# (/rtc/validate).
#
# Le schéma suit le niveau de transport de la valeur d'origine : une valeur
# en clair (`ws://`, quickstart local) reste `ws:`/`http:` — la réécrire en
# `wss:`/`https:` laisserait le signal hors connect-src en CSP bloquante.
#
# Chargé au boot, hors autoload (config/application.rb) : l'initializer qui
# l'utilise tourne avant que l'autoloader soit prêt.
module CspNetworkOrigins
  module_function

  # @param values [Array<String, nil>] URL d'hôtes réseau (LIVEKIT_URL, APP_HOST)
  # @return [Array<String>] origines schéma-hôte, dédupliquées
  def for(*values)
    values.compact.flat_map { |value| pair_for(value.to_s) }.uniq
  end

  def pair_for(value)
    host = value.sub(%r{\A[a-z]+://}, "").split("/").first
    return [] if host.blank?

    schemes = value.start_with?("ws://", "http://") ? %w[ws http] : %w[wss https]
    schemes.map { |scheme| "#{scheme}://#{host}" }
  end
end
