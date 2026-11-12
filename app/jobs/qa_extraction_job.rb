# frozen_string_literal: true

# File Q&R extraite du chat. Enfilé après la création
# de chaque message (Message#enqueue_qa_extraction).
#
#   LLM actif et réponse valide → question pertinente : nouvel item (source
#     llm) ou rattachement à la question ouverte qu'elle redit ; sinon rien.
#     Une mention @animateur que le LLM reconnaît comme question entre même
#     jugée hors sujet : la personne s'adresse explicitement à l'animation.
#     Une mention qui n'est pas une question (« @animateur merci ! ») reste
#     au chat (et au panneau Questions de la salle), pas à la file.
#   LLM coupé (QA_LLM_ENABLED ≠ "true") ou activé sans QA_LLM_URL (issue
#     journalisée : llm_disabled ou llm_unconfigured), injoignable, sortie invalide, erreur
#     imprévue, ou message de plus de MAX_AGE au moment du traitement (file
#     en retard, direct terminé : le GPU de la dictée n'est pas occupé pour
#     rien) → FAIL-OPEN : une mention @animateur (kind question) entre brute
#     (source mention) ; un chat ordinaire est ignoré.
#
# Jamais analysés : messages de l'animation (elle ne se pose pas de
# questions), messages neutralisés par `crm:erase` (CrmErasure — leur texte
# ne doit pas revenir), et le bavardage manifeste (#chatter?).
#
# Chaque appel au LLM est chronométré, journalisé et son issue posée sur le
# webinaire (`qa_llm_outcome`, `qa_llm_at`, `qa_llm_duration_ms`) : la
# console de régie montre l'état réel de l'analyse, pas seulement le drapeau.
#
# Un job à la fois par webinaire (Solid Queue) : deux personnes qui posent la
# même question coup sur coup sont dédoublonnées, la seconde voit la première
# dans le prompt. Une erreur de base (verrou SQLite, écriture) est retentée
# deux fois ; au-delà, le job échoue en clair dans Solid Queue. Journaux :
# identifiants, issue et durée, JAMAIS le texte.
class QaExtractionJob < ApplicationJob
  queue_as :default

  MAX_AGE = 2.minutes
  MIN_WORDS = 4
  # Salutation en tête et message court sans tournure interrogative :
  # « Bonjour depuis Lyon, ravie d'être là ! », « Merci beaucoup à vous ».
  GREETING = /\A[[:punct:][:space:]]*(?:bonjour|bonsoir|salut|hello|hey|coucou|merci|bravo|re)\b/i
  GREETING_WORDS = 8
  INTERROGATIVE = /\b(?:comment|pourquoi|quand|quel(?:le)?s?|combien|où|est-ce|peut-on|savoir)\b/i
  LLM_OUTCOMES = { LocalLlmClient::Timeout => "timeout", LocalLlmClient::Error => "unreachable",
                   QaExtraction::InvalidOutput => "invalid" }.freeze

  limits_concurrency to: 1, key: ->(message_id) { "qa-extraction-#{Message.where(id: message_id).pick(:webinar_id)}" },
    duration: 2.minutes

  retry_on ActiveRecord::ActiveRecordError, wait: 5.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(message_id)
    message = Message.find(message_id)
    return log(message, "skipped") unless analysable?(message)

    client = Rails.configuration.x.qa_llm_client_factory.call
    outcome = if client.nil? then fallback(message, LocalLlmClient.unavailable_reason)
    elsif message.created_at < MAX_AGE.ago then fallback(message, "stale")
    else extract(message, client)
    end
    log(message, outcome)
  end

  private

  def analysable?(message)
    message.author_role != "host" && message.body != CrmErasure::ERASED_BODY && !chatter?(message)
  end

  # Ni lettre (émojis, ponctuation seule), ou chat sans « ? » trop court, ou
  # salutation courte sans tournure interrogative. Une mention @animateur
  # n'est jamais du bavardage.
  def chatter?(message)
    body = message.body
    return true unless body.match?(/\p{L}/)
    return false if message.question? || body.include?("?") || body.match?(INTERROGATIVE)

    words = body.split.size
    words < MIN_WORDS || (words <= GREETING_WORDS && body.match?(GREETING))
  end

  def extract(message, client)
    verdict = analyse(message, client)
    return "ignored" unless verdict.question? && (verdict.relevant? || message.question?)

    item = QaItem.enqueue!(message: message, label: verdict.label, source: "llm", llm_model: client.model,
                           duplicate_of: verdict.duplicate_of)
    return "erased" unless item

    broadcast(item)
    item.enqueued.to_s
  rescue LocalLlmClient::Error, QaExtraction::InvalidOutput => error
    fallback(message, "llm_failed:#{error.class.name.demodulize}")
  rescue ActiveRecord::ActiveRecordError
    raise
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { job: self.class.name, message_id: message.id })
    fallback(message, "unexpected:#{error.class.name}")
  end

  # Appel chronométré ; issue et durée posées sur le webinaire, même en échec.
  def analyse(message, client)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = "ok"
    QaExtraction.new(message, client: client).call
  rescue StandardError => error
    status = LLM_OUTCOMES.find { |klass, _| error.is_a?(klass) }&.last || "error"
    raise
  ensure
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    message.webinar.update_columns(qa_llm_outcome: status, qa_llm_at: Time.current, qa_llm_duration_ms: duration_ms)
    Rails.logger.info("[qa_extraction] llm webinar=#{message.webinar_id} message=#{message.id} model=#{client.model} " \
                      "status=#{status} duration_ms=#{duration_ms}")
  end

  def fallback(message, reason)
    return "ignored(#{reason})" unless message.question?

    item = QaItem.enqueue!(message: message, label: message.body, source: "mention")
    return "erased" unless item

    broadcast(item)
    "mention(#{reason})"
  end

  def broadcast(item)
    QaBroadcast.new.deliver(item.webinar)
  end

  def log(message, outcome)
    Rails.logger.info("[qa_extraction] webinar=#{message.webinar_id} message=#{message.id} kind=#{message.kind} outcome=#{outcome}")
  end
end
