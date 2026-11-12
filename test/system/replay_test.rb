require "application_system_test_case"

# Parcours des replays sans JavaScript : l'inscrit ouvre le replay de son
# café par son lien personnel, le compte undust voit la liste de tous.
class ReplayTest < ApplicationSystemTestCase
  include OidcSignIn
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-system")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    @webinar.update!(topic: "L'IA au bureau", announced_speakers: [ "Ada", "Grace" ])
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "inscrit : lien personnel, bouton, lecteur et invitation à créer un compte" do
    registration = confirmed_registration(@webinar, "ines@example.test", name: "Inès")

    visit public_webinar_replay_path(@webinar.slug, t: registration.token)
    click_button "Regarder le replay"

    assert_current_path public_webinar_replay_path(@webinar.slug)
    assert_selector "video[data-role=replay-video]"
    assert_text "L'IA au bureau"
    assert_text "Ada et Grace"
    assert_selector "[data-role=replay-account-invitation]", text: "Tous les replays avec un compte Studio Exemple"

    click_link "Tous les replays"
    assert_selector "[data-replay='#{@webinar.slug}']"
  end

  test "compte spectateur : connexion depuis le replay, retour au lecteur, liste des replays" do
    visit public_webinar_replay_path(@webinar.slug)
    assert_selector "[data-role=replay-sign-in-page]"

    sign_in_as(spectator_user, groups: [ "live-spectateurs" ])

    assert_current_path public_webinar_replay_path(@webinar.slug)
    assert_selector "video[data-role=replay-video]"
    assert_no_selector "[data-role=replay-account-invitation]"

    click_link "Replays", match: :first
    assert_selector "[data-replay='#{@webinar.slug}']", text: "L'IA au bureau"
  end

  test "animateur : demande le montage, le voit en attente, puis le replay est lu depuis le montage" do
    sign_in_as(User.find_by!(oidc_sub: @webinar.host_sub), groups: [])
    visit webinar_replay_path(@webinar)

    click_button "Monter le replay"

    assert_text "Montage demandé : il sera rendu cette nuit, hors direct."
    assert_selector "[data-role=replay-montage-state]", text: "rendu la nuit, jamais pendant un direct"
    assert_no_button "Monter le replay"

    render_requested_montage
    ReplayMontageSweepJob.perform_now
    visit webinar_replay_path(@webinar)

    assert_selector "[data-role=replay-montage-state]", text: "lu depuis son montage"
    assert_selector "[data-role=replay-reference]", text: "lue depuis sa copie de diffusion"
    assert_button "Refaire le montage"
  end

  private

  # Ce que fait le moteur de rendu externe pour la demande en file
  # (docs/replays.md).
  def render_requested_montage
    request = JSON.parse(ReplayMontage.request_path_for(@replay.id).read)
    output = Recording.recordings_root.join(request.fetch("output"))
    FileUtils.mkdir_p(output.dirname)
    output.write("vidéo montée")
    output.sub_ext(".mp4.json").write({ status: "done", request_id: request["request_id"], output_size: output.size }.to_json)
  end
end
