module ReplaysHelper
  # Instant d'une vidéo, comme l'affiche un lecteur : « 4:05 », « 1:02:09 ».
  def replay_timecode(seconds)
    DurationFormat.timecode(seconds)
  end

  # Passages vus : « 0:00–12:30, 40:10–52:00 ».
  def replay_intervals(intervals)
    intervals.map { |(start, finish)| "#{replay_timecode(start)}–#{replay_timecode(finish)}" }.join(", ")
  end

  # Extrait d'un résultat de recherche : texte échappé, mots trouvés dans des
  # <mark> (marqueurs de ReplaySearchIndex, jamais du HTML venu de l'index).
  def replay_search_extract(extract)
    start, finish = ReplaySearchIndex::MARK_START, ReplaySearchIndex::MARK_END
    extract.to_s.split(/(#{start}[^#{start}#{finish}]*#{finish})/o).then do |parts|
      safe_join(parts.map { |part| part.start_with?(start) ? tag.mark(part.delete(start + finish)) : part.delete(start + finish) })
    end
  end

  def replay_search_kind(kind)
    { "chapter" => "Chapitre", "theme" => "Thème" }.fetch(kind, "Transcription")
  end
end
