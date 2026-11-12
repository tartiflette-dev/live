# frozen_string_literal: true

# EpisodePublicationSweepJob — déclencheur automatique de la publication
# (config/recurring.yml, toutes les 5 min) : chaque direct terminé est
# publié dès que EpisodePublication.due? le permet (direct public, terminé
# depuis 10 min à 24 h, enregistrements finalisés…).
#
# Balayage plutôt qu'un appel depuis la fin du direct : il ne dépend
# d'aucun ordre d'arrivée entre l'arrêt des enregistrements, les webhooks
# de l'egress et les assemblages, et rattrape un événement perdu. Les
# conditions vivent toutes dans EpisodePublication.automatic_hold ; le
# volume (quelques directs par semaine) permet de les relire chacune.
class EpisodePublicationSweepJob < ApplicationJob
  queue_as :default

  # Un épisode qui attend ses versions légères les demande d'abord à l'hôte
  # (LightVersion#request! : une demande à jour n'est pas réécrite).
  def perform(now: Time.current)
    Webinar.ended.find_each do |webinar|
      if EpisodePublication.automatic_hold(webinar, now: now) == :lightening
        EpisodePublication.waiting_light_versions(webinar, now).each { |light| light.request!(now) }
      end
      EpisodePublication.enqueue!(webinar) if EpisodePublication.due?(webinar, now: now)
    end
  end
end
