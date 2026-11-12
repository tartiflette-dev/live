# frozen_string_literal: true

require "test_helper"

# TranscriptExport — fichiers lisibles hors de l'application : Markdown
# horodaté (heure de Paris) par locuteur, SRT et WebVTT calés sur le début
# d'une vidéo. Valeurs attendues écrites à la main.
class TranscriptExportTest < ActiveSupport::TestCase
  Segment = Struct.new(:participant_identity, :speaker_name, :text, :started_at, :ended_at, keyword_init: true)

  ORIGIN = Time.utc(2026, 10, 30, 8, 31, 6) # composite démarré à 09:31:06 Paris

  def segment(text, from:, to:, name: "Basile Delmas", identity: "speaker-9")
    Segment.new(participant_identity: identity, speaker_name: name, text: text,
                started_at: ORIGIN + from, ended_at: ORIGIN + to)
  end

  test "markdown : une ligne par segment, heure de Paris, nom en gras, balisage neutralisé" do
    export = TranscriptExport.new([
      segment("Bonjour  à   tous.", from: 30.5, to: 33),
      segment("Le *vrai* sujet : <IA> | outils_libres", from: 3605, to: 3608, name: nil, identity: "host-abc")
    ])

    markdown = export.markdown(title: "Café IA #7")

    assert_includes markdown, "# Café IA #7 — transcription\n"
    assert_includes markdown, "- [09:31:36] **Basile Delmas** : Bonjour à tous.\n"
    assert_includes markdown, "- [10:31:11] **host-abc** : Le \\*vrai\\* sujet : \\<IA\\> \\| outils\\_libres\n"
  end

  test "srt : décalé sur l'origine, millisecondes, nom du locuteur dans le texte" do
    srt = TranscriptExport.new([
      segment("Bonjour.", from: 30.5, to: 33.25),
      segment("Deuxième phrase.", from: 3725.001, to: 3727, name: "Tristan Lemaire")
    ]).srt(origin: ORIGIN, finish: ORIGIN + 3800)

    assert_equal <<~SRT, srt
      1
      00:00:30,500 --> 00:00:33,250
      Basile Delmas : Bonjour.

      2
      01:02:05,001 --> 01:02:07,000
      Tristan Lemaire : Deuxième phrase.
    SRT
  end

  test "srt : hors de la vidéo écarté, à cheval rogné au bord, durée nulle allongée" do
    srt = TranscriptExport.new([
      segment("Avant la vidéo.", from: -20, to: -5),
      segment("À cheval sur le début.", from: -2, to: 4),
      segment("Instantané.", from: 10, to: 10),
      segment("À cheval sur la fin.", from: 98, to: 104),
      segment("Après la vidéo.", from: 120, to: 125)
    ]).srt(origin: ORIGIN, finish: ORIGIN + 100)

    assert_equal [ "00:00:00,000 --> 00:00:04,000", "00:00:10,000 --> 00:00:11,000", "00:01:38,000 --> 00:01:40,000" ],
                 srt.scan(/^\d\d:.*$/)
    assert_no_match(/Avant la vidéo|Après la vidéo/, srt)
    assert_match(/\A1\n/, srt)
  end

  test "vtt : en-tête WEBVTT, point décimal, voix <v> et texte échappés" do
    vtt = TranscriptExport.new([ segment("R&D <ok>", from: 1, to: 2, name: "A <b>") ])
                          .vtt(origin: ORIGIN, finish: ORIGIN + 10)

    assert_equal "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v A &lt;b&gt;>R&amp;D &lt;ok&gt;\n", vtt
  end
end
