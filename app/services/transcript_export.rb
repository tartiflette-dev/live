# frozen_string_literal: true

# TranscriptExport — la transcription d'un direct en fichiers lisibles hors
# de l'application (publication Nextcloud) :
#   • `markdown` : une ligne par segment, `[HH:MM:SS] **Nom** : texte`,
#     heure de Paris (comme l'export .txt de la page des enregistrements) ;
#   • `srt` / `vtt` : sous-titres calés sur une vidéo dont l'enregistrement
#     a démarré à `origin` et fini à `finish`. Un segment hors de cette
#     fenêtre est écarté, un segment à cheval est rogné à son bord.
#
# Calage : `origin` = Recording#started_at du composite, à moins d'une
# seconde du début réel du fichier (mesuré sur un direct : 0,55 s
# d'écart avec le manifeste de l'egress).
class TranscriptExport
  # Un segment de durée nulle ou négative (horloges du transcripteur)
  # reste affiché ce temps-là.
  MIN_CUE_SECONDS = 1.0

  Cue = Data.define(:index, :from, :to, :speaker, :text)

  def initialize(segments)
    @segments = segments.to_a
  end

  def markdown(title:)
    lines = @segments.map do |segment|
      clock = segment.started_at.in_time_zone.strftime("%H:%M:%S")
      "- [#{clock}] **#{escape_markdown(speaker_of(segment))}** : #{escape_markdown(segment.text.squish)}"
    end
    <<~MARKDOWN
      # #{escape_markdown(title)} — transcription

      Transcription automatique faite pendant le direct (reconnaissance vocale), heure de Paris. À relire avant toute citation.

      #{lines.join("\n")}
    MARKDOWN
  end

  def srt(origin:, finish:)
    cues(origin, finish).map do |cue|
      "#{cue.index}\n#{timestamp(cue.from, ',')} --> #{timestamp(cue.to, ',')}\n#{cue.speaker} : #{cue.text}\n"
    end.join("\n")
  end

  def vtt(origin:, finish:)
    body = cues(origin, finish).map do |cue|
      "#{timestamp(cue.from, '.')} --> #{timestamp(cue.to, '.')}\n<v #{escape_vtt(cue.speaker)}>#{escape_vtt(cue.text)}\n"
    end
    ([ "WEBVTT\n" ] + body).join("\n")
  end

  private

  def cues(origin, finish)
    window = finish - origin
    kept = @segments.select { |segment| segment.ended_at > origin && segment.started_at < finish }
    kept.each_with_index.map do |segment, position|
      from = (segment.started_at - origin).clamp(0.0, window)
      to   = [ segment.ended_at - origin, from + MIN_CUE_SECONDS ].max.clamp(from, window)
      Cue.new(index: position + 1, from: from, to: to, speaker: speaker_of(segment), text: segment.text.squish)
    end
  end

  def speaker_of(segment)
    segment.speaker_name.presence || segment.participant_identity.presence || "Participant"
  end

  def timestamp(seconds, separator)
    millis = (seconds * 1000).round
    hours, millis = millis.divmod(3_600_000)
    minutes, millis = millis.divmod(60_000)
    secs, millis = millis.divmod(1000)
    format("%02d:%02d:%02d%s%03d", hours, minutes, secs, separator, millis)
  end

  def escape_markdown(text)
    text.to_s.gsub(/([\\`*_\[\]<>|])/) { "\\#{Regexp.last_match(1)}" }
  end

  def escape_vtt(text)
    text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end
end
