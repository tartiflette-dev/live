# frozen_string_literal: true

# PublishEpisodeJob — dépôt d'un épisode dans Nextcloud (EpisodePublisher).
# Enfilé par EpisodePublication.enqueue! (balayage automatique ou bouton).
#
# Un seul dépôt à la fois par webinaire (Solid Queue) : un clic pendant le
# balayage attend la fin du premier, puis ne trouve plus rien à envoyer.
# Une panne passagère (réseau, 408, 423, 429, 5xx, taille relue fausse) est
# rejouée sur ~1 h 20 ; la publication porte l'erreur entre deux tentatives.
# Un direct repris entre-temps n'est pas publié : le dépôt attend sa fin.
class PublishEpisodeJob < ApplicationJob
  queue_as :default
  limits_concurrency key: ->(webinar_id) { "publish-episode-#{webinar_id}" }, duration: EpisodePublication::STALL_AFTER
  retry_on NextcloudClient::TransientError, wait: :polynomially_longer, attempts: 8

  def perform(webinar_id)
    webinar = Webinar.find_by(id: webinar_id)
    return if webinar.nil?

    client = EpisodePublication.client
    series = EpisodePublication.series(webinar)
    if client.nil? || series.nil?
      webinar.episode_publication&.fail!("Publication Nextcloud non configurée (série ou compte Nextcloud absent).")
    elsif !webinar.ended?
      webinar.episode_publication&.fail!("Direct en cours : le dépôt attend sa fin.", alert: false)
    else
      EpisodePublisher.new(webinar, client: client, series: series).call
    end
  end
end
