require "application_system_test_case"

# Lecteur de replay dans un vrai navigateur : la vidéo (servie par plages)
# se lit, la pause envoie un battement crédité à l'inscription, les
# sous-titres s'affichent et se masquent au bouton.
class ReplayPlayerTest < JsSystemTestCase
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-player")
    ENV["RECORDINGS_ROOT"] = @tmp
    @webinar = ended_cafe
    started = Time.zone.parse("2030-01-17 09:31:06")
    recording = add_recording(@webinar, kind: "composite", file: "seance.webm", bytes: nil,
                                        started: started, ended: started + 6)
    encode_test_video(recording.absolute_path, seconds: 6)
    add_segment(@webinar, "Bienvenue au café", at: started)
    Replay.publish!(@webinar)
    @registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  test "lecture puis pause : battement crédité ; sous-titres au bouton" do
    visit public_webinar_replay_path(@webinar.slug, t: @registration.token)
    click_button "Regarder le replay"
    assert_selector "video[data-role=replay-video]"

    page.execute_script(<<~JS)
      const video = document.querySelector("video");
      video.muted = true;
      video.play();
    JS
    wait_until("la vidéo doit avancer au-delà de 2 s") { page.evaluate_script("document.querySelector('video').currentTime") > 2 }
    page.execute_script("document.querySelector('video').pause()")

    view = wait_for_view
    assert_equal @registration, view.registration
    assert_operator view.watched_seconds, :>, 1.5
    assert_equal 0.0, view.intervals.first.first.floor

    button = find("[data-replay-subtitles]")
    assert_equal "false", button["aria-pressed"]
    button.click
    assert_selector "[data-replay-subtitles][aria-pressed=true]", text: "Masquer les sous-titres"
    assert_equal "showing", page.evaluate_script("document.querySelector('video').textTracks[0].mode")
    find("[data-replay-subtitles]").click
    assert_equal "hidden", page.evaluate_script("document.querySelector('video').textTracks[0].mode")
  end

  private

  # VP8/WebM : lu par tout Chromium, même sans les codecs propriétaires.
  def encode_test_video(path, seconds:)
    FileUtils.mkdir_p(path.dirname)
    ok = system("ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=#{seconds}:size=160x120:rate=10",
                "-c:v", "libvpx", "-b:v", "200k", path.to_s)
    assert ok, "ffmpeg doit produire la vidéo de test"
  end

  # Sondage côté Ruby, délai large : plusieurs navigateurs en parallèle en CI
  # ralentissent le décodage et l'envoi du battement.
  def wait_until(message, timeout: 30)
    deadline = Time.now + timeout
    until yield
      flunk message if Time.now > deadline
      sleep 0.2
    end
  end

  def wait_for_view
    wait_until("un battement doit avoir été reçu") { ReplayView.exists? }
    ReplayView.first
  end
end
