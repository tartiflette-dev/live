require "test_helper"
require "open3"

# Fonctions pures du client de la file Q&R (app/javascript/rooms/qa_state.mjs)
# exécutées sous Node : rejet des paquets de participants, forme du bandeau,
# résumé des auteurs. Node est déjà requis par la CI (esbuild).
class QaStateTest < ActiveSupport::TestCase
  test "frontières de confiance et résumé des auteurs de la file Q&R" do
    output, status = Open3.capture2e("node", Rails.root.join("test/javascript/qa_state_test.mjs").to_s)
    assert status.success?, output
  end
end
