require "test_helper"
require "open3"

# Fonctions pures du client de discussion (app/javascript/rooms/chat_state.mjs)
# exécutées sous Node : rejet des paquets de participants, fusion ordonnée,
# curseur de rattrapage, non-lus. Node est déjà requis par la CI (esbuild).
class ChatStateTest < ActiveSupport::TestCase
  test "frontières de confiance, fusion, curseur et non-lus du client de discussion" do
    output, status = Open3.capture2e("node", Rails.root.join("test/javascript/chat_state_test.mjs").to_s)
    assert status.success?, output
  end
end
