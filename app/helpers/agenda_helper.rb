module AgendaHelper
  # Point de construction unique (vues et AgendaController via `helpers`) :
  # les URL de pages publiques suivent l'hôte de la requête.
  def webinar_calendar
    WebinarCalendar.new(page_url: ->(webinar) { public_webinar_url(slug: webinar.slug) })
  end

  # Programme d'une date de l'agenda en une ligne : « Sujet · avec A et B ·
  # animé par C ». nil sans programme.
  def agenda_program_line(webinar)
    parts = []
    parts << webinar.topic if webinar.topic
    parts << "avec #{webinar.announced_speakers.to_sentence(locale: :fr)}" if webinar.announced_speakers.any?
    parts << "animé par #{webinar.lead_host_name}" if webinar.lead_host_name
    parts.join(" · ").upcase_first.presence
  end
end
