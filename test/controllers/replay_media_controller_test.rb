require "test_helper"

# Vidéo et sous-titres du replay : contrôle d'accès de la page, requêtes
# Range ; derrière Thruster, le fichier part par X-Sendfile.
class ReplayMediaControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers

  BYTES = (0..99).map { |index| (index % 10).to_s }.join

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-media")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe(bytes: BYTES)
    @webinar = @replay.webinar
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "sans identité : ni vidéo ni sous-titres" do
    get public_webinar_replay_video_path(@webinar.slug)
    assert_response :not_found
    get public_webinar_replay_subtitles_path(@webinar.slug)
    assert_response :not_found
  end

  test "compte undust : la vidéo entière, puis une plage (206)" do
    sign_in_as(spectator_user, groups: [])

    get public_webinar_replay_video_path(@webinar.slug)
    assert_response :success
    assert_equal BYTES, response.body
    assert_equal "video/mp4", response.media_type
    assert_equal "private, no-store", response.headers["Cache-Control"]

    get public_webinar_replay_video_path(@webinar.slug), headers: { "Range" => "bytes=10-19" }
    assert_response :partial_content
    assert_equal BYTES[10..19], response.body
    assert_equal "bytes 10-19/100", response.headers["Content-Range"]

    get public_webinar_replay_video_path(@webinar.slug), headers: { "Range" => "bytes=90-" }
    assert_equal BYTES[90..], response.body

    get public_webinar_replay_video_path(@webinar.slug), headers: { "Range" => "bytes=500-600" }
    assert_response :range_not_satisfiable
  end

  # Thruster se connecte à Puma par la boucle locale, IPv4 ou IPv6 (y compris
  # sous la forme IPv4 mappée).
  [ "127.0.0.1", "::1", "::ffff:127.0.0.1" ].each do |peer|
    test "derrière Thruster (pair #{peer}) : en-tête X-Sendfile, aucun octet servi par l'application" do
      sign_in_as(spectator_user, groups: [])

      get public_webinar_replay_video_path(@webinar.slug), headers: { "X-Sendfile-Type" => "X-Sendfile",
                                                                     "Range" => "bytes=0-9" },
                                                            env: { "REMOTE_ADDR" => peer }

      assert_response :success
      assert_equal @replay.recording.absolute_path.to_s, response.headers["X-Sendfile"]
      assert_empty response.body
    end
  end

  test "en-tête X-Sendfile-Type posé par un pair distant : ignoré, aucun chemin divulgué" do
    sign_in_as(spectator_user, groups: [])

    get public_webinar_replay_video_path(@webinar.slug), headers: { "X-Sendfile-Type" => "X-Sendfile" },
                                                          env: { "REMOTE_ADDR" => "203.0.113.7" }

    assert_response :success
    assert_nil response.headers["X-Sendfile"]
    assert_equal BYTES, response.body
  end

  test "copie de diffusion présente : c'est elle qui est servie" do
    derived = "#{Replay::DERIVED_SUBDIR}/#{@webinar.slug}/diffusion.mp4"
    FileUtils.mkdir_p(File.join(@tmp, File.dirname(derived)))
    File.binwrite(File.join(@tmp, derived), "copie-720p")
    @replay.update!(derived_path: derived)
    sign_in_as(spectator_user, groups: [])

    get public_webinar_replay_video_path(@webinar.slug)
    assert_equal "copie-720p", response.body
  end

  test "fichier disparu : 404" do
    File.delete(@replay.recording.absolute_path)
    sign_in_as(spectator_user, groups: [])

    get public_webinar_replay_video_path(@webinar.slug)
    assert_response :not_found
  end

  test "inscrit au replay ouvert : sous-titres WebVTT calés sur la vidéo" do
    add_segment(@webinar, "Bonjour <tous>", at: @replay.recording.started_at + 60)
    registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
    post public_webinar_replay_access_path(@webinar.slug), params: { t: registration.token }

    get public_webinar_replay_subtitles_path(@webinar.slug)

    assert_response :success
    assert_equal "text/vtt", response.media_type
    assert_includes response.body, "00:01:00.000 --> 00:01:03.000\n<v Basile Delmas>Bonjour &lt;tous&gt;"
  end

  test "replay non publié : 404 pour un spectateur, servi à l'animation" do
    @replay.unpublish!
    sign_in_as(spectator_user, groups: [])
    get public_webinar_replay_video_path(@webinar.slug)
    assert_response :not_found

    sign_in_as(User.find_by!(oidc_sub: @webinar.host_sub), groups: [])
    get public_webinar_replay_video_path(@webinar.slug)
    assert_response :success
  end
end
