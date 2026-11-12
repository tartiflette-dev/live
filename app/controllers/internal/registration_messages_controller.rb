module Internal
  # File du relais WhatsApp des inscriptions Café IA confirmées, avec ou sans
  # message — docs/registrations-api.md §Relais WhatsApp. L'app ne joint
  # aucune API WhatsApp : le relais WhatsApp vient chercher les inscriptions,
  # les poste au groupe des co-organisateurs, puis acquitte chacune. Chemins
  # historiques (`registration_messages`) gardés : le relais les appelle.
  #
  # Bearer `REGISTRATION_RELAY_TOKEN` (BearerTokenAuthentication), distinct
  # du jeton de supervision : ce jeton-ci voit des identités et écrit.
  class RegistrationMessagesController < ActionController::API
    include BearerTokenAuthentication
    authenticate_with_bearer_token "REGISTRATION_RELAY_TOKEN"

    PENDING_LIMIT = 20

    before_action { response.headers["Cache-Control"] = "no-store" }

    # Les plus anciens d'abord : le relais poste dans l'ordre d'arrivée.
    def pending
      registration_requests = RegistrationRequest.whatsapp_relay_pending.order(:created_at, :id).limit(PENDING_LIMIT)
      render json: { registration_messages: registration_requests.map { |registration_request| entry(registration_request) } }
    end

    # Idempotent : un acquittement rejoué rend la date du premier. Une demande
    # hors de la file (inconnue, non confirmée, autre source) : 404.
    def relayed
      registration_request = RegistrationRequest.team_signups.find_by(id: params[:id])
      return head :not_found unless registration_request

      registration_request.mark_whatsapp_relayed!
      render json: { id: registration_request.id, whatsapp_relayed_at: registration_request.whatsapp_relayed_at.iso8601 }
    end

    private

    def entry(registration_request)
      {
        id: registration_request.id,
        name: registration_request.name,
        email: registration_request.email,
        profile: registration_request.profile,
        webinars: registration_request.published_registrations.map { |registration| webinar_entry(registration.webinar) },
        notify_next: registration_request.notify_next,
        message: registration_request.message,
        created_at: registration_request.created_at.iso8601,
        confirmed_at: registration_request.confirmed_at.iso8601
      }
    end

    def webinar_entry(webinar)
      { slug: webinar.slug, title: webinar.title, starts_at: webinar.starts_at.iso8601 }
    end
  end
end
