require "application_system_test_case"

# Navigation dans les replays, dans un vrai navigateur : une recherche mène
# au lecteur à l'instant exact du passage ; les chapitres (liste et repères)
# font sauter la vidéo ; le chapitre en cours est signalé.
class ReplayNavigationTest < JsSystemTestCase
  include ReplayHelpers
  include ChapterHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-navigation")
    ENV["RECORDINGS_ROOT"] = @tmp
    @webinar = ended_cafe
    started = Time.zone.parse("2030-01-17 09:31:06")
    recording = add_recording(@webinar, kind: "composite", file: "seance.webm", bytes: nil, started: started, ended: started + 20)
    encode_test_video(recording.absolute_path, seconds: 20)
    @replay = Replay.publish!(@webinar)
    segment(@webinar, "09:31:18", "Le videur de boîte laisse passer les agents")
    chapters_for(@webinar, [ [ "09:31:06", "Accueil", [ "accueil" ] ], [ "09:31:16", "Le videur de boîte", [ "agents" ] ] ])
    ReplaySearchIndex.refresh(@webinar)
    @registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  test "recherche → lien → lecteur à l'instant ; chapitres et repères font sauter la vidéo" do
    visit public_webinar_replay_path(@webinar.slug, t: @registration.token)
    click_button "Regarder le replay"
    assert_selector "[data-role=replay-chapter]", count: 2

    visit replays_path
    fill_in "Chercher dans les replays", with: "videur"
    click_button "Chercher"
    assert_selector "[data-role=replay-search-hit] mark", text: "videur"
    find("[data-role=replay-search-link]", text: "Transcription").click

    assert_current_path public_webinar_replay_path(@webinar.slug, instant: 12)
    wait_until("la vidéo doit s'ouvrir à 0:12") { current_time.between?(11.5, 12.5) }
    assert_selector "[data-role=replay-chapter][aria-current=true]", text: "Le videur de boîte"

    page.execute_script("document.querySelector('video').muted = true")
    find("[data-role=replay-chapter] button", text: "Accueil").click
    wait_until("le chapitre « Accueil » ramène au début") { current_time < 3 }
    assert_selector "[data-role=replay-chapter][aria-current=true]", text: "Accueil"

    page.execute_script("document.querySelector('video').pause()")
    markers = all(".replay-repere", count: 2)
    markers.last.click
    wait_until("le repère du second chapitre mène à 0:10") { current_time.between?(9.5, 12) }
  end

  private

  def current_time
    page.evaluate_script("document.querySelector('video').currentTime")
  end

  # VP8/WebM : lu par tout Chromium, même sans les codecs propriétaires
  # (même recette que ReplayPlayerTest).
  def encode_test_video(path, seconds:)
    FileUtils.mkdir_p(path.dirname)
    ok = system("ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=#{seconds}:size=160x120:rate=10",
                "-c:v", "libvpx", "-b:v", "200k", path.to_s)
    assert ok, "ffmpeg doit produire la vidéo de test"
  end

  def wait_until(message, timeout: 30)
    deadline = Time.now + timeout
    until yield
      flunk message if Time.now > deadline
      sleep 0.2
    end
  end
end
