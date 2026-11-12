# Réglages propres à chaque instance, que le code distribué ne porte jamais
# en défaut : le nom public de l'instance (APP_HOST : vide, la liste
# config.hosts le serait aussi et Rails désactiverait en silence la
# protection contre les en-têtes Host étrangers, config/environments/
# production.rb), l'URL du signal LiveKit (LIVEKIT_URL), l'adresse de contact
# de la marque (Brand.support_email, BRAND_SUPPORT_EMAIL) et l'organisation
# qui opère l'instance (Brand.organization, BRAND_ORGANIZATION). Sans eux, une
# instance de production enverrait ses spectateurs vers un LiveKit qui n'est
# pas le sien, afficherait un contact qui ne répond pas ou ferait consentir
# envers une organisation sans nom : elle refuse de démarrer et nomme ce qui
# manque (config/initializers/instance_settings.rb).
module InstanceSettings
  class Missing < StandardError; end

  module_function

  # @return [Array<String>] noms des réglages absents
  def missing(vars: ENV, brand: Brand)
    names = []
    names << "APP_HOST" if vars["APP_HOST"].blank?
    names << "LIVEKIT_URL" if vars["LIVEKIT_URL"].blank?
    names << "BRAND_SUPPORT_EMAIL" if brand.support_email.blank?
    names << "BRAND_ORGANIZATION" if brand.organization.blank?
    names
  end

  def assert_complete!(vars: ENV, brand: Brand)
    absent = missing(vars: vars, brand: brand)
    return if absent.empty?

    raise Missing, "Instance settings missing in production: #{absent.join(', ')} (docs/quickstart.md, Production settings)"
  end
end
