# frozen_string_literal: true

require "rack"

# Redirige (301) un ancien nom d'hôte vers le nom courant, même chemin et même
# query.
#
# Seules les requêtes GET/HEAD sont redirigées : un POST (formulaire, webhook,
# démarrage OIDC) n'est jamais réécrit, même déguisé en GET par
# Rack::MethodOverride (`_method=get`). Les chemins machine (`exclude_prefixes`)
# passent tels quels : leurs clients HTTP (webhooks, sondes, websockets) ne
# suivent pas les redirections et restent configurés sur l'ancien nom.
#
# Générique : la liste des noms vient de la configuration qui le monte
# (cf. StagingHost.legacy_redirect et config/environments/production.rb).
class LegacyHostRedirect
  REDIRECTABLE_METHODS = %w[GET HEAD].freeze
  # Clé posée par Rack::MethodOverride quand il réécrit un POST.
  ORIGINAL_METHOD = "rack.methodoverride.original_method"

  def initialize(app, from:, to:, exclude_prefixes: [])
    @app = app
    @from = Array(from).map(&:downcase).freeze
    @to = to.downcase
    @exclude_prefixes = Array(exclude_prefixes).freeze
    raise ArgumentError, "la cible #{@to} figure parmi les anciens noms (boucle)" if @from.include?(@to)
  end

  def call(env)
    request = Rack::Request.new(env)
    return @app.call(env) unless redirect?(request, env)

    [ 301,
      { "location" => "https://#{@to}#{request.fullpath}",
        "cache-control" => "max-age=3600" },
      [] ]
  end

  private

  def redirect?(request, env)
    @from.include?(request.host.to_s.downcase) &&
      REDIRECTABLE_METHODS.include?(env.fetch(ORIGINAL_METHOD, request.request_method)) &&
      !excluded?(request.path)
  end

  def excluded?(path)
    @exclude_prefixes.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
  end
end
