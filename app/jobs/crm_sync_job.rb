# frozen_string_literal: true

# Pousse une inscription confirmée dans le CRM.
# Deux poussées distinctes, chacune idempotente :
#
#   1. PARTICIPANT — tout inscrit confirmé entre
#      au CRM, base légale = intérêt légitime de l'organisation à suivre la relation
#      avec ses participants (art. 6.1.f, politique v1.6), pour les
#      confirmations posées depuis la politique v1.1 (`crm_enrolled_at`) :
#      fiche trouvée par email ou créée (`crm_contact_id` = identifiant
#      unique de la personne),
#      segment `participant`, interaction « Inscription webinaire — titre »
#      portant le choix spectateur / participant, et la provenance, le
#      profil et le message de la demande.
#      Marqueur : `pushed_to_crm_at`.
#   2. CONSENTEMENT MARKETING — seulement s'il a été validé (POST /mc, ou
#      bouton d'accord `marketing=1` d'une demande de l'API) et n'est pas
#      retiré : interaction dédiée, tirée de la preuve figée à l'accord
#      (dont le libellé du bouton affiché), seule autorisation de prospection côté CRM. Marqueur : `crm_marketing_consent_pushed_at`.
#
# Invariants :
# 1. Rien n'est envoyé si `CRM_SYNC_ENABLED != "1"` (drapeau MAÎTRE).
# 2. Rien n'est envoyé sans double opt-in (`confirmed_at` posé).
# 3. Le retrait du consentement gagne toujours sur la poussée 2 : état
#    relu sous verrou avant l'envoi, et un retrait arrivé pendant l'envoi
#    enqueue `CrmMarketingWithdrawalJob`. Il n'arrête pas la poussée 1 :
#    le participant reste au CRM, sans autorisation de prospection.
# 4. Jamais de PII dans les logs : registration_id et code HTTP seulement.
# 5. Erreurs transientes -> retry borné (SolidQueue). Erreurs permanentes
#    -> consignées, pas de retry (`discard_on`).
# 6. Un job CRM à la fois par personne (`Crm.contact_concurrency_key`).
class CrmSyncJob < ApplicationJob
  queue_as :crm

  # Choix spectateur / participant : dans les notes, seul
  # champ libre du contrat HTTP du CRM (segment et source_path
  # figés, docs/registrations-api.md §Format HTTP vers le CRM).
  PARTICIPATION_NOTES = {
    "spectator" => "Choix : spectateur (regarder, discussion).",
    "participant" => "Choix : participant (intervenir en caméra et micro)."
  }.freeze

  limits_concurrency to: 1, group: Crm::CONTACT_CONCURRENCY_GROUP, duration: 15.minutes,
    key: ->(registration_id) { Crm.contact_concurrency_key(Registration.find_by(id: registration_id)&.email) }

  retry_on Crm::TransientError, wait: :polynomially_longer, attempts: 5

  discard_on Crm::PermanentError do |job, error|
    registration_id = job.arguments.first
    Rails.logger.warn(
      "[CrmSyncJob] permanent_discard registration_id=#{registration_id} " \
        "http_status=#{error.http_status.to_i}"
    )
    # Une erreur permanente compte comme une tentative : CrmResyncJob espace
    # les nouveaux essais (jusqu'à 24 h) et la sonde la signale.
    Registration.where(id: registration_id)
                .update_all([ "crm_sync_attempts = crm_sync_attempts + 1, crm_last_error_code = ?, " \
                              "crm_last_attempt_at = ?", error.http_status.to_i, Time.current ])
  end

  discard_on ActiveRecord::RecordNotFound

  # Client non configuré (`CRM_API_TOKEN` ou `CRM_BASE_URL`
  # absente : Crm::UnconfiguredError, une ArgumentError) ou autre
  # ArgumentError : une nouvelle tentative n'y changerait rien. On jette le
  # job et on logue, sans PII, la variable à poser (Crm.discard_reason).
  discard_on ArgumentError do |job, error|
    Rails.logger.warn(
      "[CrmSyncJob] discarded registration_id=#{job.arguments.first} " \
        "reason=#{Crm.discard_reason(error)}"
    )
  end

  def perform(registration_id)
    return unless ENV["CRM_SYNC_ENABLED"] == "1"

    registration = Registration.find(registration_id)
    return unless registration.crm_sync_eligible?
    return if registration.crm_pushed? && !registration.crm_marketing_consent_pending?

    client = build_client
    push_participant(client, registration) unless registration.crm_pushed?
    push_marketing_consent(client, registration) if registration.crm_marketing_consent_pending?
  rescue Crm::ContactGoneError => error
    Crm::Backlog.close_gone(:registrations, registration_id, error, job: self.class)
  rescue Crm::RateLimitedError => error
    Crm::Backlog.defer(:registrations, registration_id, error, job: self.class)
  rescue Crm::TransientError => error
    # On ne persiste QUE le code HTTP — jamais `error.message` (invariant
    # sécurité : les messages CRM pouvaient contenir des bribes de corps).
    Rails.logger.warn(
      "[CrmSyncJob] transient_retry registration_id=#{registration_id} " \
        "http_status=#{error.http_status.to_i} " \
        "attempts=#{registration&.crm_sync_attempts.to_i + 1}"
    )
    Registration.where(id: registration_id).update_all(
      crm_sync_attempts: registration&.crm_sync_attempts.to_i + 1,
      crm_last_error_code: error.http_status.to_i,
      crm_last_attempt_at: Time.current
    )
    raise
  end

  private

  # Permet au test de brancher un faux client sans toucher à l'ENV.
  def build_client
    Crm::HttpContactsClient.new
  end

  # Segment AVANT interaction : un échec permanent du segment abandonne
  # avant d'écrire l'interaction ; la reprise retrouve la fiche par email et
  # ne duplique rien. Le segment est idempotent côté CRM (200 si déjà
  # présent) : le nouvel essai après relocalisation peut le reposer.
  def push_participant(client, registration)
    participants = Crm::ParticipantSync.new(client)
    target = participants.find_or_create_contact(
      email: registration.email, name: registration.name, own_id: registration.crm_contact_id,
      consented_at: registration.crm_enrolled_at
    )

    # Persistance ATOMIQUE de `crm_contact_id` dès la fiche connue (revue
    # sécurité tour 5) : `CrmMarketingWithdrawalJob` doit pouvoir propager
    # un retrait sur une fiche créée par un job interrompu ensuite. Un id
    # EMPRUNTÉ n'est persisté qu'une fois l'écriture passée : persisté avant,
    # il passerait au nouvel essai pour celui de la ligne, dont la fiche
    # effacée ne se recrée pas.
    track_contact_id(registration, target.id) unless target.borrowed

    pushed_id = nil
    participants.on_contact(target.id, email: registration.email,
                                       relocated: ->(id) { track_contact_id(registration, id) },
                                       consented_at: registration.crm_enrolled_at) do |contact_id|
      pushed_id = contact_id
      participants.tag_participant(contact_id, email: registration.email)
      client.create_interaction(
        contact_id:   contact_id,
        email:        registration.email,
        kind:         "form",
        occurred_at:  registration.confirmed_at.iso8601,
        title:        "Inscription webinaire — #{registration.webinar.title}",
        source:       "#{Brand.host}:#{registration.webinar.slug}",
        source_path:  "/w/#{registration.webinar.slug}",
        notes:        participant_note(registration)
      )
    end
    track_contact_id(registration, pushed_id) if target.borrowed

    registration.with_lock do
      registration.update!(
        pushed_to_crm_at: Time.current,
        crm_sync_attempts: registration.crm_sync_attempts + 1,
        crm_last_error_code: nil
      )
    end
  end

  # `with_lock` relit la ligne : un retrait posé depuis le début du job
  # (MarketingWithdrawalsController verrouille aussi) annule l'envoi.
  def push_marketing_consent(client, registration)
    still_pending = registration.with_lock { registration.crm_marketing_consent_pending? }
    return unless still_pending

    Crm::ParticipantSync.new(client).on_contact(
      Integer(registration.crm_contact_id), email: registration.email,
      relocated: ->(id) { track_contact_id(registration, id) },
      consented_at: registration.crm_enrolled_at
    ) do |contact_id|
      client.create_interaction(
        contact_id:   contact_id,
        email:        registration.email,
        kind:         "form",
        occurred_at:  registration.marketing_consent_at.iso8601,
        title:        "Consentement marketing",
        source:       "#{Brand.host}:marketing_consent:#{registration.webinar.slug}",
        source_path:  registration.marketing_consent_path || "/mc",
        notes:        marketing_consent_note(registration)
      )
    end

    # Un retrait arrivé PENDANT l'envoi : le CRM a reçu le consentement,
    # on propage immédiatement le retrait (« le retrait gagne toujours »).
    withdrawn_during_send = registration.with_lock do
      registration.update!(crm_marketing_consent_pushed_at: Time.current)
      registration.marketing_consent_withdrawn?
    end
    CrmMarketingWithdrawalJob.perform_later(registration.id) if withdrawn_during_send
  end

  def marketing_consent_note(registration)
    Crm.marketing_consent_note(
      at: registration.marketing_consent_at, path: registration.marketing_consent_path,
      source: registration.marketing_consent_source, policy_version: registration.marketing_consent_policy_version,
      label: registration.marketing_consent_label,
      request: RegistrationRequest.find_by(id: registration.marketing_consent_request_id)
    )
  end

  def track_contact_id(registration, contact_id)
    registration.with_lock { registration.update!(crm_contact_id: contact_id.to_s) }
  end

  def participant_note(registration)
    [
      "Inscription confirmée le #{registration.confirmed_at.iso8601} (double opt-in).",
      PARTICIPATION_NOTES.fetch(registration.participation),
      *registration.registration_request&.detail_lines
    ].join("\n")
  end
end
