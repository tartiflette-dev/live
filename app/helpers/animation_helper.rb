module AnimationHelper
  # Fiche CRM d'un contact, lien seulement : nil sans
  # identifiant numérique ou sans CRM_BASE_URL.
  def crm_contact_url(contact_id)
    base = ENV["CRM_BASE_URL"].presence
    return nil unless base && contact_id.to_s.match?(/\A\d+\z/)

    "#{base.chomp("/")}/contacts/#{contact_id}"
  end

  # Réponse à un sondage, lisible : options cochées (choix), note (échelle)
  # ou texte (réponse courte).
  def poll_answer_text(poll, value)
    case value
    when Array then value.filter_map { |index| Array(poll.options)[index] if index.is_a?(Integer) }.join(", ")
    else value.to_s
    end
  end

  # Lien vers un chapitre : le replay à son instant s'il existe, sinon la
  # relecture des chapitres.
  def theme_entry_path(entry)
    replay = entry.webinar.replay
    return webinar_chapters_path(entry.webinar) unless replay

    public_webinar_replay_path(entry.webinar.slug, instant: replay.offset_of(entry.chapter.starts_at).floor)
  end
end
