# frozen_string_literal: true

# Fin automatique du direct (« est-ce que je suis garanti que le direct s'arrête tout seul ? »).
#
# Le webhook LiveKit `room_finished` d'un direct en cours relève la vacance
# (Webinar#room_empty_since) et programme ce job AUTO_END_DELAY plus tard.
# Au moment d'agir, le job revérifie tout et ne termine le direct que si :
#   • le direct est toujours en cours ;
#   • la salle est vide depuis au moins AUTO_END_DELAY — un participant
#     revenu entre-temps (webhook `participant_joined`) a effacé la vacance,
#     un nouveau départ en a posé une plus récente ;
#   • LiveKit ne compte aucun participant humain dans la salle (filet
#     contre des webhooks arrivés dans le désordre ou perdus). LiveKit
#     injoignable ou en erreur : une seconde vérification
#     PRESENCE_RECHECK_DELAY plus tard ; s'il ne répond toujours pas, la
#     vacance relevée par webhook fait foi.
# Une coupure réseau des animateurs ne termine donc rien s'ils reviennent
# dans le délai. La fin suit exactement le chemin de « Terminer le direct »
# (LiveEnding).
class AutoEndLiveJob < ApplicationJob
  queue_as :default

  AUTO_END_DELAY = 15.minutes
  PRESENCE_RECHECK_DELAY = 5.minutes

  def self.schedule(webinar)
    set(wait: AUTO_END_DELAY).perform_later(webinar.id)
  end

  def perform(webinar_id, presence_rechecked = false)
    webinar = Webinar.find_by(id: webinar_id)
    return unless webinar&.live?

    empty_since = webinar.room_empty_since
    return if empty_since.nil? || empty_since > AUTO_END_DELAY.ago

    case presence(webinar)
    when :occupied
      return
    when :unknown
      unless presence_rechecked
        self.class.set(wait: PRESENCE_RECHECK_DELAY).perform_later(webinar.id, true)
        return
      end
    end

    LiveEnding.new(webinar).call
    Rails.logger.info("[auto_end_live] direct terminé webinar=#{webinar.slug} salle vide depuis #{empty_since.iso8601}")
  rescue Webinar::TransitionError
    # Terminé entre-temps par l'animateur : rien à faire.
  end

  private

  # :occupied — au moins un participant humain (l'enregistreur et le
  #   transcripteur ne comptent pas) ;
  # :empty     — aucun participant humain. Pour une salle qu'il ne connaît
  #   plus (cas nominal après `room_finished`), LiveKit renvoie une liste
  #   vide ; un refus `not_found`, s'il survenait, vaut aussi salle vide ;
  # :unknown   — LiveKit injoignable, en erreur ou non configuré.
  def presence(webinar)
    participants = Rails.configuration.x.room_service_client_factory.call.list_participants(room: webinar.room_name)
    participants.any? { |participant| participant[:kind].to_s.in?([ "", "STANDARD" ]) } ? :occupied : :empty
  rescue RoomServiceClient::RemoteError => e
    return :empty if e.code == "not_found"

    Rails.logger.info("[auto_end_live] présence non vérifiable webinar=#{webinar.slug} : #{e.message}")
    :unknown
  rescue RoomServiceClient::Error => e
    Rails.logger.info("[auto_end_live] présence non vérifiable webinar=#{webinar.slug} : #{e.message}")
    :unknown
  end
end
