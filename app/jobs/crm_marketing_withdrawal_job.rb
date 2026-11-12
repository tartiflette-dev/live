# frozen_string_literal: true

# Propage un retrait de consentement marketing au CRM.
#
# Le contrat HTTP du CRM n'a pas d'appel « ne plus contacter » sur la
# fiche (docs/registrations-api.md). On trace donc le retrait via une
# Interaction `kind=form`, `source` dédié — exploitable côté CRM pour
# filtrer les contacts qui ont retiré leur consentement.
#
# Le retrait porte sur la PROSPECTION : la fiche du participant reste au
# CRM (base légale : intérêt légitime, RGPD art. 6.1.f) ; seule
# l'autorisation de recontact tombe.
#
# Invariants :
# - Rien n'est envoyé si `CRM_SYNC_ENABLED != "1"`.
# - Rien n'est envoyé si aucune fiche n'existe côté CRM (no-op).
# - Jamais de PII dans les logs ou les erreurs — mêmes règles que
#   `CrmSyncJob` (cf. `Crm::HttpContactsClient`).
# - Retry borné sur transient ; discard sur permanent / RecordNotFound /
#   ArgumentError (client non configuré : jeton ou URL du CRM absents).
class CrmMarketingWithdrawalJob < ApplicationJob
  queue_as :crm

  # Sérialisé avec CrmSyncJob pour la même personne (cf. `Crm`).
  limits_concurrency to: 1, group: Crm::CONTACT_CONCURRENCY_GROUP, duration: 15.minutes,
    key: ->(registration_id) { Crm.contact_concurrency_key(Registration.find_by(id: registration_id)&.email) }

  retry_on Crm::TransientError, wait: :polynomially_longer, attempts: 5

  discard_on Crm::PermanentError do |job, error|
    Rails.logger.warn(
      "[CrmMarketingWithdrawalJob] permanent_discard registration_id=#{job.arguments.first} " \
        "http_status=#{error.http_status.to_i}"
    )
    # Compteur PROPRE au retrait (jamais `crm_sync_attempts`) : une
    # inscription en échec ne doit pas retarder la propagation d'un retrait.
    CrmMarketingWithdrawalJob.record_withdrawal_failure(job.arguments.first, error)
  end

  discard_on ActiveRecord::RecordNotFound

  discard_on ArgumentError do |job, error|
    Rails.logger.warn(
      "[CrmMarketingWithdrawalJob] discarded registration_id=#{job.arguments.first} " \
        "reason=#{Crm.discard_reason(error)}"
    )
  end

  def perform(registration_id)
    return unless ENV["CRM_SYNC_ENABLED"] == "1"

    registration = Registration.find(registration_id)
    # Idempotence (garantie 4) : si le retrait a déjà été propagé, on ne
    # pousse PAS une seconde Interaction (évite doublon côté CRM en cas
    # de double clic utilisateur ou de retry après succès partiel).
    return if registration.crm_withdrawal_pushed?
    return unless registration.marketing_consent_withdrawn?

    client = build_client

    # Résolution du contact côté CRM :
    #   1. Priorité à `crm_contact_id` tracé localement (posé par
    #      `CrmSyncJob` immédiatement après `find_or_create_contact`,
    #      même si l'interaction d'inscription n'a jamais eu lieu).
    #   2. Fallback `search_by_email` : couvre le cas où `CrmSyncJob` n'a
    #      jamais tourné (drapeau activé entre consentement et retrait) ou
    #      a crashé avant de persister `crm_contact_id`.
    #   3. No-op si aucun contact : rien à retirer côté CRM.
    #   4. 404 (id local périmé après une fusion côté CRM) : nouveau
    #      lookup et un seul nouvel essai (Crm::ParticipantSync#on_contact).
    contact_id = resolve_contact_id(client, registration)
    return if contact_id.nil?

    Crm::ParticipantSync.new(client).on_contact(contact_id, email: registration.email,
                                                            relocated: ->(id) { contact_id = id }) do |target_id|
      client.create_interaction(
        contact_id:   target_id,
        email:        registration.email,
        kind:         "form",
        occurred_at:  (registration.marketing_consent_withdrawn_at || Time.current).iso8601,
        title:        "Retrait du consentement marketing",
        source:       "#{Brand.host}:withdrawal:#{registration.webinar.slug}",
        source_path:  "/mc/withdraw",
        notes:        "Retrait exprimé via lien dédié (jeton à usage unique)."
      )
    end

    # Pose atomique de `crm_withdrawal_pushed_at` : un retry après succès
    # HTTP mais crash entre l'HTTP et l'update retrouvera `crm_withdrawal_pushed_at`
    # nil et ré-émettra l'interaction. Côté CRM, deux `Interaction kind=form
    # source=<Brand.host>:withdrawal:<slug>` sur le même contact sont
    # bénignes (traçabilité multiple du même acte) ; côté client, on
    # minimise le risque en ne verrouillant qu'un bref instant.
    registration.with_lock do
      registration.update!(
        crm_withdrawal_pushed_at: Time.current,
        crm_contact_id: contact_id.to_s,
        crm_withdrawal_last_error_code: nil
      )
    end
  rescue Crm::ContactGoneError
    # Fiche introuvable : JAMAIS un succès (l'effacement est inféré ; un
    # email changé côté CRM laisserait la personne prospectée malgré son
    # retrait). Échec permanent dédié, visible de la sonde.
    Rails.logger.warn("[CrmMarketingWithdrawalJob] #{Crm::WithdrawalContactNotFoundError::CODE} " \
                      "registration_id=#{registration_id}")
    raise Crm::WithdrawalContactNotFoundError
  rescue Crm::RateLimitedError => error
    Crm::Backlog.defer(:withdrawals, registration_id, error, job: self.class)
  rescue Crm::TransientError => error
    Rails.logger.warn(
      "[CrmMarketingWithdrawalJob] transient_retry registration_id=#{registration_id} " \
        "http_status=#{error.http_status.to_i}"
    )
    self.class.record_withdrawal_failure(registration_id, error)
    raise
  end

  def self.record_withdrawal_failure(registration_id, error)
    Registration.where(id: registration_id)
                .update_all([ "crm_withdrawal_attempts = crm_withdrawal_attempts + 1, " \
                              "crm_withdrawal_last_error_code = ?, crm_withdrawal_last_attempt_at = ?",
                              error.http_status.to_i, Time.current ])
  end

  private

  def build_client
    Crm::HttpContactsClient.new
  end

  # Priorité à `crm_contact_id` tracé localement ; fallback `search_by_email`
  # pour couvrir le cas « contact créé côté CRM mais crash avant pose du
  # contact_id en local ». Renvoie l'id entier ou nil (no-op au niveau du job).
  def resolve_contact_id(client, registration)
    return registration.crm_contact_id.to_i if registration.crm_contact_id.present?

    known = Crm.known_contact_id(registration.email)
    return known.to_i if known

    hit = client.search_by_email(registration.email)
    hit && hit["id"]&.to_i
  end
end
