class FinalizeEgressJob < ApplicationJob
  queue_as :default

  def perform(info)
    return unless info.is_a?(Hash) && info["egress_id"].present?
    webinar = Webinar.find_by(room_name: info["room_name"])
    return unless webinar

    recording = Recording.for_egress_info(webinar, info)
    return unless recording

    EgressCompletion.apply(recording, egress_id: info["egress_id"], status: info["status"],
      files: Array(info["file_results"]).filter_map { |file| file["filename"] if file.is_a?(Hash) })

    # Déclenchement du mux par personne. On ne mixe que
    # pour des pistes `track` : un composite n'a pas de participant
    # (il est déjà pré-mixé côté LiveKit). On attend qu'AUCUNE piste
    # de la personne ne soit encore active (MuxParticipantJob
    # revérifie — garde en profondeur).
    recording.reload
    if recording.track?
      enqueue_participant_mux(webinar, recording)
    elsif recording.composite?
      # La fin d'un composite côté LiveKit
      # (EGRESS_COMPLETE / FAILED / ABORTED) ferme la fenêtre
      # d'enregistrement — même invariant que RecordingSession.stop.
      # Les pistes rattrapées via la fenêtre composite doivent cascader
      # ici aussi, sinon un composite qui expire côté serveur sans
      # qu'on l'ait stoppé via le controller laisserait tourner les
      # pistes jusqu'à `end_live`.
      RecordingSession.cascade_stop_tracks_if_window_closed(webinar, client: RecordingSession.default_client)
    end
  end

  private

  def enqueue_participant_mux(webinar, recording)
    identity = recording.participant_identity.to_s
    return if identity.blank?

    still_active = webinar.recordings
                          .tracks
                          .where(participant_identity: identity, status: Recording::ACTIVE_STATUSES)
                          .exists?
    return if still_active

    done_count = webinar.recordings
                        .tracks
                        .where(participant_identity: identity, status: "done")
                        .count
    return if done_count.zero?

    MuxParticipantJob.perform_later(webinar.id, identity)
  end
end
