# Tentatives vues par l'app pour le journal de présence (PresenceEvent) :
# page du café ou lien intervenant ouvert, accès à la salle délivré. Écriture
# de confort : un échec ne coûte jamais la page ni le jeton.
module PresenceCapture
  extend ActiveSupport::Concern

  private

  def note_presence_attempt(webinar, kind, identity)
    PresenceEvent.record_attempt!(webinar, kind, identity)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[presence] attempt not noted webinar=#{webinar.slug} kind=#{kind} err=#{e.class}")
  end
end
