# Statut de présence des animateurs (Webinar::HostPresence), partout où une
# date à venir s'affiche : catalogue, agenda, page publique, page animateur,
# régie. Rien pour un direct en cours ni pour une date passée.
module HostPresenceHelper
  DATE_STATUS_CLASSES = { "confirmed" => "etat--succes", "to_confirm" => "etat--a-verifier" }.freeze

  def date_status_badge(webinar)
    return unless webinar.draft? && !webinar.past?

    status = webinar.date_status
    tag.span t("host_presence.date_status.#{status}"), class: "etat #{DATE_STATUS_CLASSES.fetch(status)}",
                                                       data: { role: "date-status", date_status: status }
  end

  def host_presence_answer_label(answer)
    t("host_presence.answers.#{answer || 'none'}")
  end
end
