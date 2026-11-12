# frozen_string_literal: true

# Index plein texte des replays, table FTS5
# `replay_search_entries` : une ligne par segment de transcription, par titre
# de chapitre VALIDÉ et par thème de ces chapitres, avec son heure réelle
# (`at`, secondes epoch). Accents et casse ignorés (tokenizer unicode61
# remove_diacritics 2).
#
# Écriture : `refresh` reconstruit les lignes d'UN webinaire, seulement s'il a
# un replay (publié ou non : la recherche filtre). Appelé après chaque
# proposition de chapitres (ChapterProposalJob, enfilé à la fin du direct et à
# la publication), après chaque relecture des chapitres, et par
# `bin/rails replays:chapitres`. `purge` retire un webinaire (rétention).
# Écritures par `connection.insert` / `connection.delete`, jamais
# `exec_insert` / `exec_delete` : ces deux-là ne vident pas le cache de
# requêtes, qu'une recherche lancée ensuite dans la même requête ou le même
# job lirait périmé.
#
# Lecture : `search` rend les passages qui contiennent TOUS les mots de la
# requête (préfixe pour les mots de 3 lettres et plus : « agent » trouve
# « agents »), parmi les replays donnés — l'appelant décide de l'accès
# (ReplayAccess). Extraits balisés par MARK_START / MARK_END, jamais par du
# HTML : le texte vient de la transcription, la vue l'échappe puis surligne.
class ReplaySearchIndex
  TABLE = "replay_search_entries"
  MARK_START = "\u0001"
  MARK_END = "\u0002"
  QUERY_LIMIT = 100
  MAX_TERMS = 8
  MAX_HITS = 200
  HITS_PER_REPLAY = 5
  EXTRACT_TOKENS = 16
  INSERT_BATCH = 200

  Hit = Data.define(:replay, :kind, :offset, :extract)
  Group = Data.define(:replay, :hits, :hits_count)
  Result = Data.define(:groups, :count)

  # Requête telle qu'on la compte dans le journal : sans casse, accents ni
  # espaces superflus, bornée.
  def self.normalize(query)
    I18n.transliterate(query.to_s.unicode_normalize(:nfc).squish).downcase.first(QUERY_LIMIT)
  end

  def self.refresh(webinar)
    connection.transaction do
      purge(webinar.id)
      insert(entries_for(webinar)) if webinar.replay
    end
  end

  def self.purge(webinar_ids)
    connection.delete(sanitize([ "DELETE FROM #{TABLE} WHERE webinar_id IN (?)", Array(webinar_ids) ]))
  end

  # @param replays [Array<Replay>] ceux que la personne peut regarder
  # @return [Result, nil] nil si la requête ne contient aucun mot
  def self.search(query, replays)
    expression = match_expression(query)
    return nil if expression.nil?

    by_webinar = replays.index_by(&:webinar_id)
    rows = by_webinar.empty? ? [] : connection.select_rows(sanitize([ <<~SQL, expression, by_webinar.keys, MAX_HITS ]))
      SELECT webinar_id, kind, at,
             snippet(#{TABLE}, 0, char(1), char(2), '…', #{EXTRACT_TOKENS})
      FROM #{TABLE}
      WHERE #{TABLE} MATCH ? AND webinar_id IN (?)
      ORDER BY bm25(#{TABLE})
      LIMIT ?
    SQL
    # Un titre de chapitre et le segment qui l'ouvre partagent le même
    # instant : seul le mieux classé est gardé.
    hits = rows.uniq { |webinar_id, _, at, _| [ webinar_id, at ] }.map do |webinar_id, kind, at, extract|
      replay = by_webinar.fetch(webinar_id.to_i)
      Hit.new(replay: replay, kind: kind, offset: replay.offset_of(Time.zone.at(at.to_f)), extract: extract)
    end
    Result.new(groups: group(hits), count: hits.size)
  end

  # Mots de la requête, chacun entre guillemets (aucune syntaxe FTS5 ne passe),
  # tous exigés. Forme composée (NFC) d'abord : une saisie décomposée
  # (« e » + accent) serait coupée à l'accent.
  def self.match_expression(query)
    terms = query.to_s.unicode_normalize(:nfc).first(QUERY_LIMIT).scan(/[\p{L}\p{N}]+/).first(MAX_TERMS)
    return nil if terms.empty?

    terms.map { |term| term.length >= 3 ? %("#{term}"*) : %("#{term}") }.join(" ")
  end

  # Groupes par replay, le plus pertinent d'abord ; dans un groupe, chapitres
  # et thèmes puis transcription, dans l'ordre de la vidéo.
  def self.group(hits)
    hits.group_by(&:replay).map do |replay, list|
      shown = list.first(HITS_PER_REPLAY).sort_by { |hit| [ hit.kind == "transcript" ? 1 : 0, hit.offset ] }
      Group.new(replay: replay, hits: shown, hits_count: list.size)
    end
  end

  def self.entries_for(webinar)
    entries = webinar.transcript_segments.pluck(:text, :started_at).map { |text, at| [ text, "transcript", at ] }
    if webinar.chapter_set&.validated?
      webinar.chapter_set.chapters.each do |chapter|
        entries << [ chapter.title, "chapter", chapter.starts_at ]
        chapter.themes.each { |theme| entries << [ theme, "theme", chapter.starts_at ] }
      end
    end
    entries.map { |body, kind, at| [ body, webinar.id, kind, at.to_f ] }
  end

  def self.insert(entries)
    entries.each_slice(INSERT_BATCH) do |batch|
      placeholders = Array.new(batch.size, "(?, ?, ?, ?)").join(", ")
      connection.insert(sanitize([ "INSERT INTO #{TABLE} (body, webinar_id, kind, at) VALUES #{placeholders}", *batch.flatten ]))
    end
  end

  def self.sanitize(array)
    ActiveRecord::Base.sanitize_sql_array(array)
  end

  def self.connection
    ActiveRecord::Base.connection
  end

  private_class_method :match_expression, :group, :entries_for, :insert, :sanitize, :connection
end
