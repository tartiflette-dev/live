# frozen_string_literal: true

require "test_helper"

# ParticipantMux — tests unitaires du calcul de décalage et de la
# commande ffmpeg (montage par personne). N'EXÉCUTE PAS ffmpeg : l'intégration
# réelle est couverte par participant_mux_integration_test.rb.
class ParticipantMuxTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(
      title:     "Mux test",
      slug:      "mux-test-#{SecureRandom.hex(3)}",
      starts_at: 1.hour.ago,
      host_sub:  "host-sub-#{SecureRandom.hex(3)}",
      room_name: "room-#{SecureRandom.hex(3)}",
      state:     "ended",
      kind:      "cafe_ia"
    )
    @identity = "speaker-7"
    @t0 = Time.utc(2026, 10, 7, 10, 0, 0)
  end

  test "offsets poses t0 = min(started_at) et chaque flux reçoit started_at - t0" do
    video = make_track(source: "camera",     started_at: @t0,       ended_at: @t0 + 20,   path_suffix: ".mp4")
    audio = make_track(source: "microphone", started_at: @t0 + 0.5, ended_at: @t0 + 20.3, path_suffix: ".ogg")
    write_fake_file(video)
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "/bin/true",
                             prober: fake_prober(video: "h264", audio: "opus"))
    offs = mux.offsets

    assert_in_delta 0.0, offs.fetch(video), 1e-3
    assert_in_delta 0.5, offs.fetch(audio), 1e-3
  end

  test "offsets quand l'audio démarre AVANT la vidéo — t0 = audio" do
    audio = make_track(source: "microphone", started_at: @t0,       ended_at: @t0 + 10, path_suffix: ".ogg")
    video = make_track(source: "camera",     started_at: @t0 + 0.3, ended_at: @t0 + 10, path_suffix: ".mp4")
    write_fake_file(audio)
    write_fake_file(video)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "/bin/true",
                             prober: fake_prober(video: "h264", audio: "opus"))
    offs = mux.offsets

    assert_in_delta 0.0, offs.fetch(audio), 1e-3
    assert_in_delta 0.3, offs.fetch(video), 1e-3
  end

  # Constat en direct, hôte : caméra et micro demandés au même instant (started_at
  # à 25 ms près), mais le fichier caméra ne commence qu'à la première image
  # clé, 0,77 s après le premier son (passage ACTIVE). Recaler sur
  # started_at avançait la vidéo de 0,65 s (SyncNet) : c'est le défaut corrigé.
  test "recalage sur le début réel des fichiers : la vidéo attend sa première image clé" do
    video = make_track(source: "camera", started_at: @t0 + 0.025, ended_at: @t0 + 60, path_suffix: ".mp4",
                       media_started_at: @t0 + 1.914)
    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 60, path_suffix: ".ogg",
                       media_started_at: @t0 + 1.142)
    write_fake_file(video)
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(video: "h264", audio: "opus"))
    cmd = mux.ffmpeg_command(output_absolute: Pathname.new("/tmp/out.mp4"))

    expected = (0.772 - ParticipantMux::VIDEO_ACTIVATION_LAG).round(3)
    assert_in_delta expected, mux.offsets.fetch(video), 1e-3
    assert_in_delta 0.0, mux.offsets.fetch(audio), 1e-3
    assert_equal format("%.3f", expected), itsoffset_before(cmd, video.absolute_path)
    assert_equal "0.000", itsoffset_before(cmd, audio.absolute_path)
    assert_nil mux.note, "calage exact : pas de note"
  end

  test "micro ouvert après la caméra : c'est l'audio qui est retardé" do
    video = make_track(source: "camera", started_at: @t0, ended_at: @t0 + 60, path_suffix: ".mp4",
                       media_started_at: @t0 + 1.0)
    audio = make_track(source: "microphone", started_at: @t0 + 30, ended_at: @t0 + 60, path_suffix: ".ogg",
                       media_started_at: @t0 + 31.05)
    write_fake_file(video)
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(video: "h264", audio: "opus"))

    assert_in_delta 0.0, mux.offsets.fetch(video), 1e-3
    assert_in_delta 30.05 + ParticipantMux::VIDEO_ACTIVATION_LAG, mux.offsets.fetch(audio), 1e-3
  end

  test "début de fichier inconnu pour une piste : recalage sur started_at pour les deux, et note" do
    video = make_track(source: "camera", started_at: @t0 + 0.4, ended_at: @t0 + 60, path_suffix: ".mp4",
                       media_started_at: @t0 + 1.9)
    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 60, path_suffix: ".ogg")
    write_fake_file(video)
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(video: "h264", audio: "opus"))

    assert_in_delta 0.4, mux.offsets.fetch(video), 1e-3, "jamais une horloge par piste"
    assert_in_delta 0.0, mux.offsets.fetch(audio), 1e-3
    assert_equal "calage lèvres/voix approximatif : instant de début de fichier inconnu (micro (piste #{audio.id}))",
                 mux.note
  end

  test "caméra au début de fichier inconnu : la note la nomme" do
    video = make_track(source: "camera", started_at: @t0, ended_at: @t0 + 60, path_suffix: ".mp4")
    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 60, path_suffix: ".ogg",
                       media_started_at: @t0 + 1.1)
    write_fake_file(video)
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(video: "h264", audio: "opus"))

    assert_equal({ video => 0.0, audio => 0.0 }, mux.offsets)
    assert_equal "calage lèvres/voix approximatif : instant de début de fichier inconnu (caméra (piste #{video.id}))",
                 mux.note
  end

  test "piste seule sans début de fichier connu : montage sans décalage ni note de calage" do
    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 10, path_suffix: ".ogg")
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(audio: "opus"))

    assert_equal({ audio => 0.0 }, mux.offsets)
    assert_nil mux.note
  end

  test "ffmpeg_command pose -itsoffset AVANT chaque -i et sélectionne video+audio" do
    video = make_track(source: "camera",     started_at: @t0,       ended_at: @t0 + 20, path_suffix: ".mp4")
    audio = make_track(source: "microphone", started_at: @t0 + 0.5, ended_at: @t0 + 20, path_suffix: ".ogg")
    write_fake_file(video)
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(video: "h264", audio: "opus"))
    output = Pathname.new("/tmp/out.mp4")
    cmd = mux.ffmpeg_command(output_absolute: output)

    # L'ordre des -i respecte l'ordre [video, audio] et chaque -i est
    # IMMÉDIATEMENT précédé par son -itsoffset (contrat ffmpeg).
    i_positions = cmd.each_with_index.select { |a, _| a == "-i" }.map(&:last)
    assert_equal 2, i_positions.size
    i_positions.each do |idx|
      assert_equal "-itsoffset", cmd[idx - 2], "chaque -i doit être précédé de -itsoffset"
    end

    assert_includes cmd, "-map"
    v_map_idx = cmd.each_with_index.find { |a, _| a == "0:v:0" }&.last
    a_map_idx = cmd.each_with_index.find { |a, _| a == "1:a:0" }&.last
    assert v_map_idx, "la vidéo doit être mappée en 0:v:0"
    assert a_map_idx, "l'audio doit être mappé en 1:a:0"

    assert_includes cmd, "copy", "H.264 recopié sans réencodage"
    assert_includes cmd, "aac",  "Opus → AAC"
    assert_includes cmd, "+faststart"
    assert_equal output.to_s, cmd.last
  end

  test "ffmpeg_command audio-seul → .m4a, pas de -c:v" do
    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 10, path_suffix: ".ogg")
    write_fake_file(audio)
    # Pas de piste camera → audio seul.

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(audio: "opus"))
    assert_equal ".m4a", mux.extension
    assert_equal "audio/mp4", mux.content_type

    output = Pathname.new("/tmp/out.m4a")
    cmd = mux.ffmpeg_command(output_absolute: output)

    refute_includes cmd, "copy",         "pas de -c:v sur audio seul"
    refute_includes cmd, "+faststart",   "pas de +faststart sur .m4a"
    assert_includes cmd, "0:a:0",        "audio mappé en 0:a:0"
    assert_includes cmd, "aac"
  end

  test "ignore les pistes failed et vise la plus récente par source" do
    make_track(source: "camera", status: "failed", started_at: @t0 - 60, ended_at: @t0 - 50)
    recent_cam = make_track(source: "camera", started_at: @t0, ended_at: @t0 + 10, path_suffix: ".mp4")
    write_fake_file(recent_cam)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "/bin/true",
                             prober: fake_prober(video: "h264"))
    assert_equal recent_cam.id, mux.video_recording.id
  end

  test "ffmpeg_command sans aucune piste exploitable → NothingToMux" do
    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "/bin/true")
    assert_raises(ParticipantMux::NothingToMux) do
      mux.ffmpeg_command(output_absolute: Pathname.new("/tmp/x.mp4"))
    end
  end

  test "ffmpeg_command lève SourceMissing si le fichier n'est pas sur disque" do
    make_track(source: "camera", started_at: @t0, ended_at: @t0 + 10, path_suffix: ".mp4") # pas de write_fake_file

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "/bin/true",
                             prober: fake_prober(video: "h264"))
    assert_raises(ParticipantMux::SourceMissing) do
      mux.ffmpeg_command(output_absolute: Pathname.new("/tmp/out.mp4"))
    end
  end

  test "ffmpeg_command VP8 + Opus → .webm, vidéo ET audio copiés, pas de faststart" do
    video = make_track(source: "camera",     started_at: @t0,       ended_at: @t0 + 20, path_suffix: ".webm")
    audio = make_track(source: "microphone", started_at: @t0 + 0.5, ended_at: @t0 + 20, path_suffix: ".ogg")
    write_fake_file(video)
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(video: "vp8", audio: "opus"))
    cmd = mux.ffmpeg_command(output_absolute: Pathname.new("/tmp/out.webm"))

    assert_equal ".webm", mux.extension
    assert_equal "video/webm", mux.content_type
    assert_equal %w[copy copy], codec_args(cmd), "-c:v copy puis -c:a copy"
    refute_includes cmd, "aac"
    refute_includes cmd, "+faststart"
  end

  test "extension : H.264 → mp4 ; VP8, VP9 → webm" do
    video = make_track(source: "camera",     started_at: @t0, ended_at: @t0 + 5, path_suffix: ".webm")
    write_fake_file(video)

    { "h264" => ".mp4", "vp8" => ".webm", "vp9" => ".webm" }.each do |codec, extension|
      mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                               prober: fake_prober(video: codec))
      assert_equal extension, mux.extension, "codec #{codec}"
    end
  end

  test "webm : un audio qui n'est ni Opus ni Vorbis est réencodé en Opus" do
    video = make_track(source: "camera",     started_at: @t0, ended_at: @t0 + 5, path_suffix: ".webm")
    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 5, path_suffix: ".m4a")
    write_fake_file(video)
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(video: "vp8", audio: "aac"))
    cmd = mux.ffmpeg_command(output_absolute: Pathname.new("/tmp/out.webm"))

    assert_equal %w[copy libopus], codec_args(cmd)
  end

  test "piste vide écartée : montage avec l'autre piste (audio seul) et note explicite" do
    video = make_track(source: "camera",     started_at: @t0, ended_at: @t0 + 5, path_suffix: ".webm")
    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 5, path_suffix: ".ogg")
    write_fake_file(video)
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(video: "vp8", video_packets: 0, audio: "opus"))

    assert_nil mux.video_recording
    assert_equal audio.id, mux.audio_recording.id
    assert_equal ".m4a", mux.extension
    assert_equal "microphone", mux.track_source
    assert_match(/caméra \(piste #{video.id}\) écartée : aucune image exploitable/, mux.note)
    refute_includes mux.ffmpeg_command(output_absolute: Pathname.new("/tmp/o.m4a")), "-c:v"
  end

  test "caméra vide la plus récente : retombe sur la piste caméra précédente" do
    older = make_track(source: "camera", started_at: @t0 - 60, ended_at: @t0 - 30, path_suffix: ".webm")
    newer = make_track(source: "camera", started_at: @t0,      ended_at: @t0 + 5,  path_suffix: ".webm")
    write_fake_file(older)
    write_fake_file(newer)
    prober = FakeProber.new { |path, _type| [ "vp8", path.to_s == newer.absolute_path.to_s ? 0 : 12 ] }

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg", prober: prober)

    assert_equal older.id, mux.video_recording.id
    assert_match(/caméra \(piste #{newer.id}\) écartée/, mux.note)
  end

  test "fichier illisible (ffprobe nil) traité comme piste vide ; plus aucune piste → NothingToMux explicite" do
    video = make_track(source: "camera", started_at: @t0, ended_at: @t0 + 5, path_suffix: ".webm")
    write_fake_file(video)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg", prober: fake_prober)
    error = assert_raises(ParticipantMux::NothingToMux) do
      mux.ffmpeg_command(output_absolute: Pathname.new("/tmp/o.mp4"))
    end
    assert_match(/caméra \(piste #{video.id}\) écartée/, error.message)
  end

  test "sonde interrompue : ProbeFailed (montage relançable), la piste n'est pas écartée comme vide" do
    video = make_track(source: "camera", started_at: @t0, ended_at: @t0 + 5, path_suffix: ".webm")
    write_fake_file(video)
    prober = FakeProber.new { |_path, _type| raise TrackProbe::Interrupted, "ffprobe interrompu (rc=124)" }

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg", prober: prober)
    error = assert_raises(ParticipantMux::ProbeFailed) { mux.ffmpeg_command(output_absolute: Pathname.new("/tmp/o.mp4")) }
    assert_match(/piste #{video.id} : ffprobe interrompu \(rc=124\)/, error.message)
  end

  test "ffprobe introuvable : MissingBinary avant tout montage" do
    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 5, path_suffix: ".ogg")
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "/bin/true",
                             prober: TrackProbe.new(ffprobe_bin: "/nonexistent/ffprobe"))
    error = assert_raises(ParticipantMux::MissingBinary) { mux.call }
    assert_match(/ffprobe introuvable/, error.message)
  end

  test "pas de -shortest : une piste courte ne tronque pas le montage" do
    video = make_track(source: "camera",     started_at: @t0, ended_at: @t0 + 3,  path_suffix: ".webm")
    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 20, path_suffix: ".ogg")
    write_fake_file(video)
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(video: "vp8", audio: "opus"))
    refute_includes mux.ffmpeg_command(output_absolute: Pathname.new("/tmp/o.webm")), "-shortest"
  end

  test "montage complet : pas de note" do
    video = make_track(source: "camera", started_at: @t0, ended_at: @t0 + 5, path_suffix: ".mp4")
    write_fake_file(video)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(video: "h264"))
    assert_nil mux.note
    assert_equal "camera", mux.track_source
  end

  test "relative_output_path sous participants/<slug>/ et respecte l'anti-traversal" do
    video = make_track(source: "camera", started_at: @t0, ended_at: @t0 + 10, path_suffix: ".mp4")
    write_fake_file(video)

    mux = ParticipantMux.new(webinar: @webinar, identity: "speaker-42", ffmpeg_bin: "/bin/true",
                             prober: fake_prober(video: "h264"))
    rel = mux.relative_output_path

    expected_prefix = "#{Recording::PARTICIPANTS_SUBDIR}/#{@webinar.slug}/"
    assert rel.start_with?(expected_prefix),
      "préfixe participants/<slug>/ obligatoire (dossier posé par Rails, pas l'egress) ; obtenu : #{rel}"
    refute_includes rel, ".."
  end

  # ---- Un montage par lot de pistes ------------------

  test "lot fourni : seules ses pistes sont montées, même si la personne en a de plus récentes" do
    seance = @t0 + 28 * 60
    rehearsal_video = make_track(source: "camera",     started_at: @t0, ended_at: @t0 + 360, path_suffix: ".mp4")
    rehearsal_audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 360, path_suffix: ".ogg")
    session_video   = make_track(source: "camera",     started_at: seance, ended_at: seance + 3360, path_suffix: ".mp4")
    [ rehearsal_video, rehearsal_audio, session_video ].each { |rec| write_fake_file(rec) }

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, track_ids: [ rehearsal_video.id, rehearsal_audio.id ],
                             ffmpeg_bin: "ffmpeg", prober: fake_prober(video: "h264", audio: "opus"))

    assert_equal [ rehearsal_video, rehearsal_audio ], mux.tracks
  end

  test "nom de sortie horodaté du début du lot : deux lots d'une personne ne partagent pas de fichier" do
    seance = @t0 + 28 * 60
    rehearsal = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 360, path_suffix: ".ogg")
    session   = make_track(source: "microphone", started_at: seance, ended_at: seance + 3360, path_suffix: ".ogg")
    [ rehearsal, session ].each { |rec| write_fake_file(rec) }

    path_for = lambda do |track|
      ParticipantMux.new(webinar: @webinar, identity: @identity, track_ids: [ track.id ],
                         ffmpeg_bin: "ffmpeg", prober: fake_prober(audio: "opus")).relative_output_path
    end

    assert_equal "_participants/#{@webinar.slug}/mux-speaker-7-20261007-100000.m4a", path_for.(rehearsal)
    assert_equal "_participants/#{@webinar.slug}/mux-speaker-7-20261007-102800.m4a", path_for.(session)
  end

  # Le nom suit le lot COUVERT, pas les seules pistes
  # assemblées — même date que la page des enregistrements.
  test "lot avec une piste écartée : le nom garde la date du début du lot" do
    empty_camera = make_track(source: "camera", started_at: @t0, ended_at: @t0 + 60, path_suffix: ".webm")
    camera = make_track(source: "camera", started_at: @t0 + 20 * 60, ended_at: @t0 + 50 * 60, path_suffix: ".webm")
    microphone = make_track(source: "microphone", started_at: @t0 + 20 * 60, ended_at: @t0 + 50 * 60, path_suffix: ".ogg")
    lot = [ empty_camera, camera, microphone ]
    lot.each { |rec| write_fake_file(rec) }
    prober = FakeProber.new do |path, type|
      type == "video" ? [ "vp8", path.to_s == empty_camera.absolute_path.to_s ? 0 : 12 ] : [ "opus", 10 ]
    end
    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, track_ids: lot.map(&:id),
                             ffmpeg_bin: "ffmpeg", prober: prober)
    lot_mux = Recording.new(webinar: @webinar, kind: "participant", source_track_ids: lot.map(&:id))

    assert_equal [ camera, microphone ], mux.tracks
    assert_equal "_participants/#{@webinar.slug}/mux-speaker-7-20261007-100000.webm", mux.relative_output_path
    assert_equal empty_camera.started_at, lot_mux.sources_started_at
  end

  private

  def make_track(source:, started_at:, ended_at:, status: "done", path_suffix: nil, media_started_at: nil)
    path = path_suffix ? "#{@webinar.slug}/#{SecureRandom.uuid}#{path_suffix}" : nil
    Recording.create!(
      webinar:              @webinar,
      kind:                 "track",
      status:               status,
      participant_identity: @identity,
      track_source:         source,
      started_at:           started_at,
      ended_at:             ended_at,
      media_started_at:     media_started_at,
      path:                 path
    )
  end

  def itsoffset_before(cmd, path)
    index = cmd.index(path.to_s)
    assert_equal "-i", cmd[index - 1]
    assert_equal "-itsoffset", cmd[index - 3]
    cmd[index - 2]
  end

  # Sonde de substitution : `video`/`audio` = codec du flux (nil = fichier
  # sans flux de ce type, comme un ffprobe qui ne trouve rien). L'ffprobe
  # réel est exercé par participant_mux_ffmpeg_test et track_probe_test.
  class FakeProber
    def initialize(&decide)
      @decide = decide
    end

    def available? = true

    def call(path, stream_type)
      codec, packets = @decide.call(path, stream_type)
      codec && TrackProbe::Info.new(codec: codec, packets: packets)
    end
  end

  def fake_prober(video: nil, video_packets: 10, audio: nil, audio_packets: 10)
    FakeProber.new do |_path, stream_type|
      stream_type == "video" ? [ video, video_packets ] : [ audio, audio_packets ]
    end
  end

  # Valeurs qui suivent -c:v / -c:a dans la commande.
  def codec_args(cmd)
    cmd.each_cons(2).select { |flag, _| %w[-c:v -c:a].include?(flag) }.map(&:last)
  end

  def write_fake_file(recording)
    full = recording.absolute_path
    FileUtils.mkdir_p(full.dirname)
    File.binwrite(full, "")
  end

  test "ffmpeg bloqué : tué après le délai, échec explicite (le worker n'est pas immobilisé)" do
    mux = ParticipantMux.new(webinar: @webinar, identity: "speaker-1")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(ParticipantMux::FfmpegFailed) { mux.send(:run_with_deadline, [ "sleep", "30" ], timeout: 1) }
    assert_match(/interrompu après 1 s/, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
  end

  # ---- Écriture atomique + dossier Rails-owned ------

  test "ffmpeg_command vise un fichier .mp4 et pose -threads 1 (pic RAM borné)" do
    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 10, path_suffix: ".ogg")
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "ffmpeg",
                             prober: fake_prober(audio: "opus"))
    cmd = mux.ffmpeg_command(output_absolute: Pathname.new("/tmp/x.m4a"))

    assert_includes cmd, "-threads"
    threads_idx = cmd.each_with_index.find { |a, _| a == "-threads" }.last
    assert_equal "1", cmd[threads_idx + 1], "monothread AAC pour borner le pic RSS (worker 512 Mo)"
  end

  test "call : écriture atomique .part puis rename, suppression du .part sur échec" do
    # ffmpeg rc != 0 (stubbé) → aucun .part ne doit rester,
    # aucun .mp4 final ne doit apparaître. Dossier participants/<slug>/
    # créé par Rails (UID 1000) avant l'invocation.
    tmp = Dir.mktmpdir("mux-atomic")
    prev = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = tmp

    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 2, path_suffix: ".ogg")
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "/bin/true",
                             prober: fake_prober(audio: "opus"))
    # Stub binaire présent + exécution qui écrit un .part puis échoue.
    mux.define_singleton_method(:ensure_binaries!) { nil }
    mux.define_singleton_method(:run_with_deadline) do |cmd, **_opts|
      File.write(cmd.last, "partial-garbage") # simule un ffmpeg qui a commencé à écrire
      [ "boom", Struct.new(:success?, :exitstatus).new(false, 42) ]
    end

    assert_raises(ParticipantMux::FfmpegFailed) { mux.call }

    out_dir = Pathname.new(tmp).join(Recording::PARTICIPANTS_SUBDIR, @webinar.slug)
    assert File.directory?(out_dir), "dossier _participants/<slug>/ créé par Rails avant l'exec ffmpeg"
    children = Dir.children(out_dir)
    assert_empty children.select { |c| c.include?(".part-") }, "aucun .part-* résiduel : #{children.inspect}"
    assert_empty children.select { |c| c.end_with?(".m4a") }, "pas de fichier final sur échec : #{children.inspect}"
  ensure
    ENV["RECORDINGS_ROOT"] = prev
    FileUtils.remove_entry(tmp) if tmp && File.directory?(tmp)
  end

  test "call : succès ffmpeg → .part écrit puis rename atomique vers le nom final" do
    tmp = Dir.mktmpdir("mux-atomic-ok")
    prev = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = tmp

    audio = make_track(source: "microphone", started_at: @t0, ended_at: @t0 + 2, path_suffix: ".ogg")
    write_fake_file(audio)

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity, ffmpeg_bin: "/bin/true",
                             prober: fake_prober(audio: "opus"))

    # Stub : matérialise le .part comme le ferait ffmpeg, puis rend OK.
    # Permet d'exercer le rename sans dépendre du binaire réel.
    captured_partial = nil
    mux.define_singleton_method(:ensure_binaries!) { nil }
    mux.define_singleton_method(:run_with_deadline) do |cmd, **_opts|
      captured_partial = cmd.last
      File.write(captured_partial, "fake-mp4")
      [ "", Struct.new(:success?, :exitstatus).new(true, 0) ]
    end

    result = mux.call
    final_abs = Recording.recordings_root.join(result.relative_path)
    assert File.file?(final_abs), "fichier final posé par rename atomique"
    assert_includes captured_partial.to_s, ".part-", "ffmpeg a écrit dans un .part-*, pas directement dans le nom final"
    assert_equal File.extname(final_abs), File.extname(captured_partial.to_s),
                 "le .part garde l'extension finale : ffmpeg en déduit le format de sortie"
    refute File.file?(captured_partial), ".part-* doit avoir été renommé"
    siblings = Dir.children(final_abs.dirname)
    assert_empty siblings.select { |c| c.include?(".part-") }, "aucun .part résiduel"
  ensure
    ENV["RECORDINGS_ROOT"] = prev
    FileUtils.remove_entry(tmp) if tmp && File.directory?(tmp)
  end
end
