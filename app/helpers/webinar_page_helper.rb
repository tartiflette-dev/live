# Page animateur d'un webinaire (webinars#show), rangée par moment : avant,
# pendant et après le direct. Le moment décide
# du bouton principal et de la place des sections, jamais de leur présence.
module WebinarPageHelper
  MOMENTS = { "draft" => :before, "live" => :during, "ended" => :after }.freeze

  STATE_BADGES = {
    draft: [ "Brouillon", "etat--neutre" ],
    scheduled: [ "Programmé", "etat--info" ],
    live: [ "En direct", "etat--en-cours" ],
    ended: [ "Terminé", "etat--neutre" ]
  }.freeze

  def webinar_moment(webinar)
    MOMENTS.fetch(webinar.state)
  end

  # État en français. Avant le direct, « Brouillon » tant que le café n'est
  # pas publié au catalogue, « Programmé » ensuite.
  def webinar_state_badge(webinar)
    key = if webinar.draft?
      webinar.visibility_published? ? :scheduled : :draft
    else
      webinar.state.to_sym
    end
    label, modifier = STATE_BADGES.fetch(key)
    tag.span label, class: "etat #{modifier}", data: { role: "webinar-state", state: key }
  end

  # Bouton principal : avant, copier le lien public ; pendant, la régie ;
  # après, valider les vidéos en relecture, à défaut les enregistrements.
  # nil : aucun bouton n'est mis en avant (co-animateur après le direct).
  def webinar_primary_action(webinar, user, videos_to_review:)
    case webinar_moment(webinar)
    when :before then :copy_public_link
    when :during then :regie
    when :after
      if webinar.can_manage_recordings?(user)
        videos_to_review ? :review_videos : :recordings
      end
    end
  end

  def webinar_action_class(primary, action)
    primary == action ? "btn" : "btn btn--secondary"
  end
end
