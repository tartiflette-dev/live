# frozen_string_literal: true

require "test_helper"

# LightVersion — contrat par fichiers avec le moteur externe des versions
# légères (docs/replays.md) : demande écrite par l'application, version
# légère et marqueur écrits par le moteur, tous deux périmés si l'original
# change de taille.
class LightVersionTest < ActiveSupport::TestCase
  include EpisodePublicationHelpers

  NOW = Time.zone.parse("2030-01-17 11:00")

  # Ce qu'écrit le script pour un assemblage : version légère et marqueur.
  def mark(light, status:, content: "leger")
    output = Recording.recordings_root.join("_leger/#{light.recording.path}")
    FileUtils.mkdir_p(output.dirname)
    File.binwrite(output, content) if status == "done"
    File.write("#{output}.json", { status: status, source_size: light.recording.size_on_disk,
                                   output_size: content.bytesize }.to_json)
    output
  end

  test "réencodées : composite, assemblage, caméra en .mp4 ; jamais un écran, un son seul, une vidéo VP8" do
    with_recordings_root do
      webinar = ended_cafe
      eligible = [ add_recording(webinar, kind: "composite", file: "seance.mp4"),
                   add_recording(webinar, kind: "participant", identity: "speaker-1", file: "mux.mp4"),
                   add_recording(webinar, kind: "track", identity: "speaker-1", source: "camera", file: "cam.mp4") ]
      kept = [ add_recording(webinar, kind: "track", identity: "host-1", source: "screen_share", file: "ecran.mp4"),
               add_recording(webinar, kind: "track", identity: "speaker-1", source: "microphone", file: "micro.ogg"),
               add_recording(webinar, kind: "participant", identity: "speaker-2", file: "mux.webm"),
               add_recording(webinar, kind: "participant", identity: "speaker-3", file: "mux.m4a"),
               add_recording(webinar, kind: "composite", file: "absent.mp4", bytes: nil) ]

      assert(eligible.all? { |recording| LightVersion.for(recording) })
      assert(kept.none? { |recording| LightVersion.for(recording) })
    end
  end

  test "demande : chemins relatifs, CRF 26 pour le composite (rangé avec les replays), 23 sinon ; une demande à jour n'est pas réécrite" do
    with_recordings_root do |root|
      webinar = ended_cafe(slug: "cafe-ia-9")
      composite = add_recording(webinar, kind: "composite", file: "20300117-090000.mp4", bytes: "v" * 50)
      mux = add_recording(webinar, kind: "participant", identity: "speaker-1", file: "mux-1.mp4", bytes: "m" * 40)

      LightVersion.for(composite).request!(NOW)
      LightVersion.for(mux).request!(NOW)
      LightVersion.for(mux).request!(NOW + 1.hour)

      assert_equal({ "recording_id" => composite.id, "source" => "cafe-ia-9/20300117-090000.mp4",
                     "output" => "_replays/cafe-ia-9/20300117-090000.mp4", "crf" => 26, "max_height" => 1080,
                     "source_size" => 50, "requested_at" => "2030-01-17T10:00:00Z" },
                   JSON.parse(root.join("_leger/demandes/#{composite.id}.json").read))
      request = JSON.parse(root.join("_leger/demandes/#{mux.id}.json").read)
      assert_equal [ "_leger/_participants/cafe-ia-9/mux-1.mp4", 23, "2030-01-17T10:00:00Z" ],
                   request.values_at("output", "crf", "requested_at")
      assert_empty Dir.glob(root.join("_leger/demandes/.*.tmp").to_s), "écriture atomique, sans reste"
    end
  end

  test "prête seulement avec un marqueur done de l'original courant et le fichier à la taille notée" do
    with_recordings_root do
      webinar = ended_cafe
      mux = add_recording(webinar, kind: "participant", identity: "speaker-1", file: "mux.mp4", bytes: "m" * 40)
      light = -> { LightVersion.for(mux.reload) }

      assert_nil light.call.file
      output = mark(light.call, status: "done")
      assert_equal output, light.call.file

      File.binwrite(output, "tronque")
      assert_nil light.call.file, "taille différente de celle notée"

      mark(light.call, status: "done")
      File.binwrite(mux.absolute_path, "m" * 41)
      assert_nil light.call.file, "assemblage refait : la version légère est périmée"
      assert_not light.call.settled?
    end
  end

  test "marqueur original : réglée sans fichier, l'original sera déposé" do
    with_recordings_root do
      mux = add_recording(ended_cafe, kind: "participant", identity: "speaker-1", file: "mux.mp4")
      mark(LightVersion.for(mux), status: "original")

      light = LightVersion.for(mux)
      assert light.settled?
      assert_nil light.file
      assert_not light.waiting?(NOW)
    end
  end

  test "attendue sans demande, ou demandée depuis moins de WAIT ; plus au-delà" do
    with_recordings_root do
      mux = add_recording(ended_cafe, kind: "participant", identity: "speaker-1", file: "mux.mp4")

      assert LightVersion.for(mux).waiting?(NOW)
      LightVersion.for(mux).request!(NOW)
      assert LightVersion.for(mux).waiting?(NOW + LightVersion::WAIT - 1.minute)
      assert_not LightVersion.for(mux).waiting?(NOW + LightVersion::WAIT + 1.minute)
    end
  end
end
