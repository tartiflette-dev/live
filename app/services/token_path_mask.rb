# Masque les jetons porteurs d'accès qui voyagent dans un SEGMENT DE CHEMIN :
# `filter_parameters` ne couvre que la query et le corps, jamais le chemin.
# Source unique, partagée par le journal de requêtes
# (config/initializers/registration_token_logging.rb) et le journal des
# rapports CSP (CspReportsController).
#
# Inventaire (config/routes.rb) : `/r/:token` et le flux d'agenda personnel
# `/agenda/:token.ics` sont les SEULES routes dont le jeton est dans le
# chemin (`/agenda/next.json`, public, reste lisible) ; les autres liens
# porteurs de jeton (/i, /a, /mc,
# /mc/withdraw, /rattacher, /confirmer, /w/:slug/join) le passent en query
# `t=`, que les logs et `CspReportsController` retirent. Le test
# `TokenPathMaskTest` échoue si une route à segment `:token` apparaît sans
# préfixe ici.
#
# Le routeur normalise le chemin avant de router (slashs répétés ou final :
# `//r/<jeton>`, `/r//<jeton>` atteignent `/r/:token`) : le masque s'applique
# donc à la forme NORMALISÉE, par le même `Journey::Router::Utils` que lui. Il
# est insensible à la casse par prudence (le routeur y est sensible : `/R/…`
# ne route pas, mais ne doit pas pouvoir porter un jeton dans un journal). Un
# chemin sans jeton est rendu tel quel, non normalisé.
module TokenPathMask
  PLACEHOLDER = "[FILTERED]".freeze
  # Préfixes de chemin dont le segment suivant est un jeton.
  PREFIXES = %w[/r /agenda].freeze
  # Segments publics sous ces préfixes : jamais un jeton (aucun `.` dans un
  # jeton urlsafe base64), gardés lisibles dans les journaux.
  PUBLIC_SEGMENTS = %w[next.json].freeze

  PATTERN = %r{\A(#{PREFIXES.map { |prefix| Regexp.escape(prefix) }.join("|")})
               /(?!(?:#{PUBLIC_SEGMENTS.map { |segment| Regexp.escape(segment) }.join("|")})(?:/|\z))[^/]+}ix

  module_function

  # Remplace le segment qui suit un préfixe porteur de jeton ; le reste du
  # chemin (`/autre`) et la query ou le fragment sont conservés tels quels.
  # @param path [String]
  # @return [String]
  def mask(path)
    path = path.to_s
    location, separator, rest = path.partition(/[?#]/)
    normalized = ActionDispatch::Journey::Router::Utils.normalize_path(location)
    return path unless normalized.match?(PATTERN)

    masked = normalized.sub(PATTERN) { "#{Regexp.last_match(1)}/#{PLACEHOLDER}" }
    "#{masked}#{separator}#{rest}"
  end
end
