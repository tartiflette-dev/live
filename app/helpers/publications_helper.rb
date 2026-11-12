module PublicationsHelper
  # Ce qui retient le dépôt automatique d'un épisode, en clair pour
  # l'animation (EpisodePublication.automatic_hold).
  def publication_hold_message(webinar, hold)
    case hold
    when nil        then "Dépôt automatique au prochain passage du balayage."
    when :not_ended then "Le dépôt se fera à la fin du direct, une fois les enregistrements et assemblages terminés."
    when :draft     then "Brouillon : pas de dépôt automatique. Le bouton le dépose."
    when :too_old   then "Direct terminé il y a plus de #{duration_words(EpisodePublication::AUTOMATIC_WINDOW)} : " \
                         "pas de dépôt automatique. Le bouton le dépose."
    when :quiet     then "Dépôt automatique #{duration_words(EpisodePublication::QUIET_PERIOD)} après la fin du direct, " \
                         "le temps d'une éventuelle reprise."
    when :empty     then "Rien à déposer : aucun enregistrement terminé, aucune transcription."
    when :recording then "En attente de la fin des enregistrements."
    when :muxing
      count = EpisodePublication.unmuxed_identities(webinar).size
      "En attente des assemblages (#{count} personne#{'s' if count > 1}). Le bouton dépose tout de suite ce qui est prêt."
    when :lightening
      count = EpisodePublication.waiting_light_versions(webinar).size
      "Versions légères des vidéos en préparation (#{count} fichier#{'s' if count > 1}), " \
        "au plus #{duration_words(LightVersion::WAIT)} : sinon les originaux partent. " \
        "Le bouton dépose tout de suite, en original ce qui n'est pas prêt."
    end
  end

  # Heures et durée d'une vidéo à valider, lues sur son enregistrement
  # (« 9:31-10:30 · 59 min ») ; nil si le nom ne désigne pas un
  # enregistrement de ce webinaire ou s'il n'a pas ses heures.
  def publication_video_timing(webinar, name)
    id = EpisodeManifest.recording_id(name)
    recording = id && webinar.recordings.find_by(id: id)
    return unless recording&.started_at && recording.ended_at

    "#{l(recording.started_at, format: :heure)}-#{l(recording.ended_at, format: :heure)} · " \
      "#{duration_words((recording.ended_at - recording.started_at).seconds)}"
  end

  private

  def duration_words(duration)
    hours, minutes = duration.in_minutes.round.divmod(60)
    return "#{hours} h" if minutes.zero?

    hours.zero? ? "#{minutes} min" : "#{hours} h #{format('%02d', minutes)}"
  end
end
