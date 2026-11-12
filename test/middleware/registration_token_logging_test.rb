require "test_helper"

class RegistrationTokenLoggingTest < ActiveSupport::TestCase
  test "confirmation path hides the token in request logs without changing routing" do
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/r/private-bearer?locale=fr"))
    assert_equal "/r/[FILTERED]?locale=fr", request.filtered_path
    assert_equal "/r/private-bearer", request.path
  end

  test "trailing slash and extra segments keep the token hidden" do
    %w[/r/private-bearer/ /r/private-bearer/autre].each do |path|
      request = ActionDispatch::Request.new(Rack::MockRequest.env_for(path))
      assert_no_match(/private-bearer/, request.filtered_path)
    end
  end

  test "repeated slashes, which the router normalizes, keep the token hidden" do
    %w[//r/private-bearer /r//private-bearer ///r/private-bearer/x /R/private-bearer].each do |path|
      # PATH_INFO posé à la main : `env_for("//r/…")` lirait « r » comme un hôte.
      request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/").merge("PATH_INFO" => path))
      assert_no_match(/private-bearer/, request.filtered_path, path)
    end
  end

  test "ordinary request paths are unchanged" do
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/w/cafe"))
    assert_equal "/w/cafe", request.filtered_path
  end
end
