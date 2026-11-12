module Internal
  # File des annonces au groupe de messagerie de la communauté de l'opérateur —
  # docs/registrations-api.md §Groupe de la communauté. Le relais (optionnel)
  # vient chercher les inscriptions confirmées, annonce le prénom et les
  # cafés choisis, puis acquitte chacune.
  #
  # Le groupe est ouvert à des membres externes : cette file ne rend QUE le
  # prénom et les cafés — ni email, ni nom complet, ni profil, ni message.
  # Même jeton que la file des co-organisateurs (un seul relais lit les deux).
  class CommunityAnnouncementsController < ActionController::API
    include BearerTokenAuthentication
    authenticate_with_bearer_token "REGISTRATION_RELAY_TOKEN"

    PENDING_LIMIT = 20

    before_action { response.headers["Cache-Control"] = "no-store" }

    # Les plus anciennes confirmations d'abord : l'ordre des inscriptions.
    def pending
      registration_requests = RegistrationRequest.community_announcement_pending.order(:confirmed_at, :id)
                                                 .limit(PENDING_LIMIT)
      render json: { announcements: registration_requests.map { |registration_request| entry(registration_request) } }
    end

    # Idempotent : rejoué, même date. Hors de la file (inconnue, non
    # confirmée, sans café publié, inscription de test) : 404.
    def announced
      registration_request = RegistrationRequest.community_announceable.find_by(id: params[:id])
      return head :not_found unless registration_request

      registration_request.mark_community_announced!
      render json: { id: registration_request.id,
                     community_announced_at: registration_request.community_announced_at.iso8601 }
    end

    private

    def entry(registration_request)
      {
        id: registration_request.id,
        first_name: registration_request.first_name,
        webinars: registration_request.published_registrations.map { |registration| webinar_entry(registration.webinar) },
        confirmed_at: registration_request.confirmed_at.iso8601
      }
    end

    def webinar_entry(webinar)
      { slug: webinar.slug, title: webinar.title, starts_at: webinar.starts_at.iso8601 }
    end
  end
end
