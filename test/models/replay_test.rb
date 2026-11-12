require "test_helper"

class ReplayTest < ActiveSupport::TestCase
  include ReplayHelpers

  test "publish! choisit le composite terminé le plus long, pas la répétition" do
    with_recordings_root do
      webinar = ended_cafe
      add_recording(webinar, kind: "composite", file: "repetition.mp4",
                             started: Time.zone.parse("2030-01-17 09:00"), ended: Time.zone.parse("2030-01-17 09:10"))
      seance = add_recording(webinar, kind: "composite", file: "seance.mp4")
      add_recording(webinar, kind: "composite", file: "echec.mp4", status: "failed",
                             started: Time.zone.parse("2030-01-17 08:00"), ended: Time.zone.parse("2030-01-17 11:00"))

      replay = Replay.publish!(webinar, now: Time.zone.parse("2030-01-18 12:00"))

      assert_equal seance, replay.recording
      assert_equal Time.zone.parse("2030-01-18 12:00"), replay.published_at
      assert_in_delta 3398.0, replay.duration
    end
  end

  test "publish! sans vue d'ensemble lisible : rien n'est publié" do
    with_recordings_root do
      webinar = ended_cafe
      add_recording(webinar, kind: "composite", file: "absent.mp4", bytes: nil)

      assert_nil Replay.publish!(webinar)
      assert_nil webinar.reload.replay
    end
  end

  test "republier garde la vidéo déjà choisie, même si un composite plus long est arrivé depuis" do
    with_recordings_root do
      replay = replay_cafe
      replay.unpublish!
      assert_not replay.reload.published?
      add_recording(replay.webinar, kind: "composite", file: "reprise.mp4",
                                    started: Time.zone.parse("2030-01-17 08:00"), ended: Time.zone.parse("2030-01-17 11:00"))

      republished = Replay.publish!(replay.webinar.reload)

      assert_equal replay.recording_id, republished.recording_id
      assert republished.published?
    end
  end

  test "la vidéo lue est la copie de diffusion si elle est sur disque, sinon le composite" do
    with_recordings_root do |root|
      replay = replay_cafe
      assert_equal replay.recording.absolute_path, replay.video_file

      derived = "#{Replay::DERIVED_SUBDIR}/#{replay.webinar.slug}/diffusion-720p.mp4"
      replay.update!(derived_path: derived)
      assert_equal replay.recording.absolute_path, replay.video_file, "copie annoncée mais absente : le composite"

      FileUtils.mkdir_p(root.join(File.dirname(derived)))
      File.binwrite(root.join(derived), "720p")
      assert_equal root.join(derived), replay.video_file
    end
  end

  test "la copie de diffusion reste sous _replays/<slug>/, en .mp4" do
    with_recordings_root do
      replay = replay_cafe
      slug = replay.webinar.slug
      [ "#{slug}/composite.mp4", "_replays/autre-cafe/x.mp4", "_replays/#{slug}/../../#{slug}/x.mp4",
        "_replays/#{slug}/x.mkv", "/etc/passwd" ].each do |path|
        replay.derived_path = path
        assert_not replay.valid?, path
        assert replay.errors.added?(:derived_path, :outside_root), path
      end
      replay.derived_path = "_replays/#{slug}/sous/dossier.mp4"
      assert replay.valid?
    end
  end

  test "la vidéo de référence est un composite de CE webinaire" do
    with_recordings_root do
      replay = replay_cafe
      other = ended_cafe
      replay.recording = add_recording(other, kind: "composite", file: "autre.mp4")
      assert_not replay.valid?
      replay.recording = add_recording(replay.webinar, kind: "track", file: "piste.ogg", identity: "speaker-1", source: "microphone")
      assert_not replay.valid?
    end
  end

  test "sous-titres WebVTT calés sur le début de la vue d'ensemble" do
    with_recordings_root do
      replay = replay_cafe
      add_segment(replay.webinar, "Bonjour à toutes et à tous", at: Time.zone.parse("2030-01-17 09:32:06"))
      add_segment(replay.webinar, "Avant l'enregistrement", at: Time.zone.parse("2030-01-17 09:20:00"))

      vtt = replay.subtitles_vtt

      assert vtt.start_with?("WEBVTT\n")
      assert_includes vtt, "00:01:00.000 --> 00:01:03.000\n<v Basile Delmas>Bonjour à toutes et à tous"
      assert_not_includes vtt, "Avant l'enregistrement"
      assert replay.subtitles?
    end
  end

  test "supprimé avec sa vidéo de référence (purge de rétention)" do
    with_recordings_root do
      replay = replay_cafe
      Recording.where(id: replay.recording_id).delete_all
      assert_not Replay.exists?(replay.id)
    end
  end
end
