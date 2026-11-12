# frozen_string_literal: true

require "test_helper"

class StagingHostTest < ActiveSupport::TestCase
  KEYS = %w[APP_HOST STAGING_HOSTS].freeze

  setup do
    @previous = KEYS.index_with { |key| ENV[key] }
    ENV["STAGING_HOSTS"] = "edge.live.example.org, old-edge.live.example.org"
  end

  teardown { @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value } }

  test "reconnaît le nom canonique et l'ancien nom du staging, espaces ignorés" do
    assert_equal %w[edge.live.example.org old-edge.live.example.org], StagingHost.names
    %w[edge.live.example.org old-edge.live.example.org].each do |host|
      ENV["APP_HOST"] = host
      assert StagingHost.current?, host
    end
  end

  test "la prod, un hôte voisin ou l'absence d'APP_HOST ne sont pas le staging" do
    [ "live.example.org", "edge.live.example.org.evil.example", "edge.projet.example.org", "" ].each do |host|
      ENV["APP_HOST"] = host
      refute StagingHost.current?, host
    end
    ENV.delete("APP_HOST")
    refute StagingHost.current?
  end

  test "sans STAGING_HOSTS, aucune instance n'est le staging : aucun nom par défaut" do
    [ nil, "", " , " ].each do |value|
      value.nil? ? ENV.delete("STAGING_HOSTS") : ENV["STAGING_HOSTS"] = value
      assert_empty StagingHost.names, value.inspect
      [ "edge.live.example.org", "" ].each do |host|
        refute StagingHost.current?(host), "#{value.inspect} / #{host.inspect}"
        assert_nil StagingHost.legacy_redirect(host), "#{value.inspect} / #{host.inspect}"
      end
    end
  end

  test "staging : les anciens noms redirigent vers le nom canonique, chemins machine exclus" do
    %w[edge.live.example.org old-edge.live.example.org].each do |host|
      ENV["APP_HOST"] = host
      redirect = StagingHost.legacy_redirect
      assert_equal %w[old-edge.live.example.org], redirect.fetch(:from), host
      assert_equal "edge.live.example.org", redirect.fetch(:to), host
      refute_includes redirect.fetch(:from), redirect.fetch(:to), "la cible ne doit pas être une source (boucle)"
      assert_equal %w[/up /api /webhooks /cable /rtc /agent].sort, redirect.fetch(:exclude_prefixes).sort
    end
  end

  test "staging sans ancien nom : reconnu, mais aucune redirection montée" do
    ENV["STAGING_HOSTS"] = "edge.live.example.org"
    assert StagingHost.current?("edge.live.example.org")
    assert_nil StagingHost.legacy_redirect("edge.live.example.org")
  end

  test "hors staging, aucune redirection n'est montée" do
    [ "live.example.org", "edge.live.example.org.evil.example", "", nil ].each do |host|
      assert_nil StagingHost.legacy_redirect(host), host.inspect
    end
  end
end
