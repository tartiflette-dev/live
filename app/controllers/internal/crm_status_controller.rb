module Internal
  # Sonde de la synchro CRM pour la supervision —
  # GET /internal/crm_status, docs/registrations-api.md §Sonde.
  #
  # Fermée par défaut, Bearer `CRM_STATUS_TOKEN` (BearerTokenAuthentication).
  # Réponse : compteurs et dates seulement, jamais d'identité. Porte aussi, à
  # titre informatif, l'état du rappel de la veille (bloc `reminders`, hors
  # `alert`). HTTP 503 quand `alert` est vrai, pour qu'un simple contrôle
  # HTTP (code attendu 200) suffise à alerter.
  class CrmStatusController < ActionController::API
    # Une inscription en attente plus vieille que ça = panne qui dure.
    MAX_PENDING_AGE = 24.hours

    include BearerTokenAuthentication
    authenticate_with_bearer_token "CRM_STATUS_TOKEN"

    def show
      response.headers["Cache-Control"] = "no-store"
      status = crm_status
      render json: status, status: status[:alert] ? :service_unavailable : :ok
    end

    private

    def crm_status
      enabled = ENV["CRM_SYNC_ENABLED"] == "1"
      items = Crm::Backlog.new.items
      now = Time.current
      oldest = items.filter_map(&:pending_since).min
      age = oldest && (now - oldest).to_i
      permanent = items.count(&:permanent_failure?)
      {
        crm_sync_enabled: enabled,
        pending: Crm::Backlog::QUEUES.index_with { |queue| items.count { |item| item.queue == queue } }
                                     .merge(total: items.size),
        oldest_pending_at: oldest&.iso8601,
        oldest_pending_age_seconds: age,
        failing: items.count(&:error_code),
        permanent_failures: permanent,
        # Retraits sur fiche introuvable : un humain vérifie dans le CRM.
        withdrawal_contact_not_found: items.count { |item| item.queue == :withdrawals && item.error_code == 404 },
        # États terminaux attendus (fiche hors d'atteinte) : comptés, sans alerte.
        contact_gone: { registrations: Registration.where.not(crm_sync_contact_gone_at: nil).count,
                        notify_next: RegistrationRequest.where.not(crm_contact_gone_at: nil).count },
        disappeared_contacts: CrmDisappearance.count,
        alert: enabled && (permanent.positive? || age.to_i > MAX_PENDING_AGE),
        # Rappel de la veille (docs/registration-reminders.md §Supervision) :
        # informatif, n'entre PAS dans `alert` (règle CRM inchangée).
        reminders: { enabled: RegistrationReminder.enabled? }.merge(RegistrationReminderRun.status(now)),
        generated_at: now.iso8601
      }
    end
  end
end
