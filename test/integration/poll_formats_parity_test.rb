require "test_helper"
require "open3"

# Un type de question existe partout ou nulle part : Poll::KINDS (enum),
# les formats Ruby (Poll::Format::FORMATS) et la table FORMATS du client
# (poll_state.mjs) portent les mêmes clés. Ajouter un type sans son
# descripteur client fait rougir ce test.
class PollFormatsParityTest < ActiveSupport::TestCase
  MODULE_PATH = Rails.root.join("app/javascript/rooms/poll_state.mjs").to_s.freeze

  test "mêmes types dans l'enum, les formats Ruby et les formats du client" do
    script = <<~JS
      import { pathToFileURL } from "node:url";
      const { FORMATS } = await import(pathToFileURL(process.argv[2]).href);
      process.stdout.write(JSON.stringify(Object.keys(FORMATS)));
    JS
    out, err, status = Open3.capture3("node", "--input-type=module", "-", MODULE_PATH, stdin_data: script)
    assert status.success?, "node a échoué : #{err}"

    assert_equal Poll::KINDS.sort, Poll::Format::FORMATS.keys.sort
    assert_equal Poll::KINDS.sort, JSON.parse(out).sort
    Poll::Format::FORMATS.each_value { |name| assert_kind_of Class, name.constantize }
  end
end
