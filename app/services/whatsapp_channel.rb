# frozen_string_literal: true

# WhatsappChannel — envoi WhatsApp des notifications d'épisode : DÉSACTIVÉ.
#
# Aucun canal d'envoi WhatsApp n'est fourni à l'application : pas d'API
# d'envoi joignable depuis son conteneur, aucune ligne WhatsApp ; les
# intervenants n'ont pas de numéro dans l'application.
#
# Un vrai canal répond au même contrat (`enabled?`, `deliver(speaker:,
# text:)`) et s'injecte dans EpisodeNotification sans toucher au reste.
class WhatsappChannel
  def enabled?
    false
  end

  def deliver(speaker:, text:)
    raise NotImplementedError, "aucun canal WhatsApp utilisable par l'application"
  end
end
