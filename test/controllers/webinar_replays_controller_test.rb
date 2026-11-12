require "test_helper"

# Replay côté animation : publier, retirer, statistiques nominatives —
# propriétaire et animateurs du projet seulement.
class WebinarReplaysControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("webinar-replays")
    ENV["RECORDINGS_ROOT"] = @tmp
    @webinar = ended_cafe
    @composite = add_recording(@webinar, kind: "composite", file: "seance.mp4")
    @owner = User.find_by!(oidc_sub: @webinar.host_sub)
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "le propriétaire publie puis retire le replay ; les statistiques restent" do
    sign_in_as(@owner, groups: [])

    get webinar_replay_path(@webinar)
    assert_select "[data-role=replay-publish]"

    post publish_webinar_replay_path(@webinar)
    assert_redirected_to webinar_replay_path(@webinar)
    replay = @webinar.reload.replay
    assert replay.published?
    assert_equal @composite, replay.recording

    replay.views.create!(registration: confirmed_registration(@webinar, "ines@example.test", name: "Inès"), session_key: session_key,
                         started_at: Time.current, last_seen_at: Time.current, watched_seconds: 120,
                         intervals: [ [ 0.0, 120.0 ] ])
    post unpublish_webinar_replay_path(@webinar)
    assert_not replay.reload.published?
    assert_equal 1, replay.views.count

    get webinar_replay_path(@webinar)
    assert_select "[data-role=replay-stats-row]", 1
    assert_select "[data-role=replay-stats]", /Inès/
    assert_select "[data-role=replay-stats]", /0:00–2:00/
    assert_select "[data-role=replay-stats]", /2 min 00 s/
  end

  test "direct pas terminé : publication refusée" do
    @webinar.update!(state: "live", ended_at: nil)
    sign_in_as(@owner, groups: [])

    post publish_webinar_replay_path(@webinar)
    assert_nil @webinar.reload.replay
    assert_match "Publication impossible", flash[:alert]
  end

  test "co-animateur invité : 404 (les statistiques nomment les personnes)" do
    guest = User.create!(email: "co@example.test", oidc_sub: "sub-co", email_verified: true, email_verified_for: "co@example.test")
    @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @owner.oidc_sub, claimed_sub: guest.oidc_sub)
    sign_in_as(guest, groups: [])

    get webinar_replay_path(@webinar)
    assert_response :not_found
    post publish_webinar_replay_path(@webinar)
    assert_response :not_found
    assert_nil @webinar.reload.replay
  end

  test "montage demandé avant publication : replay créé non publié, demande en file, état affiché" do
    sign_in_as(@owner, groups: [])

    get webinar_replay_path(@webinar)
    assert_select "[data-role=replay-montage-request]", text: "Monter le replay"

    post montage_webinar_replay_path(@webinar)
    assert_redirected_to webinar_replay_path(@webinar)
    assert_match "Montage demandé", flash[:notice]
    replay = @webinar.reload.replay
    assert_not replay.published?
    assert ReplayMontage.request_path_for(replay.id).exist?

    post montage_webinar_replay_path(@webinar)
    assert_equal "Rien de nouveau à monter.", flash[:notice]

    get webinar_replay_path(@webinar)
    assert_select "[data-role=replay-montage-state]", /rendu la nuit, jamais pendant un direct/
    assert_select "[data-role=replay-montage-request]", 0
  end

  test "montage adopté calé par estimation : la page le dit et invite à vérifier avant de publier" do
    replay = Replay.prepare!(@webinar)
    render_montage(replay, method: "estimé")
    ReplayMontage.new(replay).adopt!
    sign_in_as(@owner, groups: [])

    get webinar_replay_path(@webinar)

    assert_select "[data-role=replay-montage-state]", /lu depuis son montage/
    assert_select "[data-role=replay-montage-audio]", /Son calé par estimation/
  end

  test "nouveau montage en échec après un premier adopté : le replay reste sur sa copie actuelle" do
    replay = Replay.prepare!(@webinar)
    render_montage(replay, method: "mesuré")
    ReplayMontage.new(replay).adopt!
    @webinar.transcript_segments.create!(participant_identity: "host-x", text: "Une nouvelle phrase qui compte.",
                                         started_at: @composite.started_at + 10, ended_at: @composite.started_at + 20, segment_id: "s-1")
    render_montage(replay.reload, method: nil, status: "failed")
    sign_in_as(@owner, groups: [])

    get webinar_replay_path(@webinar)

    assert_select "[data-role=replay-montage-state]", /reste lu depuis sa copie de diffusion actuelle/
    assert_select "[data-role=replay-montage-audio]", 0
  end

  test "demande toujours pas rendue après une nuit : alerte visible" do
    replay = Replay.prepare!(@webinar)
    travel_to(2.days.ago) { ReplayMontage.new(replay).request! }
    sign_in_as(@owner, groups: [])

    get webinar_replay_path(@webinar)

    assert_select "[data-role=replay-montage-state]", /toujours pas rendu après une nuit/
  end

  test "montage : direct pas terminé, refusé ; co-animateur invité, 404" do
    @webinar.update!(state: "live", ended_at: nil)
    sign_in_as(@owner, groups: [])
    post montage_webinar_replay_path(@webinar)
    assert_match "Montage impossible", flash[:alert]
    assert_nil @webinar.reload.replay

    @webinar.update!(state: "ended", ended_at: Time.current)
    guest = User.create!(email: "co@example.test", oidc_sub: "sub-co", email_verified: true, email_verified_for: "co@example.test")
    @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @owner.oidc_sub, claimed_sub: guest.oidc_sub)
    sign_in_as(guest, groups: [])
    post montage_webinar_replay_path(@webinar)
    assert_response :not_found
    assert_nil @webinar.reload.replay
  end

  test "animateur du projet : accès à tout replay" do
    sign_in_as(User.create!(email: "anim@example.test", oidc_sub: "sub-anim"), groups: [ "live-animateurs" ])

    post publish_webinar_replay_path(@webinar)
    assert @webinar.reload.replay.published?
  end

  test "sondages : réponses du direct et du replay comptées séparément ; réponses courtes du replay nommées" do
    replay = Replay.publish!(@webinar)
    origin = replay.recording.started_at
    choice = @webinar.polls.create!(position: 1, kind: "choice", label: "Ça vous parle ?", options: %w[Oui Non],
                                    opened_at: origin + 60, closed_at: origin + 120)
    text = @webinar.polls.create!(position: 2, kind: "short_text", label: "Un mot ?", opened_at: origin + 200, closed_at: origin + 260)
    @webinar.polls.create!(position: 3, kind: "choice", label: "Jamais lancé", options: %w[A B])
    choice.responses.create!(respondent_identity: "viewer-900", name: "Direct", value: [ 0 ])
    ines = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
    choice.respond_from_replay!(viewer: ines, value: [ 1 ])
    choice.respond_from_replay!(viewer: spectator_user, value: [ 1 ])
    text.respond_from_replay!(viewer: ines, value: "Très clair")
    sign_in_as(@owner, groups: [])

    get webinar_replay_path(@webinar)

    assert_response :success
    assert_select "[data-role=replay-poll-results]", 2
    assert_select "[data-role=replay-poll-results][data-poll-id='#{choice.id}'] tbody tr" do |rows|
      assert_equal [ %w[Oui 1 0], %w[Non 0 2], %w[Personnes 1 2] ], rows.map { |row| row.css("th, td").map { |cell| cell.text.strip } }
    end
    assert_select "[data-role=replay-poll-results][data-poll-id='#{text.id}'] [data-role=replay-poll-respondents] td", text: "1", count: 1
    assert_select "[data-role=replay-poll-texts] li", text: /Inès\s*: Très clair/
  end

  private

  # Ce que fait le moteur de rendu externe pour une nouvelle demande
  # (docs/replays.md).
  def render_montage(replay, method:, status: "done")
    ReplayMontage.new(replay).request!
    request = JSON.parse(ReplayMontage.request_path_for(replay.id).read)
    output = Recording.recordings_root.join(request.fetch("output"))
    FileUtils.mkdir_p(output.dirname)
    output.write("vidéo montée") if status == "done"
    marker = { status: status, request_id: request["request_id"], audio: { method: method } }
    marker[:output_size] = output.size if status == "done"
    output.sub_ext(".mp4.json").write(marker.to_json)
  end
end
