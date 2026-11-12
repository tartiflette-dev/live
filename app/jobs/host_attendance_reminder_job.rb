# Tournée quotidienne de la présence des animateurs (config/recurring.yml) :
#   1. demandes jamais faites pour un webinaire publié à venir (webinaire
#      publié avant cette fonction, job de demande jamais exécuté) ; une
#      demande déjà comptée dont le mail s'est perdu ne repart pas ;
#   2. relance J-3 des co-animateurs sans réponse (HostAttendance.remind_due).
# Idempotente : une demande ou une relance part une fois par date. Un café du
# jour même encore à venir reçoit sa demande au passage de 10:00 : assumé, le
# co-animateur répond alors depuis son téléphone ou la page du café.
class HostAttendanceReminderJob < ApplicationJob
  queue_as :default

  def perform(now = Time.current)
    requested = Webinar.published.upcoming(now).includes(:webinar_hosts).sum { |webinar| webinar.request_host_attendances!(now) }
    reminded = HostAttendance.remind_due(now)
    Rails.logger.info("host_attendance_reminder requested=#{requested} reminded=#{reminded}")
  end
end
