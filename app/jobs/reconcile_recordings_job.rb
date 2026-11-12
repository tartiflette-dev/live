# frozen_string_literal: true

# Réconciliation différée des enregistrements d'un webinaire.
# Planifiée par LiveEnding juste après la fin du direct : un
# démarrage en vol au moment de la fin (scène rechargée, piste publiée au
# dernier moment) a pu relancer un egress que l'arrêt n'a pas vu.
# RecordingSession.reconcile arrête tout Recording encore actif d'un
# webinaire terminé.
class ReconcileRecordingsJob < ApplicationJob
  queue_as :default

  def perform(webinar_id)
    webinar = Webinar.find_by(id: webinar_id)
    RecordingSession.reconcile(webinar) if webinar
  end
end
