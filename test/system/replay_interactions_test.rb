require "application_system_test_case"

# Replay interactif dans un vrai navigateur : le sondage du direct paraît
# à son instant sur la vidéo, l'inscrit y répond et voit le résultat direct
# + replay ; il pose une question ancrée à l'instant de la vidéo, qui
# rejoint la file du café.
class ReplayInteractionsTest < JsSystemTestCase
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-interactions")
    ENV["RECORDINGS_ROOT"] = @tmp
    FileUtils.rm_rf(Pathname.new(RegistrationRateLimitStore.storage_root).join("replay_interaction_rate_limits"))
    @webinar = ended_cafe
    started = Time.zone.parse("2030-01-17 09:31:06")
    recording = add_recording(@webinar, kind: "composite", file: "seance.webm", bytes: nil, started: started, ended: started + 8)
    encode_test_video(recording.absolute_path, seconds: 8)
    Replay.publish!(@webinar)
    @poll = @webinar.polls.create!(position: 1, kind: "choice", label: "Ça vous parle ?", options: %w[Oui Non],
                                   opened_at: started + 2, closed_at: started + 4)
    @poll.responses.create!(respondent_identity: "viewer-900", name: "Au direct", value: [ 0 ])
    @registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  test "le sondage paraît à son instant, la réponse part du replay ; la question est ancrée à l'instant de la vidéo" do
    visit public_webinar_replay_path(@webinar.slug, t: @registration.token)
    click_button "Regarder le replay"
    assert_no_selector "[data-replay-poll-id]"

    page.execute_script("const video = document.querySelector('video'); video.muted = true; video.currentTime = 3;")
    within "[data-replay-poll-id='#{@poll.id}']" do
      assert_text "Ça vous parle ?"
      choose "Non"
    end
    # Sondage saisi : la carte reste après la fin de son créneau (0:04).
    page.execute_script("document.querySelector('video').currentTime = 5;")
    assert_equal 5, page.evaluate_script("Math.round(document.querySelector('video').currentTime)")
    within "[data-replay-poll-id='#{@poll.id}']" do
      click_button "Répondre"
      assert_selector "[data-replay-poll-answered=replay]", text: "Ta réponse, dans le replay : Non"
      assert_text "Oui : 50 % (1)"
      assert_text "2 réponses : 1 pendant le direct, 1 dans le replay."
    end
    assert_equal [ [ "live", [ 0 ] ], [ "replay", [ 1 ] ] ], @poll.responses.order(:id).pluck(:origin, :value)

    fill_in "replay-question-texte", with: "Et pour les PME ?"
    assert_selector "[data-replay-question-instant]", text: "0:05"
    page.execute_script("document.querySelector('video').currentTime = 7;")
    click_button "Envoyer la question"
    assert_selector "[data-replay-question-status]", text: "Question envoyée aux animateurs (à 0:05 de la vidéo)."
    item = QaItem.sole
    assert_equal [ "replay", "Et pour les PME ?", @registration ], [ item.source, item.label, item.registration ]
    assert_in_delta 5.0, item.video_position, 0.5

    click_button "Masquer"
    assert_no_selector "[data-replay-poll-id]"
    page.execute_script("document.querySelector('video').currentTime = 3;")
    assert_no_selector "[data-replay-poll-id]"
  end

  private

  # VP8/WebM : lu par tout Chromium, même sans les codecs propriétaires.
  def encode_test_video(path, seconds:)
    FileUtils.mkdir_p(path.dirname)
    ok = system("ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=#{seconds}:size=160x120:rate=10",
                "-c:v", "libvpx", "-b:v", "200k", path.to_s)
    assert ok, "ffmpeg doit produire la vidéo de test"
  end
end
