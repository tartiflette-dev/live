# frozen_string_literal: true

require "test_helper"
require "open3"

# ParticipantMux — test d'intégration ffmpeg + ffprobe RÉELS. Génère des
# sources synthétiques (lavfi testsrc 2 s en H.264, VP8 ou VP9 + sine 2 s
# en Opus, décalé de 0,5 s), exécute le mux, vérifie conteneur, codecs et
# flux du résultat ; couvre aussi les pistes vides.
#
# SKIP PROPRE si ffmpeg n'est pas disponible localement. L'image de
# l'application l'installe (Dockerfile).
class ParticipantMuxFfmpegTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    skip "ffmpeg absent — test exécuté là où ffmpeg est installé" unless ffmpeg_available?

    @tmp_root = Pathname.new(Dir.mktmpdir("mux-ffmpeg-test"))
    @prev_root = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = @tmp_root.to_s

    @webinar = Webinar.create!(
      title:     "Mux ffmpeg",
      slug:      "mux-ff-#{SecureRandom.hex(3)}",
      starts_at: 1.hour.ago,
      host_sub:  "host-ff-#{SecureRandom.hex(3)}",
      room_name: "room-ff-#{SecureRandom.hex(3)}",
      state:     "ended",
      kind:      "cafe_ia"
    )
    @identity = "speaker-ff"
    @t0 = Time.utc(2026, 10, 7, 12, 0, 0)
  end

  teardown do
    # Tests non transactionnels : nettoyage explicite, sinon les lignes
    # fuient vers les autres tests (delete_all : pas de restrict_with_error).
    if @webinar
      Recording.where(webinar_id: @webinar.id).delete_all
      Webinar.where(id: @webinar.id).delete_all
    end
    ENV["RECORDINGS_ROOT"] = @prev_root
    FileUtils.remove_entry(@tmp_root) if @tmp_root && File.directory?(@tmp_root)
  end

  test "mux réel : testsrc 2 s + sine décalé 0,5 s → .mp4 avec vidéo+audio" do
    video_rel = "#{@webinar.slug}/cam.mp4"
    audio_rel = "#{@webinar.slug}/mic.ogg"
    generate_video(@tmp_root.join(video_rel))
    generate_audio(@tmp_root.join(audio_rel))

    video = Recording.create!(
      webinar: @webinar, kind: "track", status: "done",
      participant_identity: @identity, track_source: "camera",
      started_at: @t0, ended_at: @t0 + 2, path: video_rel
    )
    audio = Recording.create!(
      webinar: @webinar, kind: "track", status: "done",
      participant_identity: @identity, track_source: "microphone",
      started_at: @t0 + 0.5, ended_at: @t0 + 2.5, path: audio_rel
    )
    assert video.downloadable?
    assert audio.downloadable?

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity)
    result = mux.call

    assert_equal ".mp4", result.extension
    # Sortie SOUS participants/<slug>/, dossier
    # créé par Rails (UID 1000, mode 0750) — pas par l'egress (UID 1001).
    assert result.relative_path.start_with?("_participants/#{@webinar.slug}/"),
      "sortie attendue sous participants/<slug>/ ; obtenue : #{result.relative_path}"
    out_abs = Recording.recordings_root.join(result.relative_path)
    assert File.file?(out_abs), "sortie ffmpeg présente sur disque"
    assert File.size(out_abs) > 1_000, "fichier non vide"

    # Pas de résidu `.part-*` à côté (écriture atomique).
    residues = Dir.children(out_abs.dirname).grep(/\.part-/)
    assert_empty residues, "aucun fichier .part-* résiduel attendu, obtenu : #{residues.inspect}"

    streams = probe_streams(out_abs)
    types = streams.map { |s| s["codec_type"] }
    assert_includes types, "video"
    assert_includes types, "audio"

    video_stream = streams.find { |s| s["codec_type"] == "video" }
    assert_equal "h264", video_stream["codec_name"], "vidéo recopiée sans réencodage"
    audio_stream = streams.find { |s| s["codec_type"] == "audio" }
    assert_equal "aac", audio_stream["codec_name"], "Opus → AAC"

    # Le Recording synthétique construit à partir de ce chemin passe la
    # garde Recording#absolute_path (préfixe participants/<slug>/).
    rec = @webinar.recordings.create!(
      kind: :participant, status: :done, participant_identity: @identity,
      started_at: @t0, ended_at: @t0 + 2, path: result.relative_path
    )
    assert_equal out_abs.cleanpath, rec.absolute_path
    assert rec.downloadable?, "le Recording participant doit être downloadable"
  end

  # Cas réel : la caméra d'un intervenant est enregistrée en VP8
  # (.webm) ; mp4 refuse VP8 (« Could not find tag for codec vp8 »).
  test "mux réel : caméra VP8 (.webm) + micro Opus (.ogg) → .webm, VP8 et Opus recopiés" do
    mux_result = mux_tracks(video_codec: "libvpx", video_ext: ".webm")

    assert_equal ".webm", mux_result.extension
    assert_equal "video/webm", mux_result.content_type
    assert_equal "camera+microphone", mux_result.track_source
    assert_nil mux_result.note
    streams = probe_streams(Recording.recordings_root.join(mux_result.relative_path))
    assert_equal "vp8",  streams.find { |s| s["codec_type"] == "video" }["codec_name"]
    assert_equal "opus", streams.find { |s| s["codec_type"] == "audio" }["codec_name"]
  end

  test "mux réel : caméra VP9 (.webm) + micro Opus → .webm, VP9 recopié" do
    mux_result = mux_tracks(video_codec: "libvpx-vp9", video_ext: ".webm")

    assert_equal ".webm", mux_result.extension
    streams = probe_streams(Recording.recordings_root.join(mux_result.relative_path))
    assert_equal "vp9", streams.find { |s| s["codec_type"] == "video" }["codec_name"]
  end

  test "mux réel : caméra VP8 vide (0 octet) + micro valide → montage audio seul .m4a, note explicite" do
    mux_result = mux_tracks(video_codec: nil, video_ext: ".webm")

    assert_equal ".m4a", mux_result.extension
    assert_equal "microphone", mux_result.track_source
    assert_match(/caméra \(piste \d+\) écartée : aucune image exploitable/, mux_result.note)
    streams = probe_streams(Recording.recordings_root.join(mux_result.relative_path))
    assert_equal [ "audio" ], streams.map { |s| s["codec_type"] }
  end

  test "mux réel : caméra .webm tronquée avant son premier paquet (illisible) + micro valide → audio seul" do
    mux_result = mux_tracks(video_codec: "libvpx", video_ext: ".webm", truncate_video_to: 200)

    assert_equal ".m4a", mux_result.extension
    assert_match(/aucune image exploitable/, mux_result.note)
  end

  test "mux réel : micro vide + caméra VP8 valide → vidéo seule .webm, note explicite" do
    mux_result = mux_tracks(video_codec: "libvpx", video_ext: ".webm", audio_empty: true)

    assert_equal ".webm", mux_result.extension
    assert_equal "camera", mux_result.track_source
    assert_match(/micro \(piste \d+\) écartée : aucun son exploitable/, mux_result.note)
    streams = probe_streams(Recording.recordings_root.join(mux_result.relative_path))
    assert_equal [ "video" ], streams.map { |s| s["codec_type"] }
  end

  test "mux réel : toutes les pistes vides → NothingToMux avec la raison, aucun fichier" do
    error = assert_raises(ParticipantMux::NothingToMux) do
      mux_tracks(video_codec: nil, video_ext: ".webm", audio_empty: true)
    end
    assert_match(/caméra \(piste \d+\) écartée/, error.message)
    assert_match(/micro \(piste \d+\) écartée/, error.message)
  end

  # Retour de review : `-shortest` tronquait le montage à la durée
  # de la piste la plus courte (caméra de 2 s + micro de 6 s → 2 s).
  test "mux réel : caméra courte (2 s) + micro long (6 s) → le montage garde les 6 s de son" do
    video_rel = "#{@webinar.slug}/cam-short.webm"
    audio_rel = "#{@webinar.slug}/mic-long.ogg"
    generate_video(@tmp_root.join(video_rel), codec: "libvpx")
    generate_audio(@tmp_root.join(audio_rel), seconds: 6)
    Recording.create!(webinar: @webinar, kind: "track", status: "done", participant_identity: @identity,
                      track_source: "camera", started_at: @t0, ended_at: @t0 + 2, path: video_rel)
    Recording.create!(webinar: @webinar, kind: "track", status: "done", participant_identity: @identity,
                      track_source: "microphone", started_at: @t0, ended_at: @t0 + 6, path: audio_rel)

    mux_result = ParticipantMux.new(webinar: @webinar, identity: @identity).call

    assert_equal ".webm", mux_result.extension
    assert_in_delta 6.0, probe_duration(Recording.recordings_root.join(mux_result.relative_path)), 0.3
  end

  # Constat en direct : le fichier caméra commence à la première image clé, après
  # le premier son. Le montage doit placer la première image à ce décalage,
  # sans réencoder la vidéo.
  test "mux réel : la vidéo commence à son début de fichier réel, l'audio à 0" do
    video_rel = "#{@webinar.slug}/cam-late.mp4"
    audio_rel = "#{@webinar.slug}/mic-early.ogg"
    generate_video(@tmp_root.join(video_rel))
    generate_audio(@tmp_root.join(audio_rel), seconds: 3)
    Recording.create!(webinar: @webinar, kind: "track", status: "done", participant_identity: @identity,
                      track_source: "camera", started_at: @t0, ended_at: @t0 + 3, media_started_at: @t0 + 1.9,
                      path: video_rel)
    Recording.create!(webinar: @webinar, kind: "track", status: "done", participant_identity: @identity,
                      track_source: "microphone", started_at: @t0, ended_at: @t0 + 3, media_started_at: @t0 + 1.1,
                      path: audio_rel)

    result = ParticipantMux.new(webinar: @webinar, identity: @identity).call

    assert_nil result.note
    streams = probe_streams(Recording.recordings_root.join(result.relative_path))
    video = streams.find { |stream| stream["codec_type"] == "video" }
    audio = streams.find { |stream| stream["codec_type"] == "audio" }
    assert_equal "h264", video["codec_name"], "vidéo recopiée"
    assert_in_delta 0.8 - ParticipantMux::VIDEO_ACTIVATION_LAG, video["start_time"].to_f, 0.045
    assert_in_delta 0.0, audio["start_time"].to_f, 0.03
  end

  test "mux audio seul (pas de vidéo caméra) → .m4a aac" do
    audio_rel = "#{@webinar.slug}/mic-only.ogg"
    generate_audio(@tmp_root.join(audio_rel))

    Recording.create!(
      webinar: @webinar, kind: "track", status: "done",
      participant_identity: @identity, track_source: "microphone",
      started_at: @t0, ended_at: @t0 + 2, path: audio_rel
    )

    mux = ParticipantMux.new(webinar: @webinar, identity: @identity)
    result = mux.call

    assert_equal ".m4a", result.extension
    out_abs = Recording.recordings_root.join(result.relative_path)
    assert File.file?(out_abs)

    streams = probe_streams(out_abs)
    assert_equal [ "audio" ], streams.map { |s| s["codec_type"] }
    assert_equal "aac", streams.first["codec_name"]
  end

  private

  # Crée une caméra (codec ffmpeg `video_codec`, nil = fichier vide de 0
  # octet) + un micro Opus sous @tmp_root, les enregistre en `done` et
  # exécute le mux réel. `truncate_video_to` garde les N premiers octets
  # du fichier vidéo (en-tête sans paquet) ; `audio_empty` vide le micro.
  def mux_tracks(video_codec:, video_ext:, truncate_video_to: nil, audio_empty: false)
    video_rel = "#{@webinar.slug}/cam#{video_ext}"
    audio_rel = "#{@webinar.slug}/mic.ogg"
    video_abs = @tmp_root.join(video_rel)
    audio_abs = @tmp_root.join(audio_rel)
    FileUtils.mkdir_p(video_abs.dirname)
    if video_codec
      generate_video(video_abs, codec: video_codec)
      File.truncate(video_abs, truncate_video_to) if truncate_video_to
    else
      File.binwrite(video_abs, "")
    end
    audio_empty ? File.binwrite(audio_abs, "") : generate_audio(audio_abs)

    Recording.create!(
      webinar: @webinar, kind: "track", status: "done",
      participant_identity: @identity, track_source: "camera",
      started_at: @t0, ended_at: @t0 + 2, media_started_at: @t0 + 1.2, path: video_rel
    )
    Recording.create!(
      webinar: @webinar, kind: "track", status: "done",
      participant_identity: @identity, track_source: "microphone",
      started_at: @t0 + 0.5, ended_at: @t0 + 2.5, media_started_at: @t0 + 0.6, path: audio_rel
    )
    ParticipantMux.new(webinar: @webinar, identity: @identity).call
  end

  def ffmpeg_available?
    system(ENV.fetch("FFMPEG_BIN", "ffmpeg"), "-version", out: File::NULL, err: File::NULL)
  end

  def generate_video(path, codec: "libx264")
    FileUtils.mkdir_p(File.dirname(path))
    cmd = [ "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25",
            "-c:v", codec, "-pix_fmt", "yuv420p", "-t", "2",
            path.to_s ]
    _o, e, s = Open3.capture3(*cmd)
    raise "generate_video failed: #{e}" unless s.success?
  end

  def generate_audio(path, seconds: 2)
    FileUtils.mkdir_p(File.dirname(path))
    cmd = [ "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=#{seconds}",
            "-c:a", "libopus", "-b:a", "64k",
            path.to_s ]
    _o, e, s = Open3.capture3(*cmd)
    raise "generate_audio failed: #{e}" unless s.success?
  end

  def probe_duration(path)
    out, _e, s = Open3.capture3("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path.to_s)
    raise "ffprobe failed" unless s.success?
    out.to_f
  end

  def probe_streams(path)
    cmd = [ "ffprobe", "-v", "error", "-print_format", "json", "-show_streams", path.to_s ]
    out, _e, s = Open3.capture3(*cmd)
    raise "ffprobe failed" unless s.success?
    JSON.parse(out).fetch("streams")
  end
end
