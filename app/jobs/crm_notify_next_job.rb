# frozen_string_literal: true

# « Pas dispo, préviens-moi du suivant » (API d'inscription,
# docs/registrations-api.md) : une demande confirmée qui porte
# `notify_next` fait entrer la personne au CRM comme participant, avec
# une interaction « Veut être prévenu·e du prochain Café IA ». Pas de
# webinaire, donc pas de `Registration` : la demande porte ses propres
# marqueurs de synchro. `source_path` = `/confirmer`, la page où la
# demande a été confirmée (aucun café visé).
#
# Case de recontact : sans café, le
# consentement est porté par la demande ; ce job pousse aussi
# l'interaction « Consentement marketing » (preuve figée, marqueur
# `crm_marketing_consent_pushed_at`) puis, s'il est retiré, son retrait
# (`crm_withdrawal_pushed_at`). Chaque étape relit l'état sous verrou :
# le retrait gagne toujours.
#
# Mêmes invariants que CrmSyncJob : drapeau maître `CRM_SYNC_ENABLED`,
# double opt-in, idempotence (`pushed_to_crm_at`), zéro PII dans les
# logs, retry borné, un job CRM à la fois par personne.
class CrmNotifyNextJob < ApplicationJob
  queue_as :crm

  limits_concurrency to: 1, group: Crm::CONTACT_CONCURRENCY_GROUP, duration: 15.minutes,
    key: ->(request_id) { Crm.contact_concurrency_key(RegistrationRequest.find_by(id: request_id)&.email) }

  retry_on Crm::TransientError, wait: :polynomially_longer, attempts: 5

  discard_on Crm::PermanentError do |job, error|
    Rails.logger.warn(
      "[CrmNotifyNextJob] permanent_discard registration_request_id=#{job.arguments.first} " \
        "http_status=#{error.http_status.to_i}"
    )
    RegistrationRequest.where(id: job.arguments.first)
                       .update_all([ "crm_sync_attempts = crm_sync_attempts + 1, crm_last_error_code = ?, " \
                                     "crm_last_attempt_at = ?", error.http_status.to_i, Time.current ])
  end

  discard_on ActiveRecord::RecordNotFound

  # Client non configuré ou autre ArgumentError : même traitement que
  # CrmSyncJob (variable à poser journalisée, jamais de PII).
  discard_on ArgumentError do |job, error|
    Rails.logger.warn(
      "[CrmNotifyNextJob] discarded registration_request_id=#{job.arguments.first} " \
        "reason=#{Crm.discard_reason(error)}"
    )
  end

  def perform(request_id)
    return unless ENV["CRM_SYNC_ENABLED"] == "1"

    request = RegistrationRequest.find(request_id)
    return unless request.confirmed? && request.notify_next?
    return if request.crm_contact_gone_at || !request.crm_work_pending?

    client = build_client
    participants = Crm::ParticipantSync.new(client)
    push_participant(participants, client, request) unless request.crm_pushed?
    push_marketing_consent(participants, client, request)
    push_withdrawal(participants, client, request)
  rescue Crm::ContactGoneError => error
    Crm::Backlog.close_gone(:notify_next, request_id, error, job: self.class)
  rescue Crm::RateLimitedError => error
    Crm::Backlog.defer(:notify_next, request_id, error, job: self.class)
  rescue Crm::TransientError => error
    Rails.logger.warn(
      "[CrmNotifyNextJob] transient_retry registration_request_id=#{request_id} " \
        "http_status=#{error.http_status.to_i}"
    )
    RegistrationRequest.where(id: request_id).update_all(
      crm_sync_attempts: request&.crm_sync_attempts.to_i + 1,
      crm_last_error_code: error.http_status.to_i,
      crm_last_attempt_at: Time.current
    )
    raise
  end

  private

  def push_participant(participants, client, request)
    target = participants.find_or_create_contact(email: request.email, name: request.name,
                                                 own_id: request.crm_contact_id, consented_at: request.confirmed_at)
    # Id emprunté : persisté une fois l'écriture passée (cf. CrmSyncJob).
    track_contact_id(request, target.id) unless target.borrowed

    pushed_id = nil
    participants.on_contact(target.id, email: request.email,
                                       relocated: ->(id) { track_contact_id(request, id) },
                                       consented_at: request.confirmed_at) do |contact_id|
      pushed_id = contact_id
      participants.tag_participant(contact_id, email: request.email)
      client.create_interaction(
        contact_id:   contact_id,
        email:        request.email,
        kind:         "form",
        occurred_at:  request.confirmed_at.iso8601,
        title:        "Veut être prévenu·e du prochain Café IA",
        source:       "#{Brand.host}:notify_next",
        source_path:  "/confirmer",
        notes:        interaction_note(request)
      )
    end
    track_contact_id(request, pushed_id) if target.borrowed

    request.with_lock do
      request.update!(pushed_to_crm_at: Time.current, crm_sync_attempts: request.crm_sync_attempts + 1,
                      crm_last_error_code: nil)
    end
  end

  def push_marketing_consent(participants, client, request)
    return unless request.with_lock { request.crm_marketing_consent_pending? }

    on_known_contact(participants, request) do |contact_id|
      client.create_interaction(
        contact_id:   contact_id,
        email:        request.email,
        kind:         "form",
        occurred_at:  request.marketing_consent_at.iso8601,
        title:        "Consentement marketing",
        source:       "#{Brand.host}:marketing_consent:notify_next",
        source_path:  "/confirmer",
        notes:        Crm.marketing_consent_note(at: request.marketing_consent_at, path: "/confirmer",
                                                 source: request.source || "api",
                                                 policy_version: request.marketing_consent_policy_version,
                                                 label: request.marketing_consent_label,
                                                 request: request)
      )
    end
    request.with_lock { request.update!(crm_marketing_consent_pushed_at: Time.current, crm_last_error_code: nil) }
  end

  def push_withdrawal(participants, client, request)
    return unless request.with_lock { request.crm_withdrawal_pending? }

    on_known_contact(participants, request) do |contact_id|
      client.create_interaction(
        contact_id:   contact_id,
        email:        request.email,
        kind:         "form",
        occurred_at:  request.marketing_consent_withdrawn_at.iso8601,
        title:        "Retrait du consentement marketing",
        source:       "#{Brand.host}:withdrawal:notify_next",
        source_path:  "/mc/withdraw",
        notes:        "Retrait exprimé via lien dédié (jeton à usage unique)."
      )
    end
    request.with_lock { request.update!(crm_withdrawal_pushed_at: Time.current, crm_last_error_code: nil) }
  end

  def on_known_contact(participants, request, &)
    participants.on_contact(Integer(request.crm_contact_id), email: request.email,
                                                            relocated: ->(id) { track_contact_id(request, id) },
                                                            consented_at: request.confirmed_at, &)
  end

  def build_client
    Crm::HttpContactsClient.new
  end

  def track_contact_id(request, contact_id)
    request.with_lock { request.update!(crm_contact_id: contact_id.to_s) }
  end

  def interaction_note(request)
    [ "Demande confirmée le #{request.confirmed_at.iso8601} (double opt-in).", *request.detail_lines ].join("\n")
  end
end
