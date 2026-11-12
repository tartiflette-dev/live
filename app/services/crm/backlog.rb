# frozen_string_literal: true

module Crm
  # Ce qui reste à pousser vers le CRM, et quand réessayer — lu par la
  # reprise (CrmResyncJob), la sonde (Internal::CrmStatusController) et la
  # remise en file manuelle (`bin/rails crm:requeue`).
  #
  # Trois files, chacune avec son job et ses marqueurs :
  # - inscriptions (participant ou consentement marketing) → CrmSyncJob ;
  # - « préviens-moi » confirmés                            → CrmNotifyNextJob ;
  # - retraits du consentement, sur une fiche connue        → CrmMarketingWithdrawalJob,
  #   avec son PROPRE compteur : une inscription en échec ne bloque jamais
  #   la propagation d'un retrait.
  #
  # Pas de plafond qui gèle : après un échec, l'attente avant nouvel essai
  # double à partir de FIRST_DELAY et plafonne à MAX_DELAY (24 h). Une ligne
  # en échec est donc retentée au moins une fois par jour, sans fin, et la
  # sonde la signale. Aucune donnée personnelle ne sort d'ici : identifiants
  # locaux, dates, compteurs, codes HTTP.
  class Backlog
    # Cadence de CrmResyncJob — doit suivre `config/recurring.yml` (testé).
    RESYNC_PERIOD = 30.minutes
    # Après un enqueue (ou un échec daté), pas de nouvel enqueue avant un
    # tour de reprise complet + marge : le job peut encore être en file ou
    # dans sa chaîne de retry (`retry_on … polynomially_longer, attempts: 5`
    # ≈ 7 min au total). Le tour suivant (30 min) ne le ré-enqueue donc pas ;
    # celui d'après (60 min) seulement s'il n'a toujours pas abouti.
    REQUEUE_HOLD  = RESYNC_PERIOD + 15.minutes
    FIRST_DELAY   = 15.minutes
    MAX_DELAY     = 24.hours
    # Jamais tentée : on laisse au job lancé à la confirmation le temps de
    # passer avant que la reprise n'en enqueue un second.
    GRACE         = 15.minutes

    # Par file : modèle et colonnes de son calendrier (le retrait a les siennes).
    # `log_key` : nom de l'identifiant local dans les journaux (jamais d'email).
    # `gone` : colonne de l'état terminal « fiche hors d'atteinte » de CETTE
    # file ; nil pour le retrait, qui n'en a pas (fiche introuvable = alerte,
    # un humain vérifie dans le CRM).
    Schedule = Data.define(:record, :log_key, :attempts, :last_attempt_at, :next_attempt_at, :error_code, :gone)
    SCHEDULES = {
      registrations: Schedule.new(Registration, "registration_id", :crm_sync_attempts, :crm_last_attempt_at,
                                  :crm_next_attempt_at, :crm_last_error_code, :crm_sync_contact_gone_at),
      notify_next: Schedule.new(RegistrationRequest, "registration_request_id", :crm_sync_attempts,
                                :crm_last_attempt_at, :crm_next_attempt_at, :crm_last_error_code,
                                :crm_contact_gone_at),
      withdrawals: Schedule.new(Registration, "registration_id", :crm_withdrawal_attempts,
                                :crm_withdrawal_last_attempt_at, :crm_withdrawal_next_attempt_at,
                                :crm_withdrawal_last_error_code, nil)
    }.freeze
    QUEUES = SCHEDULES.keys.freeze

    # 429 (Crm::RateLimitedError) : le job s'arrête sans retry immédiat (les
    # retries SolidQueue brûleraient le quota en quelques minutes) et la
    # ligne attend `error.defer_for`, datée, code 429, SANS tentative
    # comptée — le quota n'est pas un échec de la ligne et ne doit pas
    # allonger son espacement.
    def self.defer(queue, id, error, job:, now: Time.current)
      schedule = SCHEDULES.fetch(queue)
      schedule.record.where(id: id).update_all(schedule.last_attempt_at => now,
                                               schedule.next_attempt_at => now + error.defer_for,
                                               schedule.error_code => error.http_status)
      Rails.logger.warn("[#{job.name}] rate_limited #{schedule.log_key}=#{id} http_status=429 " \
                        "retry_in=#{error.defer_for.to_i}")
    end

    # Fiche hors d'atteinte (Crm::ContactGoneError) : état terminal attendu
    # de la file `queue` seulement. La ligne sort de CETTE file sans code
    # d'erreur : ni reprise, ni 503 (la sonde la compte). Journal sans PII.
    def self.close_gone(queue, id, error, job:, now: Time.current)
      schedule = SCHEDULES.fetch(queue)
      raise ArgumentError, "la file #{queue} n'a pas d'état terminal" unless schedule.gone

      schedule.record.where(id: id).update_all(schedule.gone => now, schedule.error_code => nil)
      Rails.logger.info("[#{job.name}] contact_gone reason=#{error.reason} #{schedule.log_key}=#{id}")
    end

    Item = Data.define(:queue, :job_class, :id, :pending_since, :attempts, :last_attempt_at,
                       :next_attempt_at, :error_code) do
      def due?(now)
        return false if next_attempt_at && next_attempt_at > now

        reference = last_attempt_at || pending_since
        reference.nil? || reference <= now - wait
      end

      def wait
        return GRACE if last_attempt_at.nil?

        backoff = attempts.zero? ? 0 : FIRST_DELAY * (2**(attempts - 1))
        backoff.clamp(REQUEUE_HOLD, MAX_DELAY)
      end

      # Erreur que le CRM ne corrigera pas seul (contrat, fiche) : 4xx hors 429.
      def permanent_failure?
        error_code.to_i.between?(400, 499) && error_code.to_i != 429
      end
    end

    def items
      registration_items + notify_next_items + withdrawal_items
    end

    # Date l'enqueue par la reprise : la ligne attend alors au moins
    # REQUEUE_HOLD avant d'être ré-enqueuée (cf. ci-dessus).
    def mark_attempted(items, now = Time.current)
      items.group_by(&:queue).each do |queue, group|
        schedule = SCHEDULES.fetch(queue)
        schedule.record.where(id: group.map(&:id)).update_all(schedule.last_attempt_at => now)
      end
    end

    # Remise à zéro de l'attente : tout ce qui reste à pousser redevient dû.
    def reset_schedule
      pending_scopes.each do |queue, scope|
        schedule = SCHEDULES.fetch(queue)
        scope.update_all(schedule.attempts => 0, schedule.last_attempt_at => nil, schedule.next_attempt_at => nil)
      end
    end

    private

    def pending_scopes
      { registrations: Registration.crm_pending, notify_next: RegistrationRequest.crm_pending,
        withdrawals: Registration.crm_withdrawal_pending }
    end

    def registration_items
      Registration.crm_pending.map do |registration|
        since = registration.crm_pushed? ? registration.marketing_consent_at : registration.crm_enrolled_at
        item(:registrations, CrmSyncJob, registration, since)
      end
    end

    # Datée par l'étape encore due : participant (confirmation), consentement
    # porté par la demande (accord), puis retrait — un retrait récent d'une
    # demande confirmée il y a longtemps n'est pas « en attente depuis des jours ».
    def notify_next_items
      RegistrationRequest.crm_pending.map do |request|
        since = if !request.crm_pushed? then request.confirmed_at
        elsif request.crm_marketing_consent_pending? then request.marketing_consent_at
        else request.marketing_consent_withdrawn_at
        end
        item(:notify_next, CrmNotifyNextJob, request, since)
      end
    end

    def withdrawal_items
      Registration.crm_withdrawal_pending.map do |registration|
        item(:withdrawals, CrmMarketingWithdrawalJob, registration, registration.marketing_consent_withdrawn_at)
      end
    end

    def item(queue, job_class, row, pending_since)
      schedule = SCHEDULES.fetch(queue)
      Item.new(queue: queue, job_class: job_class, id: row.id, pending_since: pending_since,
               attempts: row[schedule.attempts], last_attempt_at: row[schedule.last_attempt_at],
               next_attempt_at: row[schedule.next_attempt_at], error_code: row[schedule.error_code])
    end
  end
end
