# Alertes à l'équipe (adresse de contact de la marque) quand la transcription
# d'un direct s'interrompt, puis quand l'interruption prend fin
# (Webinar::TranscriptionOutage) : un mail à l'entrée, un à la sortie. La
# régie affiche le même état à l'animation. Les heures arrivent figées par
# l'appelant : l'interruption a pu se clore avant l'envoi différé.
class TranscriptionOutageMailer < ApplicationMailer
  def interrupted(webinar, absent_since:)
    @webinar = webinar
    @since = clock(absent_since)
    @agent_name = TranscriberPresence.agent_name
    @regie_url = webinar_regie_url(webinar)

    mail(to: Brand.support_email, subject: "#{webinar.title} — transcription en direct interrompue depuis environ #{@since}")
  end

  # @param reason [String] "restored" (transcripteur revenu) ou "capture_closed" (captation arrêtée, fin du direct)
  def ended(webinar, absent_since:, ended_at:, reason:)
    @webinar = webinar
    @since = clock(absent_since)
    @until = clock(ended_at)
    @restored = reason == "restored"
    @regie_url = webinar_regie_url(webinar)
    subject = @restored ? "transcription en direct rétablie à #{@until}" : "captation arrêtée sans transcription depuis environ #{@since}"

    mail(to: Brand.support_email, subject: "#{webinar.title} — #{subject}")
  end

  private

  def clock(time)
    time.in_time_zone("Europe/Paris").strftime("%-H:%M")
  end
end
