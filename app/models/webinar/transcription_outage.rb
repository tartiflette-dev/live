# Transcription absente pendant un direct : « tout ce qui arrive doit être
# transcrit en direct, point. » TranscriberPresence rappelle l'agent chaque
# minute ; si cela ne suffit pas (agent arrêté, nom d'agent divergent, agent
# déployé avant l'app), l'animation et l'équipe doivent le savoir PENDANT le
# direct, pas après coup.
#
# Chaque vérification de présence (TranscriberPresenceJob) est observée :
#   • salle occupée sans agent : l'absence est datée à la première
#     observation (`transcriber_absent_since`) ; au-delà d'ABSENCE_LIMIT,
#     la transcription est interrompue (`transcription_interrupted_at`) :
#     bandeau de la régie, journal warn, un mail à l'équipe. Une absence
#     restée sans observation au-delà de STALE_ABSENCE (le balayage, chaque
#     minute, l'aurait déjà interrompue) est périmée : elle est redatée.
#     Revers assumé : LiveKit injoignable 5 min ou plus pendant une vraie
#     absence la redate aussi ; l'alerte arrive alors plus tard, et
#     l'heure de début sous-estime l'intervalle perdu ;
#   • agent présent : l'absence est effacée ; une interruption se clôt
#     (journal warn, un mail « rétablie ») ;
#   • salle vide : rien n'échappe à la transcription. Une absence encore
#     sous le seuil est oubliée (le retour du public ne déclenche pas d'alerte
#     sur un délai qui ne courait plus) ; une interruption reste ouverte ;
#   • captation close (fin du direct, LiveEnding) : l'interruption se clôt.
# Écritures conditionnelles : une seule alerte par entrée et par sortie,
# même si deux vérifications se croisent.
module Webinar::TranscriptionOutage
  extend ActiveSupport::Concern

  ABSENCE_LIMIT = 3.minutes
  STALE_ABSENCE = ABSENCE_LIMIT + 2.minutes

  # @param outcome [Symbol] résultat de TranscriberPresence#ensure_present
  def transcriber_observed!(outcome, at: Time.current)
    case outcome
    when :present then end_transcription_outage!(:restored, at: at)
    when :pending, :dispatched then transcriber_missing!(at)
    when :empty_room then forget_transcriber_absence!
    when :closed then end_transcription_outage!(:capture_closed, at: at)
    end
  end

  # @param reason [Symbol] :restored (l'agent est revenu) ou :capture_closed
  def end_transcription_outage!(reason, at: Time.current)
    absent_since, interrupted_at = self.class.where(id: id)
                                             .pick(:transcriber_absent_since, :transcription_interrupted_at)
    return if absent_since.nil? && interrupted_at.nil?

    cleared = self.class.where(id: id, transcriber_absent_since: absent_since, transcription_interrupted_at: interrupted_at)
                        .update_all(transcriber_absent_since: nil, transcription_interrupted_at: nil) == 1
    return unless cleared && interrupted_at

    Rails.logger.warn("[transcription_outage] event=ended reason=#{reason} webinar=#{slug} room=#{room_name} " \
                      "absent_since=#{absent_since.iso8601} ended_at=#{at.iso8601}")
    TranscriptionOutageMailer.ended(self, absent_since: absent_since, ended_at: at, reason: reason.to_s).deliver_later
  end

  # Début de l'absence, seulement une fois la transcription interrompue.
  def transcription_interrupted_since
    transcriber_absent_since if transcription_interrupted_at
  end

  private

  # Jamais sur un direct terminé : une vérification lancée juste avant la fin
  # ne rouvre pas ce que LiveEnding vient de clore. Chaque écriture est
  # conditionnée sur la valeur lue ; le début de l'absence part figé dans le
  # mail, qui ne relit pas l'absence à l'envoi.
  def transcriber_missing!(at)
    open_absence = self.class.where(id: id, transcription_interrupted_at: nil).where.not(state: "ended")
    absent_since = open_absence.pick(:transcriber_absent_since)

    if absent_since.nil? || absent_since < at - STALE_ABSENCE
      open_absence.where(transcriber_absent_since: absent_since).update_all(transcriber_absent_since: at)
      return
    end
    return if absent_since > at - ABSENCE_LIMIT
    return unless open_absence.where(transcriber_absent_since: absent_since)
                              .update_all(transcription_interrupted_at: at) == 1

    Rails.logger.warn("[transcription_outage] event=interrupted webinar=#{slug} room=#{room_name} " \
                      "absent_since=#{absent_since.iso8601} agent_name=#{TranscriberPresence.agent_name}")
    TranscriptionOutageMailer.interrupted(self, absent_since: absent_since).deliver_later
  end

  def forget_transcriber_absence!
    self.class.where(id: id, transcription_interrupted_at: nil).where.not(transcriber_absent_since: nil)
              .update_all(transcriber_absent_since: nil)
  end
end
