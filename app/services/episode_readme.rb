# frozen_string_literal: true

# EpisodeReadme — le README.md déposé à la racine du dossier d'épisode
# partagé : Nextcloud l'affiche en tête du dossier. Même plan qu'un premier
# dépôt fait à la main : de quoi il s'agit, ce que contient chaque
# famille de fichiers, puis le tableau des fichiers (durée, taille), et
# l'accord de chaque personne pour les extraits et shorts. Il ne décrit que
# le dossier partagé : les vidéos en relecture n'y sont ni nommées ni liées,
# seulement annoncées.
#
# Réécrit à chaque dépôt : les notes humaines vont ailleurs (doc
# d'épisode `<épisode>-episode.md`, skill montage-editorial).
class EpisodeReadme
  # Caractères qui font du Markdown actif dans une cellule de tableau.
  MARKDOWN_ACTIVE = /[\\`*_{}\[\]()<>#!|~&]/

  def initialize(manifest, files, in_review:)
    @manifest  = manifest
    @webinar   = manifest.webinar
    @files     = files
    @in_review = in_review
  end

  def to_s
    sections = [ "# #{@webinar.title} — #{I18n.l(@webinar.starts_at.to_date, format: :long)}", introduction,
                 "## Contenu\n#{contents.join("\n")}", "## Fichiers\n#{table}" ]
    sections << "## Extraits et shorts\n#{excerpt_consents}" if @manifest.excerpt_consents.any?
    sections << undeposited if @manifest.undeposited_count.positive?
    sections.join("\n\n") + "\n"
  end

  private

  def introduction
    lines = []
    if (duration = @manifest.live_duration)
      lines << "Direct du #{I18n.l(@webinar.started_at, format: '%A %-d %B %Y')}, " \
               "de #{clock(@webinar.started_at)} à #{clock(@webinar.ended_at)} (heure de Paris) : #{DurationFormat.short(duration)}."
    end
    lines << "Déposé par #{Brand.host} à la fin du direct. Ce fichier est réécrit à chaque dépôt : " \
             "les notes vont dans un autre fichier (par exemple `#{@manifest.episode_name}-episode.md`)."
    lines.join("\n")
  end

  def contents
    names = @files.map(&:name)
    lines = []
    if names.any? { |name| name.start_with?("video-complete-") && !name.end_with?(".srt", ".vtt") }
      lines << "- `video-complete-…` : la vidéo d'ensemble du direct, telle que la voyaient les spectateurs."
    end
    if names.any? { |name| name.end_with?(".srt") }
      lines << "- `video-complete-….srt` et `.vtt` : les sous-titres de la vidéo complète principale, calés sur elle."
    end
    if names.include?(@manifest.transcript_name)
      lines << "- `#{@manifest.transcript_name}` : la transcription automatique faite pendant le direct, " \
               "horodatée (heure de Paris) par personne. À relire avant toute citation."
    end
    if names.any? { |name| name.start_with?("assemblages/") }
      lines << "- `assemblages/` : par personne, l'image de sa caméra et le son de son micro recalés en un seul fichier, " \
               "prêt au montage : .mp4, .webm (VP8 ou VP9, ne s'ouvre pas dans Final Cut) ou .m4a (son seul) ; le nombre final distingue les fichiers."
    end
    if names.any? { |name| name.start_with?("pistes/") }
      lines << "- `pistes/` : les enregistrements bruts par personne et par source (`micro`, `camera` sauf celle qu'un assemblage reprend telle quelle, " \
               "puis `partage-ecran` et `son-ecran` une fois relus) ; " \
               "`fin-HHhMM` = heure de fin (Paris), le nombre final distingue les fichiers."
      lines << "  Caméras en .mp4 (H.264) ou .webm (VP8, ne s'ouvre pas dans Final Cut), micros en .ogg (Opus)."
    end
    lines << "- #{EpisodePublication::IN_REVIEW_NOTICE}" if @in_review
    lines
  end

  def table
    rows = @files.map do |file|
      duration = file.duration ? DurationFormat.short(file.duration) : "—"
      "| #{file.name} | #{duration} | #{ActiveSupport::NumberHelper.number_to_human_size(file.size, locale: :fr)} |"
    end
    ([ "| Fichier | Durée | Taille |", "|---|---|---|" ] + rows).join("\n")
  end

  # Ce que le montage doit savoir avant tout extrait.
  # Version lisible de `<épisode>-extraits.json`, que lisent les outils. Le
  # nom vient du participant : échappé (`markdown_cell`), il ne peut ni
  # fabriquer une ligne ni changer l'état d'un autre ; l'identité LiveKit
  # rattache chaque ligne à ses pistes.
  def excerpt_consents
    rows = @manifest.excerpt_consents.map do |consent|
      "| #{markdown_cell(consent.name)} | #{markdown_cell(consent.identity)} | #{consent.label} |"
    end
    notice = "Un extrait ou un short ne montre que des personnes aux extraits autorisés ; l'animation de droit " \
             "l'est par la politique de confidentialité, un co-animateur invité par son accord. « Accord retiré » : la personne ne doit plus apparaître dans ce qui est " \
             "publié, replay compris (procédure : `docs/depublication.md` du dépôt de l'application). Pour les outils " \
             "de montage, le même état est dans `#{@manifest.excerpt_consents_file.name}`."
    ([ notice, "", "| Personne | Identité | Extraits et shorts |", "|---|---|---|" ] + rows).join("\n")
  end

  # Texte libre dans une cellule de tableau Markdown : une seule ligne, aucun
  # séparateur de colonne ni balisage actif.
  def markdown_cell(text)
    text.to_s.gsub(/[[:cntrl:]]+/, " ").squish.gsub(MARKDOWN_ACTIVE) { |character| "\\#{character}" }
  end

  def undeposited
    count = @manifest.undeposited_count
    "#{count} enregistrement#{'s' if count > 1} non déposé#{'s' if count > 1} " \
      "(en échec, en cours ou fichier introuvable) : détail sur la page des enregistrements du webinaire."
  end

  def clock(time)
    time.in_time_zone.strftime("%H:%M")
  end
end
