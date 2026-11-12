# frozen_string_literal: true

require "test_helper"

# EpisodeManifest + EpisodeReadme — dossier d'épisode et noms des fichiers
# déposés, sur le modèle d'un premier dépôt fait à la main.
class EpisodeManifestTest < ActiveSupport::TestCase
  include EpisodePublicationHelpers

  test "dossier <date>-<slug>, numéro d'épisode sur 3 chiffres (convention Cafe-IA), même nom en relecture" do
    assert_equal "Cafe-IA/2030-01-17-cafe-ia-007", manifest(ended_cafe(slug: "cafe-ia-7")).folder
    assert_equal "Cafe-IA/2030-01-17-cafe-ia-012", manifest(ended_cafe(slug: "cafe-ia-12")).folder
    assert_equal "Cafe-IA/2030-01-17-test-29-10", manifest(ended_cafe(slug: "test-29-10")).folder
    assert_equal "Relecture/Cafe-IA/2030-01-17-cafe-ia-013", manifest(ended_cafe(slug: "cafe-ia-13")).review_folder
  end

  test "noms lisibles par personne et par source, heure de fin à Paris, id en suffixe" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      speaker = webinar.speakers.create!(name: "Basile Delmas")
      identity = "speaker-#{speaker.id}"
      composite = add_recording(webinar, kind: "composite", file: "20261030-083106-6c6e27eeb812.mp4")
      camera = add_recording(webinar, kind: "track", identity: identity, source: "camera", file: "#{identity}-camera-87d0.mp4")
      screen = add_recording(webinar, kind: "track", identity: "host-publication-host", source: "screen_share",
                                      file: "host-screen-share-94b3.mp4", ended: Time.zone.parse("2030-01-17 10:13:46"))
      mux = add_recording(webinar, kind: "participant", identity: identity, source: "camera+microphone",
                                   file: "mux-#{identity}.mp4", ended: Time.zone.parse("2030-01-17 10:29:35"))

      assert_equal [ "video-complete-fin-10h27-#{composite.id}.mp4",
                     "assemblages/basile-delmas-#{mux.id}.mp4",
                     "pistes/basile-delmas-camera-fin-10h27-#{camera.id}.mp4",
                     "pistes/marc-partage-ecran-fin-10h13-#{screen.id}.mp4" ], manifest(webinar).files.map(&:name)
      assert_equal %w[assemblages pistes], manifest(webinar).subfolders.sort
    end
  end

  # La page du webinaire retrouve l'enregistrement d'une vidéo à valider
  # par son nom (heures et durée).
  test "recording_id relit l'id de l'enregistrement dans le nom de chaque fichier média" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      speaker = webinar.speakers.create!(name: "Basile Delmas")
      identity = "speaker-#{speaker.id}"
      add_recording(webinar, kind: "composite", file: "composite.mp4")
      add_recording(webinar, kind: "track", identity: identity, source: "microphone", file: "#{identity}-micro.ogg")
      add_recording(webinar, kind: "participant", identity: identity, source: "camera+microphone", file: "mux.mp4")

      media = manifest(webinar).files.grep(EpisodeManifest::MediaFile)
      assert_equal 3, media.size
      media.each { |file| assert_equal file.recording.id, EpisodeManifest.recording_id(file.name), file.name }
      assert_nil EpisodeManifest.recording_id("2030-01-17-cafe-ia-007-transcript.md")
      assert_nil EpisodeManifest.recording_id("README.md")
    end
  end

  test "caméra assemblée dans un assemblage déposé : pas déposée en double ; micro gardé, caméra sans assemblage gardée" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-9")
      speaker = webinar.speakers.create!(name: "Basile Delmas")
      identity = "speaker-#{speaker.id}"
      camera = add_recording(webinar, kind: "track", identity: identity, source: "camera", file: "#{identity}-camera-1.mp4")
      micro = add_recording(webinar, kind: "track", identity: identity, source: "microphone", file: "#{identity}-micro-1.ogg")
      reprise = add_recording(webinar, kind: "track", identity: identity, source: "camera", file: "#{identity}-camera-2.mp4")
      mux = add_recording(webinar, kind: "participant", identity: identity, source: "camera+microphone", file: "mux-#{identity}.mp4")
      mux.update!(source_track_ids: [ camera.id, micro.id ])
      failed = add_recording(webinar, kind: "participant", identity: identity, source: "camera+microphone",
                                      file: "mux-#{identity}-echec.mp4", status: "failed")
      failed.update!(source_track_ids: [ reprise.id ])

      names = manifest(webinar).files.map(&:name)
      assert_includes names, "assemblages/basile-delmas-#{mux.id}.mp4"
      assert(names.none? { |name| name.end_with?("-#{camera.id}.mp4") }, names.inspect)
      assert(names.any? { |name| name.start_with?("pistes/basile-delmas-micro-") && name.end_with?("-#{micro.id}.ogg") }, names.inspect)
      assert(names.any? { |name| name.start_with?("pistes/basile-delmas-camera-") && name.end_with?("-#{reprise.id}.mp4") }, names.inspect)
    end
  end

  test "lot à plusieurs caméras : ParticipantMux n'en monte qu'une, sans dire laquelle, toutes restent déposées" do
    with_recordings_root do
      webinar = ended_cafe(slug: "test-29-10")
      identity = "speaker-7"
      cameras = 3.times.map { |index| add_recording(webinar, kind: "track", identity: identity, source: "camera", file: "camera-#{index}.mp4") }
      micro = add_recording(webinar, kind: "track", identity: identity, source: "microphone", file: "micro.ogg")
      mux = add_recording(webinar, kind: "participant", identity: identity, source: "camera+microphone", file: "mux.mp4")
      mux.update!(source_track_ids: cameras.map(&:id) + [ micro.id ])

      names = manifest(webinar).files.map(&:name)
      cameras.each { |camera| assert(names.any? { |name| name.end_with?("-#{camera.id}.mp4") }, names.inspect) }
    end
  end

  test "assemblage sans image (son seul) : la caméra de son lot reste déposée" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-9")
      identity = "speaker-3"
      camera = add_recording(webinar, kind: "track", identity: identity, source: "camera", file: "camera.webm")
      micro = add_recording(webinar, kind: "track", identity: identity, source: "microphone", file: "micro.ogg")
      mux = add_recording(webinar, kind: "participant", identity: identity, source: "microphone", file: "mux.m4a")
      mux.update!(source_track_ids: [ camera.id, micro.id ])

      assert(manifest(webinar).files.map(&:name).any? { |name| name.end_with?("-#{camera.id}.webm") })
    end
  end

  test "README : une caméra écartée parce que son assemblage la contient n'est pas comptée « non déposée »" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-9")
      identity = "speaker-4"
      camera = add_recording(webinar, kind: "track", identity: identity, source: "camera", file: "camera.mp4")
      micro = add_recording(webinar, kind: "track", identity: identity, source: "microphone", file: "micro.ogg")
      mux = add_recording(webinar, kind: "participant", identity: identity, source: "camera+microphone", file: "mux.mp4")
      mux.update!(source_track_ids: [ camera.id, micro.id ])

      episode = manifest(webinar)
      assert_equal 0, episode.undeposited_count
      assert_not_includes episode.readme(episode.files, in_review: false).content, "non déposé"
    end
  end

  # La piste d'une identité provisoire (accès
  # immédiat, jamais confirmée) reste sur son identité, marquée non vérifiée.
  test "piste d'un spectateur : son nom, « non vérifié » s'il n'a jamais confirmé son adresse" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-8")
      confirmed = webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: 1.day.ago)
      provisional = webinar.registrations.create!(name: "Paul", email: "paul@example.test", instant_access_at: 1.day.ago)
      ines = add_recording(webinar, kind: "track", identity: "viewer-#{confirmed.id}", source: "camera", file: "viewer-ines.mp4")
      paul = add_recording(webinar, kind: "track", identity: "viewer-#{provisional.id}", source: "camera", file: "viewer-paul.mp4")

      names = manifest(webinar).files.map(&:name)
      assert(names.any? { |name| name.start_with?("pistes/ines-camera-") && name.end_with?("-#{ines.id}.mp4") }, names.inspect)
      assert(names.any? { |name| name.start_with?("pistes/paul-non-verifie-camera-") && name.end_with?("-#{paul.id}.mp4") }, names.inspect)
    end
  end

  test "à relire avant partage : composite et toute piste autre que caméra ou micro ; assemblages et textes partagés" do
    with_recordings_root do
      webinar = ended_cafe
      add_segment(webinar, "Bonjour.", at: Time.zone.parse("2030-01-17 09:31:36"))
      add_recording(webinar, kind: "composite", file: "seance.mp4")
      add_recording(webinar, kind: "participant", identity: "speaker-1", source: "camera+microphone", file: "mux.mp4")
      [ "camera", "microphone", "screen_share", "screen_share_audio", "inconnue", nil ].each_with_index do |source, index|
        add_recording(webinar, kind: "track", identity: "speaker-1", source: source, file: "piste-#{index}.mp4")
      end

      review = manifest(webinar).files.to_h { |file| [ file.name.sub(/-fin-\d\dh\d\d-\d+/, "").sub(/-\d+\./, "."), file.review? ] }
      assert_equal({ "video-complete.mp4" => true, "assemblages/basile-delmas.mp4" => false,
                     "pistes/basile-delmas-camera.mp4" => false, "pistes/basile-delmas-micro.mp4" => false,
                     "pistes/basile-delmas-partage-ecran.mp4" => true, "pistes/basile-delmas-son-ecran.mp4" => true,
                     "pistes/basile-delmas-inconnue.mp4" => true, "pistes/basile-delmas-piste.mp4" => true,
                     "2030-01-17-cafe-ia-001-transcript.md" => false, "video-complete.srt" => false,
                     "video-complete.vtt" => false }, review)
    end
  end

  test "seuls les enregistrements terminés avec fichier sont déposés ; le README compte les autres" do
    with_recordings_root do
      webinar = ended_cafe
      kept = add_recording(webinar, kind: "track", identity: "speaker-1", source: "microphone", file: "micro.ogg")
      add_recording(webinar, kind: "track", identity: "speaker-1", source: "camera", file: "vide.mp4", status: "failed")
      add_recording(webinar, kind: "track", identity: "speaker-1", source: "camera", file: "perdu.mp4", bytes: nil)

      files = manifest(webinar).files
      assert_equal [ "pistes/speaker-1-micro-fin-10h27-#{kept.id}.ogg" ], files.map(&:name)
      assert_includes manifest(webinar).readme(files, in_review: false).content,
                      "2 enregistrements non déposés (en échec, en cours ou fichier introuvable)"
    end
  end

  test "transcription : Markdown, et sous-titres nommés comme le composite le plus long" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      add_recording(webinar, kind: "composite", file: "repetition.mp4",
                             started: Time.zone.parse("2030-01-17 09:01:31"), ended: Time.zone.parse("2030-01-17 09:09:48"))
      main = add_recording(webinar, kind: "composite", file: "seance.mp4")
      add_segment(webinar, "Bonjour.", at: Time.zone.parse("2030-01-17 09:31:36"))

      files = manifest(webinar).files.index_by(&:name)
      stem = "video-complete-fin-10h27-#{main.id}"
      assert_includes files.fetch("2030-01-17-cafe-ia-007-transcript.md").content, "- [09:31:36] **Basile Delmas** : Bonjour."
      assert_includes files.fetch("#{stem}.srt").content, "00:00:30,000 --> 00:00:33,000\nBasile Delmas : Bonjour."
      assert files.fetch("#{stem}.vtt").content.start_with?("WEBVTT")
    end
  end

  test "README : durée du direct, contenu présent seulement, tableau des fichiers" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      composite = add_recording(webinar, kind: "composite", file: "seance.mp4", bytes: "x" * 2048)

      readme = manifest(webinar).readme(manifest(webinar).files, in_review: false).content
      assert readme.start_with?("# Café IA #7 — 17 janvier 2030\n")
      assert_includes readme, "Direct du jeudi 17 janvier 2030, de 09:40 à 10:28 (heure de Paris) : 47 min 43 s."
      assert_includes readme, "`video-complete-…` : la vidéo d'ensemble du direct"
      assert_no_match(/pistes|assemblages|transcription|relecture/, readme)
      assert_includes readme, "| Fichier | Durée | Taille |\n|---|---|---|\n| video-complete-fin-10h27-#{composite.id}.mp4 | 56 min 38 s | 2 ko |\n"
    end
  end

  test "README pendant la relecture : seuls les fichiers partagés, les vidéos à relire annoncées sans nom" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      add_recording(webinar, kind: "composite", file: "seance.mp4")
      add_recording(webinar, kind: "track", identity: "host-x", source: "screen_share", file: "ecran.mp4")
      add_segment(webinar, "Bonjour.", at: Time.zone.parse("2030-01-17 09:31:36"))
      shared = manifest(webinar).files.reject(&:review?)

      readme = manifest(webinar).readme(shared, in_review: true).content

      assert_includes readme, "- `video-complete-….srt` et `.vtt` : les sous-titres de la vidéo complète principale"
      assert_includes readme, "- #{EpisodePublication::IN_REVIEW_NOTICE}"
      assert_no_match(/la vidéo d'ensemble|partage-ecran-fin|\.mp4/, readme)
    end
  end

  test "accord pour les extraits de chaque personne de l'épisode, repris dans le README" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      allowed = webinar.speakers.create!(name: "Basile Delmas")
      refused = webinar.speakers.create!(name: "Mathilde Courtois")
      withdrawn = webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)
      silent = webinar.speakers.create!(name: "Lorenzo Navarre")
      ParticipantConsent.grant!(allowed, recording: true, excerpts: true, adult: true)
      ParticipantConsent.grant!(refused, recording: true, excerpts: false, adult: true)
      ParticipantConsent.grant!(withdrawn, recording: true, excerpts: true, adult: true).withdraw!
      lorenzo = add_recording(webinar, kind: "track", identity: "speaker-#{silent.id}", source: "camera", file: "lorenzo.mp4")
      add_recording(webinar, kind: "track", identity: "host-publication-host", source: "camera", file: "marc.mp4")

      consents = manifest(webinar).excerpt_consents
      assert_equal({ "marc" => :animation, "Basile Delmas" => :allowed, "Mathilde Courtois" => :refused,
                     "Lorenzo Navarre" => :missing, "Inès" => :withdrawn },
                   consents.to_h { |consent| [ consent.name, consent.status ] })

      readme = manifest(webinar).readme(manifest(webinar).files, in_review: false).content
      assert_includes readme, "## Extraits et shorts\nUn extrait ou un short ne montre que des personnes aux extraits autorisés"
      assert_includes readme, "| Basile Delmas | speaker-#{allowed.id} | extraits autorisés |\n"
      assert_includes readme, "| Mathilde Courtois | speaker-#{refused.id} | extraits non autorisés |\n"
      assert_includes readme, "| Lorenzo Navarre | speaker-#{silent.id} | aucun accord : extraits non autorisés |\n"
      assert_includes readme, "| Inès | viewer-#{withdrawn.id} | accord retiré |"

      json = manifest(webinar).excerpt_consents_file
      assert_equal "2030-01-17-cafe-ia-007-extraits.json", json.name
      people = JSON.parse(json.content).fetch("people").index_by { |person| person["name"] }
      mathilde = people.fetch("Mathilde Courtois")
      assert_equal [ "speaker-#{refused.id}", "refused", "extraits non autorisés", [] ],
                   mathilde.values_at("identity", "excerpts", "label", "files")
      assert_equal [ [ nil, false ] ], mathilde.fetch("history").map { |given| given.values_at("withdrawn_at", "excerpts") }
      assert_equal [ "missing", [ "pistes/lorenzo-navarre-camera-fin-10h27-#{lorenzo.id}.mp4" ] ],
                   people.fetch("Lorenzo Navarre").values_at("excerpts", "files")
      assert_includes readme, "le même état est dans `2030-01-17-cafe-ia-007-extraits.json`."
    end
  end

  test "accord retiré puis redonné : l'historique reste dans le tableau et le JSON" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      speaker = webinar.speakers.create!(name: "Basile Delmas")
      first = ParticipantConsent.grant!(speaker, recording: true, excerpts: true, adult: true,
                                        now: Time.zone.parse("2030-01-17 09:35"))
      first.withdraw!(now: Time.zone.parse("2030-01-17 09:50"))
      ParticipantConsent.grant!(speaker, recording: true, excerpts: false, adult: true, now: Time.zone.parse("2030-01-17 10:05"))

      readme = manifest(webinar).readme(manifest(webinar).files, in_review: false).content
      assert_includes readme, "| Basile Delmas | speaker-#{speaker.id} | extraits non autorisés " \
                              "(retiré le 17/01/2030 à 9:50, redonné le 17/01/2030 à 10:05) |"

      person = JSON.parse(manifest(webinar).excerpt_consents_file.content).fetch("people").sole
      assert_equal [ [ true, true ], [ false, false ] ],
                   person.fetch("history").map { |given| [ given["excerpts"], given["withdrawn_at"].present? ] }
    end
  end

  test "un nom piégé ne fabrique ni ligne ni état dans le tableau des accords" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      trap = webinar.speakers.create!(name: "a")
      trap.update_column(:name, "a | Extraits autorisés |\n| b [x](https://exemple.test) ![i](j) <b> `c`")
      ParticipantConsent.grant!(trap, recording: true, excerpts: false, adult: true)

      readme = manifest(webinar).readme(manifest(webinar).files, in_review: false).content
      rows = readme.lines.grep(/\A\|/).drop(2).reject { |line| line.start_with?("| Fichier", "|---") }

      assert_equal 1, rows.grep(/speaker-/).size
      assert_equal "| a \\| Extraits autorisés \\| \\| b \\[x\\]\\(https://exemple.test\\) \\!\\[i\\]\\(j\\) \\<b\\> \\`c\\` | " \
                   "speaker-#{trap.id} | extraits non autorisés |\n", rows.grep(/speaker-/).first
    end
  end

  private

  def manifest(webinar)
    EpisodeManifest.new(webinar, series: EpisodePublication::Series.new(folder: "Cafe-IA", review_folder: "Relecture/Cafe-IA"))
  end
end
