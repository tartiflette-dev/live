# frozen_string_literal: true

# Proposition de chapitres d'un café par le LLM local (ChapterProposal), puis
# mise à jour de l'index de recherche des replays (ReplaySearchIndex).
#
# Enfilé à la fin du direct (LiveEnding, après END_OF_LIVE_DELAY : les
# derniers segments sont arrivés), à la publication du replay
# (WebinarReplaysController) et par `bin/rails replays:chapitres` (cafés
# passés). Rejouable : rien n'est redemandé au LLM si la transcription n'a pas
# changé depuis la dernière proposition, sauf `force` ; un jeu VALIDÉ par
# l'animation n'est jamais remplacé.
#
# Jamais pendant un direct : le GPU du LLM est aussi celui de la
# transcription. Ce webinaire repris : rien, il sera relancé à sa nouvelle
# fin. Un autre direct en cours remet le travail à LIVE_RETRY. Un direct qui
# commence pendant la proposition l'arrête avant le passage suivant (rien
# n'est écrit, même report). Un travail à la fois sur toute l'instance (même
# GPU).
#
# Le LLM lit plusieurs minutes : si l'animation valide ou relit les chapitres
# pendant ce temps, la proposition n'est pas écrite (ChapterSet#propose!,
# issue journalisée « superseded_by_review »).
#
# Issues (ChapterSet#llm_outcome) : ok, partial (passages sautés, dont ceux
# hors délai), invalid, no_transcript, llm_disabled / llm_unconfigured (LLM
# coupé), unreachable. Une panne laisse la proposition précédente en place et
# ne retient pas l'empreinte de la transcription : le passage suivant
# réessaie. LLM indisponible = aucun chapitre, rien d'autre ne change. Journaux :
# identifiants, issue, durée et nombre de chapitres, JAMAIS le texte.
class ChapterProposalJob < ApplicationJob
  queue_as :default

  END_OF_LIVE_DELAY = 10.minutes
  LIVE_RETRY = 20.minutes

  limits_concurrency to: 1, key: "chapter-proposal", duration: 30.minutes

  retry_on ActiveRecord::ActiveRecordError, wait: 30.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(webinar_id, force: false)
    webinar = Webinar.find(webinar_id)
    return if webinar.live?
    return self.class.set(wait: LIVE_RETRY).perform_later(webinar_id, force: force) if Webinar.live.exists?

    outcome = propose(webinar, force)
    ReplaySearchIndex.refresh(webinar)
    Rails.logger.info("[chapter_proposal] webinar=#{webinar.id} outcome=#{outcome}")
  rescue ChapterProposal::Halted
    Rails.logger.info("[chapter_proposal] webinar=#{webinar_id} outcome=halted_by_live")
    self.class.set(wait: LIVE_RETRY).perform_later(webinar_id, force: force)
  end

  private

  def propose(webinar, force)
    set = webinar.chapter_set || ChapterSet.create_or_find_by!(webinar: webinar)
    digest = ChapterSet.transcript_digest(webinar)
    return "validated" if set.validated?
    return "unchanged" unless force || set.generated_at.nil? || set.stale?(digest)

    read_at = set.reload.updated_at
    segments = webinar.transcript_segments.chronological.to_a
    return record_failure(set, "no_transcript") if segments.empty?

    client = Rails.configuration.x.chapter_llm_client_factory.call
    return record_failure(set, LocalLlmClient.unavailable_reason) if client.nil?

    run(set, webinar, segments, client, digest, read_at)
  end

  def run(set, webinar, segments, client, digest, read_at)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = ChapterProposal.new(webinar, segments, client: client, halt: -> { Webinar.live.exists? }).call
    written = set.propose!(result.drafts, outcome: result.outcome, model: client.model, digest: digest, read_at: read_at)
    return "superseded_by_review" unless written

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    "#{result.outcome} chapters=#{result.drafts.size} model=#{client.model} duration_ms=#{duration_ms}"
  rescue LocalLlmClient::Error
    record_failure(set, "unreachable")
  end

  # Issue posée sans toucher aux chapitres ni à l'empreinte : le passage
  # suivant réessaie.
  def record_failure(set, outcome)
    set.update_columns(llm_outcome: outcome)
    outcome
  end
end
