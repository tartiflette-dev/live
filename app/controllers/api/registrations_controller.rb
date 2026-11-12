module Api
  # API d'inscription cross-origin (docs/registrations-api.md), pour un
  # site partenaire statique : `POST /api/registrations` (JSON), préflight
  # OPTIONS.
  #
  # ActionController::API : ni session, ni cookie, ni CSRF par cookie —
  # il n'y a aucune session à protéger. La protection tient en :
  # liste blanche d'origine (`REGISTRATION_API_ORIGINS`, vide par défaut :
  # API fermée sans configuration ; refus 403 côté
  # serveur, pas seulement côté navigateur), rate limit au compteur commun
  # avec le formulaire HTML (`scope: :registrations`), validation stricte (RegistrationSubmission), champ
  # piège, et double opt-in : rien n'est confirmé ni poussé au CRM sans
  # le clic de la personne sur le lien reçu par mail.
  class RegistrationsController < ActionController::API
    include RegistrationsHelper

    # `consent` (ancienne case obligatoire, retirée par la politique v1.6)
    # n'est plus permis : envoyé par une version antérieure du site, il est
    # ignoré sans erreur.
    PERMITTED = [ :name, :email, :notify_next, :profile, :message, :marketing_consent, :participation, :source, :website ].freeze

    before_action :refuse_unlisted_origin
    # Même compteur que le formulaire HTML (`scope: :registrations`).
    rate_limit to: 10, within: 1.minute, only: :create, scope: :registrations,
      by: -> { Digest::SHA256.hexdigest(ClientNetwork.key(request.remote_ip)) },
      store: RegistrationRateLimitStore.new,
      with: -> { render json: { status: "rate_limited" }, status: :too_many_requests }
    before_action :require_json, only: :create

    # Corps JSON illisible : réponse du contrat (et CORS déjà posé par
    # `refuse_unlisted_origin`), pas la page 400 de Rails.
    rescue_from ActionDispatch::Http::Parameters::ParseError do
      render json: { status: "invalid", errors: { body: [ "malformed_json" ] } }, status: :bad_request
    end

    def preflight
      response.headers["Access-Control-Allow-Methods"] = "POST"
      response.headers["Access-Control-Allow-Headers"] = "Content-Type"
      response.headers["Access-Control-Max-Age"] = "600"
      head :no_content
    end

    def create
      return render json: { status: "unavailable" }, status: :service_unavailable unless registration_privacy_url

      submission = RegistrationSubmission.new(**submission_params)
      if submission.save
        render json: { status: "pending_confirmation", webinars: submission.webinars.map(&:slug) }, status: :accepted
      else
        render json: { status: "invalid", errors: error_codes(submission) }, status: :unprocessable_entity
      end
    end

    private

    # Origine absente ou hors liste = 403 sans en-tête CORS. Les
    # navigateurs envoient toujours `Origin` sur un POST cross-origin ;
    # un formulaire « simple » posté depuis un autre site est ainsi
    # refusé AVANT tout effet, pas seulement rendu illisible.
    def refuse_unlisted_origin
      origin = request.headers["Origin"].to_s
      return head :forbidden unless allowed_origins.include?(origin)

      response.headers["Access-Control-Allow-Origin"] = origin
      response.headers["Vary"] = "Origin"
    end

    def allowed_origins
      ENV.fetch("REGISTRATION_API_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
    end

    def require_json
      head :unsupported_media_type unless request.media_type == "application/json"
    end

    def submission_params
      permitted = params.permit(*PERMITTED).to_h.symbolize_keys
      permitted[:slugs] = params[:slugs] if params.key?(:slugs)
      permitted
    end

    def error_codes(submission)
      submission.errors.details.transform_values { |details| details.map { |detail| detail[:error].to_s } }
    end
  end
end
