# frozen_string_literal: true

# Fin du direct — chemin UNIQUE de « Terminer le direct » (bouton de
# l'animateur, WebinarStatesController#end_live) et de la fin automatique
# d'une salle restée vide (AutoEndLiveJob). Les deux répondent au même
# acteur, l'animateur qui clôt son direct : la question SRP est tranchée, une seule définition de ce que « terminer »
# veut dire.
#
# Ordre : la transition d'abord (garde d'entrée — un direct qui n'est pas
# en cours lève TransitionError SANS toucher aux enregistrements), puis
# tous les enregistrements arrêtés (chaque arrêt tenté, les échecs restent
# portés par leur Recording), le sondage resté ouvert fermé, le montage par
# personne, le transcripteur
# congédié, une réconciliation différée qui arrête tout ce qu'un
# démarrage concurrent aurait relancé après coup, et la proposition différée
# des chapitres du replay (ChapterProposalJob).
class LiveEnding
  # Le temps qu'un démarrage en vol (scène rechargée, piste publiée au
  # dernier moment) ait répondu.
  RECONCILE_DELAY = 1.minute

  def initialize(webinar, egress_client: RecordingSession.default_client,
                 room_client: Rails.configuration.x.room_service_client_factory.call)
    @webinar = webinar
    @egress_client = egress_client
    @room_client = room_client
  end

  # @raise [Webinar::TransitionError] si le direct n'est pas en cours
  # @return [Array<Hash>] résultats d'arrêt, cf. RecordingSession.stop_all
  def call
    @webinar.end!
    results = RecordingSession.stop_all(@webinar, client: @egress_client)
    close_open_poll
    enqueue_participant_muxes
    dismiss_transcriber
    ReconcileRecordingsJob.set(wait: RECONCILE_DELAY).perform_later(@webinar.id)
    ChapterProposalJob.set(wait: ChapterProposalJob::END_OF_LIVE_DELAY).perform_later(@webinar.id)
    results
  end

  private

  # Un sondage resté ouvert est fermé et la salle en est avertie : la pop-up
  # ne propose plus de répondre à un sondage qui refuserait la réponse.
  # Après l'arrêt des enregistrements, et jamais bloquant : une panne ici est
  # journalisée ; le serveur refuse de toute façon les réponses hors direct.
  def close_open_poll
    PollBroadcast.new(client: @room_client).deliver(@webinar) if Poll.close_open_for(@webinar)
  rescue StandardError => e
    Rails.logger.warn("[live_ending] sondage non fermé webinar=#{@webinar.id} err=#{e.class}: #{e.message}")
  end

  # Filet du montage par personne : chaque identité qui a au moins une
  # piste `done` et plus aucune active. FinalizeEgressJob l'a souvent déjà
  # planifié au moment où sa dernière piste a terminé ; ici on couvre une
  # piste terminée en `failed` sans webhook abouti. Le job ne refait rien
  # pour des pistes déjà montées.
  def enqueue_participant_muxes
    tracks = @webinar.recordings.tracks.where.not(participant_identity: [ nil, "" ])
    identities = tracks.where(status: "done").distinct.pluck(:participant_identity)
    busy = tracks.where(status: Recording::ACTIVE_STATUSES).distinct.pluck(:participant_identity)

    (identities - busy).each { |identity| MuxParticipantJob.perform_later(@webinar.id, identity) }
  end

  # Fin du direct = le transcripteur quitte la salle. Sans cela l'agent reste
  # tant qu'un participant est connecté (la salle ne se ferme pas), et
  # continue de transcrire et d'archiver après la fin (test-29-10). Une
  # reprise le rappelle (TranscriberPresence). Une transcription interrompue
  # se clôt avec le direct (Webinar::TranscriptionOutage).
  def dismiss_transcriber
    TranscriberPresence.new(@webinar, room_client: @room_client).dismiss
    @webinar.end_transcription_outage!(:capture_closed)
  end
end
