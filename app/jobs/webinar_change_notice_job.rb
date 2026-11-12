# Fin du délai d'apaisement d'un changement de webinaire
# (WebinarChangeNotice::QUIET_PERIOD) : annonce l'écart, si ce changement est
# encore le dernier. Rejouable sans doublon.
class WebinarChangeNoticeJob < ApplicationJob
  queue_as :default
  # Webinaire supprimé entre-temps (la trace part avec lui) : rien à annoncer.
  discard_on ActiveJob::DeserializationError

  def perform(notice, revision)
    notice.announce!(revision)
  end
end
