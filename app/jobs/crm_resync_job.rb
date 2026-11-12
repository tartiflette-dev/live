# frozen_string_literal: true

# Reprise de la synchro CRM (tâche récurrente, config/recurring.yml) : les
# jobs CRM ne sont enqueués qu'une fois, à la confirmation ; un job
# abandonné (CRM indisponible au-delà des retries, endpoint pas encore
# déployé) serait sinon perdu. Ce job ré-enqueue ce qui est DÛ selon
# Crm::Backlog : attente doublée après chaque échec, plafonnée à 24 h — pas
# de gel définitif ; le retrait du consentement a son propre compteur.
#
# Invariants : drapeau maître `CRM_SYNC_ENABLED` ; jobs enqueués idempotents
# et sérialisés par personne ; rien que du déjà éligible (`crm_pending`
# exige l'entrée v1.1 — aucune rétroactivité) ; journal = compteurs seuls.
# État lisible par la supervision : GET /internal/crm_status.
class CrmResyncJob < ApplicationJob
  queue_as :crm

  # `force: true` (bin/rails crm:requeue) : tout ce qui est en attente, sans
  # tenir compte de l'espacement.
  def perform(force: false)
    return unless ENV["CRM_SYNC_ENABLED"] == "1"

    backlog = Crm::Backlog.new
    now = Time.current
    pending = backlog.items
    due = force ? pending : pending.select { |item| item.due?(now) }
    due.each { |item| item.job_class.perform_later(item.id) }
    backlog.mark_attempted(due, now)
    log(pending, due)
  end

  private

  def log(pending, due)
    permanent = pending.count(&:permanent_failure?)
    failing = pending.count(&:error_code)
    line = "pending=#{pending.size} enqueued=#{due.size} failing=#{failing} permanent_failures=#{permanent}"
    Rails.logger.public_send(failing.positive? ? :warn : :info, "[CrmResyncJob] crm_resync #{line}")
  end
end
