# Points d'entrée JSON de la salle : un POST sans jeton CSRF valide est
# refusé en JSON 422. Sans ce rescue, l'exception rejoint la page d'erreur
# (ErrorsController), qui ne connaît pas 422 et répond 500.
module JsonCsrfRefusal
  extend ActiveSupport::Concern

  included do
    rescue_from ActionController::InvalidAuthenticityToken do
      render json: { error: "invalid_authenticity_token" }, status: :unprocessable_entity
    end
  end
end
