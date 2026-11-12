# frozen_string_literal: true

require "test_helper"
require "open3"

# TrackProbe — ffprobe RÉEL sur de petits fichiers générés par ffmpeg.
# SKIP PROPRE si ffmpeg/ffprobe sont absents (installés en CI et dans l'image).
class TrackProbeTest < ActiveSupport::TestCase
  setup do
    tools = %w[ffmpeg ffprobe].all? { |bin| system(bin, "-version", out: File::NULL, err: File::NULL) }
    skip "ffmpeg/ffprobe absents" unless tools
    @dir = Pathname.new(Dir.mktmpdir("track-probe"))
    @probe = TrackProbe.new
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  test "renvoie le codec et le nombre de paquets d'une caméra VP8" do
    cam = generate(@dir.join("cam.webm"), "testsrc=duration=2:size=320x240:rate=25", "-c:v", "libvpx")

    info = @probe.call(cam, "video")

    assert_equal "vp8", info.codec
    assert_equal 50, info.packets
  end

  test "renvoie le codec d'un micro Opus" do
    mic = generate(@dir.join("mic.ogg"), "sine=frequency=440:duration=2", "-c:a", "libopus")

    info = @probe.call(mic, "audio")

    assert_equal "opus", info.codec
    assert_operator info.packets, :>, 0
  end

  test "nil quand le fichier n'a pas de flux du type demandé" do
    mic = generate(@dir.join("mic.ogg"), "sine=frequency=440:duration=1", "-c:a", "libopus")

    assert_nil @probe.call(mic, "video")
  end

  test "nil pour un fichier vide ou absent" do
    empty = @dir.join("vide.webm")
    File.binwrite(empty, "")

    assert_nil @probe.call(empty, "video")
    assert_nil @probe.call(@dir.join("absent.webm"), "video")
  end

  test "sonde interrompue par le délai : Interrupted, pas nil (une piste saine n'est pas écartée)" do
    cam = generate(@dir.join("cam.webm"), "testsrc=duration=1:size=320x240:rate=25", "-c:v", "libvpx")
    slow = fake_ffprobe("slow", "sleep 10")

    error = assert_raises(TrackProbe::Interrupted) { TrackProbe.new(ffprobe_bin: slow, timeout: 1).call(cam, "video") }
    assert_match(/rc=124/, error.message)
  end

  test "sonde tuée par un signal : Interrupted" do
    cam = generate(@dir.join("cam.webm"), "testsrc=duration=1:size=320x240:rate=25", "-c:v", "libvpx")
    killed = fake_ffprobe("killed", "kill -9 $$")

    assert_raises(TrackProbe::Interrupted) { TrackProbe.new(ffprobe_bin: killed).call(cam, "video") }
  end

  test "binaire inexécutable : Interrupted" do
    cam = generate(@dir.join("cam.webm"), "testsrc=duration=1:size=320x240:rate=25", "-c:v", "libvpx")

    assert_raises(TrackProbe::Interrupted) { TrackProbe.new(ffprobe_bin: "/nonexistent/ffprobe").call(cam, "video") }
  end

  private

  # Faux ffprobe : un script shell qui exécute `body`.
  def fake_ffprobe(name, body)
    path = @dir.join(name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path.to_s
  end

  def generate(path, lavfi_source, *codec_args)
    _out, err, status = Open3.capture3("ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                                       "-f", "lavfi", "-i", lavfi_source, *codec_args, "-t", "2", path.to_s)
    raise "ffmpeg: #{err}" unless status.success?
    path
  end
end
