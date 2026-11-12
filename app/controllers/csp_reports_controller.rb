# Réceptacle des rapports de violation de la politique de sécurité du contenu
# (config/initializers/content_security_policy.rb, `report-uri`). Le
# navigateur poste ici, sans cookie ni jeton CSRF, un JSON
# `{ "csp-report": { … } }` en `application/csp-report`.
#
# Anonyme par construction : la route est donc bornée (corps limité, débit
# par réseau) et ne journalise qu'un extrait ASSAINI. Les adresses de page
# portent des jetons en query string (`/mc?t=`, `/rattacher?t=`, `/r/:token`) :
# toute adresse est ramenée à son origine et son chemin, sans query ni
# fragment, et tout segment de chemin porteur de jeton est masqué
# (TokenPathMask, masque partagé avec le journal de requêtes). Le corps
# brut n'est jamais journalisé (`csp-report` est dans `filter_parameters`).
class CspReportsController < ActionController::API
  MAX_BODY_BYTES = 8 * 1024
  MAX_FIELD_LENGTH = 200
  LOGGED_FIELDS = %w[violated-directive effective-directive blocked-uri document-uri source-file line-number disposition].freeze
  URI_FIELDS = %w[blocked-uri document-uri source-file].freeze

  rate_limit to: 60, within: 1.minute, only: :create,
    by: -> { "csp:#{Digest::SHA256.hexdigest(ClientNetwork.key(request.remote_ip))}" },
    store: RegistrationRateLimitStore.new(name: "csp_report_rate_limits"),
    with: -> { head :too_many_requests }

  def create
    return head :content_too_large if request.content_length.to_i > MAX_BODY_BYTES

    report = parse(request.body.read(MAX_BODY_BYTES + 1))
    return head :bad_request unless report

    Rails.logger.warn("[csp-report] #{summary(report)}")
    head :no_content
  end

  private

  def parse(raw)
    return if raw.nil? || raw.bytesize > MAX_BODY_BYTES

    body = JSON.parse(raw)
    report = body["csp-report"] if body.is_a?(Hash)
    report if report.is_a?(Hash)
  rescue JSON::ParserError, EncodingError
    nil
  end

  def summary(report)
    LOGGED_FIELDS.filter_map do |field|
      value = report[field]
      next unless value.is_a?(String) || value.is_a?(Integer)

      # Nettoyer AVANT tout appel de méthode : `blank?`, `gsub` et `first`
      # lèvent ArgumentError sur de l'UTF-8 invalide.
      value = value.scrub("?") if value.is_a?(String)
      next if value.blank?

      value = sanitize_uri(value) if URI_FIELDS.include?(field) && value.is_a?(String)
      "#{field}=#{value.to_s.gsub(/[[:cntrl:]]+/, " ").first(MAX_FIELD_LENGTH)}"
    end.join(" ")
  end

  # Origine + chemin, sans query ni fragment ; un mot-clé CSP (`inline`,
  # `eval`, `data`) reste tel quel.
  def sanitize_uri(value)
    uri = URI.parse(value)
    return value unless uri.scheme && uri.host

    "#{uri.scheme}://#{uri.host}#{TokenPathMask.mask(uri.path)}"
  rescue URI::InvalidURIError
    "[uri illisible]"
  end
end
