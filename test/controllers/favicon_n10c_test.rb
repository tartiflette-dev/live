# frozen_string_literal: true

require "test_helper"
require "digest"

class FaviconN10cTest < ActionDispatch::IntegrationTest
  test "icon.svg : atome y=283.4, auto dark, lettre l, pas de rouge scaffold" do
    svg = Rails.root.join("public/icon.svg").read
    assert_includes svg, 'y="283.4"'
    assert_includes svg, "@media (prefers-color-scheme: dark)"
    assert_includes svg, "Monogramme l."
    assert_no_match(/<text[\s>]/, svg)
    assert_no_match(/<circle[\s>]/, svg)
    assert_no_match(/fill="red"/, svg)
  end

  test "icon-stg.svg porte le cadre orange d'environnement" do
    stg = Rails.root.join("public/icon-stg.svg").read
    assert_match(/stroke\s*[:=]\s*"?#FB5102/, stg)
    assert_includes stg, 'y="283.4"'
  end

  test "icon.png n'est plus le PNG rouge scaffold" do
    digest = Digest::MD5.hexdigest(Rails.root.join("public/icon.png").read)
    refute digest.start_with?("a4376964"), "icon.png encore le scaffold rouge (md5=#{digest})"
  end

  test "layout application : un seul rel=icon SVG, sans media, apple-touch servi par la gem" do
    require_undust_theme!
    get root_path
    assert_response :success
    assert_select 'link[rel="icon"]', count: 1
    assert_select 'link[rel="icon"][type="image/svg+xml"]'
    assert_select 'link[rel="icon"][media]', count: 0
    assert_select 'link[rel="apple-touch-icon"][href^="/apple-touch-icon.png"]'
    assert_no_match(/data-icon-light/, response.body)
  end

  test "favicon_href suit l'environnement" do
    require_undust_theme!
    helper = ApplicationController.helpers
    assert_equal "/icon.svg", helper.favicon_href

    # Nom canonique et ancien nom resté servi : même favicon.
    staging_hosts = %w[edge.live.example.org old-edge.live.example.org]
    staging_hosts.each do |staging_host|
      with_env("APP_HOST" => staging_host, "STAGING_HOSTS" => staging_hosts.join(",")) do
        assert_equal "/icon-stg.svg", helper.favicon_href, staging_host
      end
    end

    with_env("APP_HOST" => "live.example.org", "STAGING_HOSTS" => staging_hosts.join(",")) do
      assert_equal "/icon.svg", helper.favicon_href
    end
  end

  private

  def with_env(overrides)
    previous = overrides.keys.index_with { |key| ENV[key] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
