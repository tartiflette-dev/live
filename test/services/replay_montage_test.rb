require "test_helper"

# Montage du replay : document de rendu tiré de la base (pistes, parole,
# mises en avant), file de demandes, adoption comme copie de diffusion.
# Vidéo de référence : composite 09:31:06 → 10:27:44 (3398 s).
class ReplayMontageTest < ActiveSupport::TestCase
  include ReplayHelpers

  T0 = Time.zone.parse("2030-01-17 09:31:06")
  LAG = ParticipantMux::VIDEO_ACTIVATION_LAG

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-montage")
    ENV["RECORDINGS_ROOT"] = @tmp
    @webinar = ended_cafe
    @composite = add_recording(@webinar, kind: "composite", file: "composite.mp4")
    @anne_camera = track("host-anne", "camera", 14.0)
    @anne_mic = track("host-anne", "microphone", 13.5)
    @ines_camera = track("speaker-1", "camera", 300.0)
    @ines_mic = track("speaker-1", "microphone", 299.0)
    @replay = Replay.prepare!(@webinar)
    @montage = ReplayMontage.new(@replay)
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  test "document : plans sur la parole, pistes calées sur media_started_at, son calé sur le micro de qui parle le plus" do
    says("host-anne", 20, 400)
    says("speaker-1", 400, 2000)
    says("host-anne", 2000, 2100)

    document = @montage.document

    assert_equal [ "_replays/#{@webinar.slug}/montage-#{@composite.id}.mp4", 3398.0 ], document.values_at(:output, :duration)
    assert_equal({ path: @composite.path, end: 3398.0 }, document[:composite])
    assert_equal [ { key: "v#{@anne_camera.id}", path: @anne_camera.path, offset: (14.0 - LAG).round(3) },
                   { key: "v#{@ines_camera.id}", path: @ines_camera.path, offset: (300.0 - LAG).round(3) } ], document[:sources]
    # 299,9 s : la caméra d'Inès arrive, nouvelle vignette sans changer le grand cadre.
    assert_equal [ [ 0.0, 20.0, "composite", nil ], [ 20.0, 299.9, "speaker", "v#{@anne_camera.id}" ],
                   [ 299.9, 400.0, "speaker", "v#{@anne_camera.id}" ],
                   [ 400.0, 2000.0, "speaker", "v#{@ines_camera.id}" ], [ 2000.0, 3398.0, "speaker", "v#{@anne_camera.id}" ] ],
                 document[:shots].map { |shot| shot.values_at(:from, :to, :layout, :main) }
    assert_equal [ "v#{@anne_camera.id}" ], document[:shots][3][:thumbnails]

    # Quatre tranches de 849,5 s : Anne et Inès dans la 1re, Inès seule dans la
    # 2e, les deux dans la 3e, personne dans la 4e.
    probes = document[:probes]
    part = 3398.0 / 4
    assert_equal [ [ 0, @anne_mic.path ], [ 0, @ines_mic.path ], [ 1, @ines_mic.path ], [ 2, @ines_mic.path ], [ 2, @anne_mic.path ] ].sort,
                 probes.map { |probe| [ (probe[:from] / part).floor, probe[:path] ] }.sort
    offsets = { @anne_mic.path => 13.5, @ines_mic.path => 299.0 }
    probes.each do |probe|
      assert_equal offsets.fetch(probe[:path]), probe[:offset], "micro calé sur media_started_at, sans délai vidéo"
      assert_equal ReplayMontage::PROBE_SECONDS, probe[:to] - probe[:from]
      assert_operator probe[:from], :>=, probe[:offset], "fenêtre dans le fichier du micro"
    end
    assert_empty document[:notes]
  end

  test "extrait : bornes ramenées à 0, plans coupés, seules les pistes vues" do
    says("host-anne", 20, 400)
    says("speaker-1", 400, 2000)

    document = @montage.document(window: 350.0..450.0)

    assert_equal 100.0, document[:duration]
    assert_equal 3048.0, document.dig(:composite, :end)
    assert_equal [ [ 0.0, 50.0, "v#{@anne_camera.id}" ], [ 50.0, 100.0, "v#{@ines_camera.id}" ] ],
                 document[:shots].map { |shot| shot.values_at(:from, :to, :main) }
    assert_equal (14.0 - LAG - 350).round(3), document[:sources].first[:offset]
    assert_match %r{_replays/#{@webinar.slug}/extrait-#{@composite.id}-350-450\.mp4}, document[:output]
  end

  test "piste sans media_started_at : calée sur la demande d'egress (1 s plus tôt), et la note le dit" do
    @ines_camera.update!(media_started_at: nil)
    says("speaker-1", 400, 2000)

    document = @montage.document

    assert_equal 299.0, document[:sources].find { |source| source[:key] == "v#{@ines_camera.id}" }[:offset]
    assert_equal [ "speaker-1 (piste #{@ines_camera.id}) : calage approximatif, instant de début de fichier inconnu" ], document[:notes]
  end

  test "mise en avant journalisée pendant la vidéo respectée ; celle d'avant (autre séance) ignorée" do
    says("host-anne", 20, 3000)
    @webinar.spotlight_changes.create!(identity: "speaker-1", changed_at: T0 - 60)
    @webinar.spotlight_changes.create!(identity: "speaker-1", changed_at: T0 + 1000)
    @webinar.spotlight_changes.create!(identity: nil, changed_at: T0 + 1500)

    mains = @montage.document[:shots].map { |shot| shot.values_at(:from, :main) }

    assert_equal [ [ 0.0, nil ], [ 20.0, "v#{@anne_camera.id}" ], [ 299.9, "v#{@anne_camera.id}" ], [ 1000.0, "v#{@ines_camera.id}" ],
                   [ 1500.0, "v#{@anne_camera.id}" ] ], mains
  end

  test "demande, rendu, adoption : la copie de diffusion devient le montage, la demande quitte la file" do
    says("host-anne", 20, 400)

    assert @montage.request!
    assert_equal :pending, fresh.status
    assert_not fresh.request!, "même contenu déjà en file : gardé"

    render(status: "done")
    montage = fresh
    assert_equal :done, montage.status
    assert montage.adopt!

    assert_equal "_replays/#{@webinar.slug}/montage-#{@composite.id}.mp4", @replay.reload.derived_path
    assert_equal Recording.recordings_root.join(@replay.derived_path), @replay.video_file
    assert_not ReplayMontage.request_path_for(@replay.id).exist?
    assert_equal :adopted, fresh.status
    assert_not fresh.request!, "rien n'a changé depuis le montage adopté"

    says("speaker-1", 400, 900)
    assert fresh.request!, "nouvelle parole : nouveau montage"
  end

  test "échec du rendu : l'état le dit, une nouvelle demande le relance sous un autre identifiant" do
    says("host-anne", 20, 400)
    @montage.request!
    first_id = request_document["request_id"]
    render(status: "failed", reason: "rendu en échec (code 1)")

    assert_equal [ :failed, "rendu en échec (code 1)" ], [ fresh.status, fresh.failure ]
    assert_not fresh.adopt!
    assert fresh.request!
    assert_not_equal first_id, request_document["request_id"]
    assert_equal :pending, fresh.status, "le marqueur d'une autre demande ne compte pas"
  end

  test "montage noté fait mais absent ou tronqué : en échec, jamais adopté" do
    says("host-anne", 20, 400)
    @montage.request!
    render(status: "done")
    output.write("tronqué")

    assert_equal :failed, fresh.status
    assert_not fresh.adopt!
    assert_nil @replay.reload.derived_path
  end

  test "vidéo de référence absente du disque : aucune demande" do
    File.delete(@composite.absolute_path)

    assert_raises(ArgumentError) { ReplayMontage.new(@replay.reload).request! }
    assert_not ReplayMontage.request_path_for(@replay.id).exist?
  end

  test "purge : montage, marqueur et demande supprimés" do
    says("host-anne", 20, 400)
    @montage.request!
    render(status: "done")

    assert_equal 3, fresh.purge!
    assert_empty Dir.glob(File.join(@tmp, "{_replays,_montages}/**/*.*"))
  end

  private

  def track(identity, source, media_offset)
    extension = source == "microphone" ? "ogg" : "mp4"
    recording = add_recording(@webinar, kind: "track", file: "#{identity}-#{source}.#{extension}", identity: identity, source: source,
                                        started: T0 + media_offset - 1, ended: T0 + 3400)
    recording.update!(media_started_at: T0 + media_offset)
    recording
  end

  def says(identity, from, to)
    @segment_index = (@segment_index || 0) + 1
    @webinar.transcript_segments.create!(participant_identity: identity, text: "Une phrase qui compte.", started_at: T0 + from,
                                         ended_at: T0 + to, segment_id: "seg-#{@segment_index}")
  end

  def fresh
    ReplayMontage.new(@replay.reload)
  end

  def request_document
    JSON.parse(ReplayMontage.request_path_for(@replay.id).read)
  end

  def output
    Recording.recordings_root.join("_replays/#{@webinar.slug}/montage-#{@composite.id}.mp4")
  end

  # Ce que fait le moteur de rendu externe pour la demande en file
  # (docs/replays.md).
  def render(status:, reason: nil)
    FileUtils.mkdir_p(output.dirname)
    output.write("vidéo montée") if status == "done"
    marker = { status: status, request_id: request_document["request_id"], digest: request_document["digest"], reason: reason,
               output_size: (output.size if status == "done") }
    output.sub_ext(".mp4.json").write(marker.compact.to_json)
  end
end
