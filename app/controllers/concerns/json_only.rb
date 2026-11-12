# Endpoints JSON de la salle (/api/*) : toute requête non JSON est refusée
# (415). Empêche un submit HTML détourné de contourner l'inspection du
# header X-CSRF-Token.
module JsonOnly
  extend ActiveSupport::Concern

  included do
    before_action :require_json!
  end

  private

  def require_json!
    return if request.format.json? || request.content_type.to_s.include?("application/json")

    head :unsupported_media_type
  end
end
