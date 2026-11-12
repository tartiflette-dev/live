# Libellés de la page « Présence » (PresenceTimeline, PresenceChart).
module PresenceHelper
  ROLE_LABELS = { animation: "Animation", intervenant: "Intervenant", inscrit: "Inscrit" }.freeze
  ANONYMOUS_LABELS = {
    animation: "Animation (compte inconnu)",
    intervenant: "Intervenant sans nom (effacé)",
    inscrit: "Spectateur anonyme (inscription effacée)"
  }.freeze
  ATTEMPT_LABELS = {
    "page_opened" => "page ouverte",
    "token_issued" => "accès à la salle délivré",
    "aborted" => "connexion interrompue",
    "refused" => "refusé par la salle"
  }.freeze
  SOURCE_LABELS = {
    "livekit" => "webhooks LiveKit reçus en direct",
    "livekit_log" => "journal du serveur LiveKit, rejoué après coup",
    "app" => "pages ouvertes et accès délivrés vus par l'application",
    "registration" => "première arrivée notée sur l'inscription, sans le départ"
  }.freeze

  # 9:30, heure de Paris.
  def presence_clock(time)
    time.in_time_zone.strftime("%-H:%M")
  end

  def presence_duration(seconds)
    minutes = (seconds / 60.0).round
    return "moins d'une minute" if minutes < 1
    return "#{minutes} min" if minutes < 60

    format("%d h %02d", minutes / 60, minutes % 60)
  end

  def presence_name(person)
    person.name || ANONYMOUS_LABELS.fetch(person.role)
  end

  def presence_role(person)
    return "Intervenant (inscrit)" if person.role == :intervenant && person.registration

    ROLE_LABELS.fetch(person.role)
  end

  # Présences complètes et partielles, dans l'ordre du temps.
  def presence_intervals(attendee)
    known = attendee.intervals.each_with_index.map do |(from, to), index|
      last = index == attendee.intervals.size - 1
      [ from, "#{presence_clock(from)} → #{last && attendee.ongoing ? 'maintenant' : presence_clock(to)}" ]
    end
    partial = attendee.partial.map do |from, to|
      from ? [ from, "#{presence_clock(from)} → départ non relevé" ] : [ to, "arrivée non relevée → #{presence_clock(to)}" ]
    end
    (known + partial).sort_by(&:first).map(&:last)
  end

  def presence_attendee_duration(attendee)
    return "inconnue" if attendee.intervals.empty?

    attendee.partial.any? ? "au moins #{presence_duration(attendee.duration)}" : presence_duration(attendee.duration)
  end

  # « page ouverte à 9:28, connexion interrompue ×2 (9:36, 9:40) »
  def presence_attempts(attendee)
    attendee.attempts.group_by(&:kind).map do |kind, events|
      times = events.map { |event| presence_clock(event.occurred_at) }.uniq
      label = ATTEMPT_LABELS.fetch(kind)
      events.size == 1 ? "#{label} à #{times.first}" : "#{label} ×#{events.size} (#{times.join(', ')})"
    end
  end

  def presence_plural(count, word)
    "#{count} #{word}#{'s' if count > 1}"
  end
end
