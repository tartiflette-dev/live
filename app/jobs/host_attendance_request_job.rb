# Demandes de présence aux animateurs d'un webinaire
# (Webinar#request_host_attendances!) : à la publication, au changement de
# date, à l'ajout d'un co-animateur. Idempotent : rejoué, il n'envoie rien de
# plus pour la même date. Webinaire supprimé entre-temps : rien à faire.
class HostAttendanceRequestJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(webinar)
    webinar.request_host_attendances!
  end
end
