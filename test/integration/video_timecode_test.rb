require "test_helper"
require "open3"

# Instant d'une vidéo côté client (app/javascript/rooms/video_timecode.mjs),
# exécuté sous Node : la question du replay et la file Q&R de la régie
# l'affichent comme le serveur (ReplaysHelper#replay_timecode).
class VideoTimecodeTest < ActiveSupport::TestCase
  test "instants de la vidéo : minutes, heures, valeurs absentes ou négatives" do
    output, status = Open3.capture2e("node", Rails.root.join("test/javascript/video_timecode_test.mjs").to_s)
    assert status.success?, output
  end
end
