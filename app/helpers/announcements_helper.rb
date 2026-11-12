# Libellés des cibles d'un envoi groupé (écran d'envoi, journal).
module AnnouncementsHelper
  AUDIENCE_LABELS = {
    "webinar_registrants" => "Inscrits confirmés de ce webinaire",
    "marketing_list"      => "La liste : personnes d'accord pour être recontactées",
    "notify_next"         => "Demandes « préviens-moi du prochain Café IA »"
  }.freeze

  AUDIENCE_HINTS = {
    "webinar_registrants" => "Message de service (indications du jour, changement pratique), sans lien de retrait. " \
                             "Chaque mail rappelle le lien d'accès personnel au webinaire. Co-animateur : le jour " \
                             "du café, 3 envois au plus, le propriétaire en est avisé et reçoit les réponses.",
    "marketing_list"      => "Chaque mail porte un lien de retrait. Une personne qui se retire n'est plus servie, " \
                             "même pendant l'envoi. Un envoi aux listes par 24 h ; les animateurs du projet en sont avisés.",
    "notify_next"         => "Personnes qui ont demandé à être prévenues du prochain café. Chaque mail porte un " \
                             "lien pour ne plus l'être ; qui a retiré son accord au recontact n'est pas servi. " \
                             "Un envoi aux listes par 24 h ; les animateurs du projet en sont avisés."
  }.freeze

  def announcement_audience_label(audience)
    AUDIENCE_LABELS.fetch(audience)
  end

  def announcement_audience_hint(audience)
    AUDIENCE_HINTS.fetch(audience)
  end

  AUTHOR_ROLE_LABELS = {
    "owner"        => "propriétaire",
    "project_host" => "animateur du projet",
    "guest_host"   => "co-animateur"
  }.freeze

  # Auteur d'un envoi au journal : son adresse, sauf pour un co-animateur qui
  # regarde l'envoi d'un autre (il n'a pas accès aux adresses de l'équipe).
  def announcement_author_label(announcement, permission)
    return announcement.author_email unless permission.guest? && announcement.author_sub != current_user.oidc_sub

    AUTHOR_ROLE_LABELS.fetch(announcement.author_role)
  end

  def recipients_label(count)
    "#{count} destinataire#{'s' if count > 1}"
  end
end
