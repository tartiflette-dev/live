# frozen_string_literal: true

# Chaque minute (config/recurring.yml), le transcripteur de chaque captation
# ouverte est vérifié : un agent tombé en plein direct, une salle recréée ou un
# dispatch perdu se réparent sans geste. Candidats : direct en cours, ou
# composite actif avant le go_live, dans la même borne d'âge que la fenêtre
# d'enregistrement ; TranscriberPresence revérifie chacun.
class TranscriberSweepJob < ApplicationJob
  queue_as :default

  def perform
    cutoff = Time.current - TrackRecordingSession.window_max_hours.hours
    stage_captures = Recording.composite.active.where(started_at: cutoff..).select(:webinar_id)
    capturing = Webinar.where(state: "live").or(Webinar.where(id: stage_captures)).where.not(state: "ended")
    capturing.pluck(:id).each { |id| TranscriberPresenceJob.perform_later(id) }
  end
end
