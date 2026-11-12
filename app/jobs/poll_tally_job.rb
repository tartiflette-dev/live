# Compteur des réponses d'un sondage, diffusé une fois par seconde au plus
# (PollBroadcast.schedule_tally).
class PollTallyJob < ApplicationJob
  queue_as :default

  def perform(webinar)
    PollBroadcast.new.deliver(webinar)
  end
end
