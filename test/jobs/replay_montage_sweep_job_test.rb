require "test_helper"

# Adoption des montages rendus de nuit : un montage fini devient la copie de
# diffusion, une demande en attente reste, une demande orpheline part.
class ReplayMontageSweepJobTest < ActiveJob::TestCase
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-montage-sweep")
    ENV["RECORDINGS_ROOT"] = @tmp
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  test "montage fini adopté, demande en attente gardée, demande sans replay retirée" do
    finished = replay_cafe
    pending = replay_cafe
    ReplayMontage.new(finished).request!
    ReplayMontage.new(pending).request!
    render(finished)
    orphan = ReplayMontage.request_path_for(finished.id + pending.id + 100)
    orphan.write("{}")
    stray = Recording.recordings_root.join(ReplayMontage::QUEUE_DIR, "pas-un-id.json")
    stray.write("{}")

    ReplayMontageSweepJob.perform_now

    assert_equal ReplayMontage.new(finished).output_relative, finished.reload.derived_path
    assert_nil pending.reload.derived_path
    assert ReplayMontage.request_path_for(pending.id).exist?
    assert_not ReplayMontage.request_path_for(finished.id).exist?
    assert_not orphan.exist?
    assert stray.exist?, "un nom qui n'est pas un identifiant n'est pas touché"
  end

  private

  # Ce que fait le moteur de rendu externe pour la demande en file
  # (docs/replays.md).
  def render(replay)
    request = JSON.parse(ReplayMontage.request_path_for(replay.id).read)
    output = Recording.recordings_root.join(request.fetch("output"))
    FileUtils.mkdir_p(output.dirname)
    output.write("vidéo montée")
    output.sub_ext(".mp4.json").write({ status: "done", request_id: request["request_id"], output_size: output.size }.to_json)
  end
end
