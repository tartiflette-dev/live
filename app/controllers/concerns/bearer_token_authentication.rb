# Points d'entrée internes (supervision, relais WhatsApp) : fermés par défaut.
# Sans la variable d'environnement du jeton (ou vide), 404 ; avec,
# exactement `Authorization: Bearer <jeton>` (comparaison à temps
# constant), sinon 401 — le jeton nu, sans schéma, est refusé. Une réponse
# refusée n'a pas de corps.
#
#   authenticate_with_bearer_token "CRM_STATUS_TOKEN"
module BearerTokenAuthentication
  extend ActiveSupport::Concern

  class_methods do
    def authenticate_with_bearer_token(env_key)
      before_action { authenticate_bearer_token(ENV[env_key].to_s) }
    end
  end

  private

  def authenticate_bearer_token(expected)
    return head :not_found if expected.empty?

    provided = request.headers["Authorization"].to_s[/\ABearer (\S+)\z/, 1].to_s
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end
end
