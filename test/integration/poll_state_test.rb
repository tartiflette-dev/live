require "test_helper"
require "open3"

# Fonctions pures du client des sondages (app/javascript/rooms/poll_state.mjs)
# exécutées sous Node : rejet des paquets de participants et des schémas
# inattendus, instantané le plus récent gagnant, pourcentages.
class PollStateTest < ActiveSupport::TestCase
  test "frontières de confiance, ordre des instantanés et pourcentages du client des sondages" do
    output, status = Open3.capture2e("node", Rails.root.join("test/javascript/poll_state_test.mjs").to_s)
    assert status.success?, output
  end
end
