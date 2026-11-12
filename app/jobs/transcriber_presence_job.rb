# frozen_string_literal: true

# Garantit le transcripteur dans la salle d'un webinaire (TranscriberPresence).
# Une vérification à la fois par webinaire, les suivantes abandonnées : deux
# vérifications simultanées verraient la salle sans agent et en dispatcheraient
# deux, soit chaque phrase archivée deux fois. Celle de la minute suivante
# (TranscriberSweepJob) rattrape ce qu'un abandon aurait manqué.
class TranscriberPresenceJob < ApplicationJob
  queue_as :default
  limits_concurrency key: ->(webinar_id) { "transcriber-presence-#{webinar_id}" },
                     duration: 1.minute, on_conflict: :discard

  # Le résultat nourrit la détection d'une transcription interrompue
  # (Webinar::TranscriptionOutage) ; LiveKit injoignable n'observe rien.
  def perform(webinar_id)
    webinar = Webinar.find_by(id: webinar_id)
    return unless webinar

    webinar.transcriber_observed!(TranscriberPresence.new(webinar).ensure_present)
  rescue RoomServiceClient::Error => e
    Rails.logger.warn("[transcriber_presence] webinar=#{webinar_id} non vérifié : #{e.message}")
  end
end
