require "test_helper"
require "open3"

# Fonctions pures de la régie (regie_layout.mjs, clock_time.mjs) exécutées
# sous Node : chaque bloc rangé une fois à chaque moment, priorités du
# moment, heures au format 9:30.
class RegieLayoutTest < ActiveSupport::TestCase
  test "mise en page de la régie par moment et format des heures" do
    output, status = Open3.capture2e("node", Rails.root.join("test/javascript/regie_layout_test.mjs").to_s)
    assert status.success?, output
  end
end
