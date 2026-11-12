# frozen_string_literal: true

# Durée en français court : « 38 s », « 12 min 05 s », « 1 h 03 min ».
# Partagée par la page des enregistrements et la publication des épisodes
# (README déposé, mail aux intervenants). `timecode` : un instant de vidéo,
# comme l'affiche un lecteur (replays, relecture des chapitres).
module DurationFormat
  def self.short(seconds)
    total = seconds.round
    hours, rest = total.divmod(3600)
    minutes, secs = rest.divmod(60)
    return format("%d h %02d min", hours, minutes) if hours.positive?
    return format("%d min %02d s", minutes, secs) if minutes.positive?

    "#{secs} s"
  end

  # « 4:05 », « 1:02:09 » ; jamais négatif.
  def self.timecode(seconds)
    total = seconds.to_f.floor.clamp(0, nil)
    hours, rest = total.divmod(3600)
    minutes, secs = rest.divmod(60)
    hours.positive? ? format("%d:%02d:%02d", hours, minutes, secs) : format("%d:%02d", minutes, secs)
  end
end
