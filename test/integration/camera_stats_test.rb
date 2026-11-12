require "test_helper"
require "open3"

# Mesure caméra exécutée sous Node : couches lues dans getStats, mesure au
# contrat CameraSample, décision du repli sans simulcast (camera_stats.mjs),
# puis relevé et repli unique avec un participant LiveKit simulé
# (camera_monitor.mjs).
class CameraStatsTest < ActiveSupport::TestCase
  test "lecture des couches, mesure et décision du repli sans simulcast" do
    output, status = Open3.capture2e("node", Rails.root.join("test/javascript/camera_stats_test.mjs").to_s)
    assert status.success?, output
  end

  test "un seul repli par entrée dans la salle, jugé 10 s après la publication, échec rétabli" do
    output, status = Open3.capture2e("node", Rails.root.join("test/javascript/camera_monitor_test.mjs").to_s)
    assert status.success?, output
  end
end
