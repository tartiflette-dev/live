# frozen_string_literal: true

require "test_helper"
require "open3"

class DevLoginTest < ActiveSupport::TestCase
  def env(name) = ActiveSupport::EnvironmentInquirer.new(name)

  test "active en développement, sans drapeau" do
    assert DevLogin.enabled?(env: env("development"), vars: {})
  end

  test "hors développement, seulement avec LIVE_DEV_LOGIN=1" do
    refute DevLogin.enabled?(env: env("test"), vars: {})
    refute DevLogin.enabled?(env: env("test"), vars: { "LIVE_DEV_LOGIN" => "true" })
    assert DevLogin.enabled?(env: env("test"), vars: { "LIVE_DEV_LOGIN" => "1" })
  end

  test "jamais en production, même avec le drapeau" do
    refute DevLogin.enabled?(env: env("production"), vars: { "LIVE_DEV_LOGIN" => "1" })
  end

  test "le drapeau posé en production refuse le démarrage, quelle que soit sa valeur" do
    %w[1 0 false].each do |value|
      assert_raises(DevLogin::ForbiddenInProduction, value) do
        DevLogin.assert_not_in_production!(env: env("production"), vars: { "LIVE_DEV_LOGIN" => value })
      end
    end
  end

  test "sans drapeau en production, ou avec le drapeau ailleurs, le démarrage continue" do
    assert_nothing_raised do
      DevLogin.assert_not_in_production!(env: env("production"), vars: { "LIVE_DEV_LOGIN" => "" })
      DevLogin.assert_not_in_production!(env: env("development"), vars: { "LIVE_DEV_LOGIN" => "1" })
    end
  end

  NETWORKS = { "LIVE_DEV_LOGIN_ALLOWED_NETWORKS" => "172.16.0.0/12, 192.168.0.0/16" }.freeze

  test "origine : loopback seul par défaut, IPv4, IPv6 et IPv4 dans IPv6" do
    %w[127.0.0.1 127.8.9.10 ::1 ::ffff:127.0.0.1].each { |ip| assert DevLogin.allowed_address?(ip, vars: {}), ip }
    %w[172.29.0.1 192.168.1.20 203.0.113.5 2001:db8::1].each { |ip| refute DevLogin.allowed_address?(ip, vars: {}), ip }
  end

  test "origine : les réseaux déclarés s'ajoutent au loopback, et rien d'autre" do
    %w[127.0.0.1 172.29.0.1 192.168.65.1].each { |ip| assert DevLogin.allowed_address?(ip, vars: NETWORKS), ip }
    %w[10.0.0.1 203.0.113.5 172.32.0.1].each { |ip| refute DevLogin.allowed_address?(ip, vars: NETWORKS), ip }
  end

  test "origine illisible ou absente : refusée" do
    [ nil, "", "localhost", "999.1.1.1" ].each { |ip| refute DevLogin.allowed_address?(ip, vars: NETWORKS), ip.inspect }
  end

  def peer(address, headers = {}) = { "REMOTE_ADDR" => address }.merge(headers)

  test "disponible = active ET origine admise" do
    vars = NETWORKS.merge("LIVE_DEV_LOGIN" => "1")
    assert DevLogin.available_to?(peer("172.29.0.1"), env: env("test"), vars: vars)
    refute DevLogin.available_to?(peer("203.0.113.5"), env: env("test"), vars: vars)
    refute DevLogin.available_to?(peer("127.0.0.1"), env: env("test"), vars: NETWORKS)
    refute DevLogin.available_to?(peer("127.0.0.1"), env: env("production"), vars: vars)
  end

  test "origine : jugée sur le pair TCP, un en-tête de transfert venu d'un pair non loopback est refusé" do
    %w[HTTP_X_FORWARDED_FOR HTTP_X_REAL_IP HTTP_CLIENT_IP].each do |header|
      refute DevLogin.allowed_origin?(peer("192.168.1.50", header => "127.0.0.1"), vars: {}), header
      refute DevLogin.allowed_origin?(peer("172.29.0.1", header => "127.0.0.1"), vars: NETWORKS), header
    end
    refute DevLogin.allowed_origin?(peer("172.29.0.1", "HTTP_FORWARDED" => "for=127.0.0.1"), vars: NETWORKS)
  end

  test "origine : un mandataire loopback ne transmet que des adresses admises" do
    assert DevLogin.allowed_origin?(peer("127.0.0.1", "HTTP_X_FORWARDED_FOR" => "127.0.0.1"), vars: {})
    assert DevLogin.allowed_origin?(peer("::1", "HTTP_X_FORWARDED_FOR" => "172.29.0.1"), vars: NETWORKS)
    refute DevLogin.allowed_origin?(peer("127.0.0.1", "HTTP_X_FORWARDED_FOR" => "192.168.1.50"), vars: {})
    refute DevLogin.allowed_origin?(peer("127.0.0.1", "HTTP_X_FORWARDED_FOR" => "127.0.0.1, 203.0.113.5"), vars: {})
  end

  test "Forwarded (RFC 7239) : for= lu, port et crochets retirés, valeur obfusquée refusée" do
    assert DevLogin.allowed_origin?(peer("127.0.0.1", "HTTP_FORWARDED" => "for=127.0.0.1:5678;proto=http"), vars: {})
    assert DevLogin.allowed_origin?(peer("127.0.0.1", "HTTP_FORWARDED" => 'for="[::1]:80"'), vars: {})
    refute DevLogin.allowed_origin?(peer("127.0.0.1", "HTTP_FORWARDED" => "for=203.0.113.5"), vars: {})
    refute DevLogin.allowed_origin?(peer("127.0.0.1", "HTTP_FORWARDED" => "for=unknown"), vars: {})
    refute DevLogin.allowed_origin?(peer("127.0.0.1", "HTTP_FORWARDED" => "proto=https"), vars: {})
  end

  test "réseaux déclarés hors plages privées : refus de démarrer" do
    [ "0.0.0.0/0", "203.0.113.0/24", "172.0.0.0/8", "::/0", "2001:db8::/32", "pas-un-réseau" ].each do |value|
      assert_raises(DevLogin::UnsafeNetwork, value) do
        DevLogin.assert_safe_networks!(vars: { "LIVE_DEV_LOGIN_ALLOWED_NETWORKS" => value })
      end
    end
  end

  test "réseaux privés ou loopback déclarés, ou rien : le démarrage continue" do
    assert_nothing_raised do
      DevLogin.assert_safe_networks!(vars: {})
      DevLogin.assert_safe_networks!(vars: { "LIVE_DEV_LOGIN_ALLOWED_NETWORKS" => "172.16.0.0/12,192.168.0.0/16,10.0.0.0/8" })
      DevLogin.assert_safe_networks!(vars: { "LIVE_DEV_LOGIN_ALLOWED_NETWORKS" => "127.0.0.1/32,fd00::/8" })
    end
  end

  test "le compose du quickstart déclare des réseaux que le démarrage accepte" do
    compose = YAML.safe_load_file(Rails.root.join("compose.yaml"))
    value = compose.dig("services", "app", "environment", "LIVE_DEV_LOGIN_ALLOWED_NETWORKS")

    assert_predicate value, :present?
    assert_nothing_raised { DevLogin.assert_safe_networks!(vars: { "LIVE_DEV_LOGIN_ALLOWED_NETWORKS" => value }) }
    assert DevLogin.allowed_address?("172.29.0.1", vars: { "LIVE_DEV_LOGIN_ALLOWED_NETWORKS" => value })
  end

  # Boot réel en RAILS_ENV=production, comme le conteneur.
  # (Les assets ne sont pas compilés ici : l'écran de connexion se rend sans
  # layout.)
  PROBE = <<~RUBY
    app = Rack::MockRequest.new(Rails.application)
    dev_login = app.post("https://live.example.test/dev_login", params: { email: "x@example.test" },
                                                               "HTTP_HOST" => "live.example.test")
    sign_in = SessionsController.render(:new, layout: false)
    puts "PROBE " + JSON.generate(dev_form: sign_in.include?("dev-login"), dev_login: dev_login.status,
                                  oidc_button: sign_in.include?("/auth/pocket_id"),
                                  unavailable: sign_in.include?(I18n.t("chrome.login_unavailable")))
  RUBY

  def boot_production(extra_env)
    env = { "RAILS_ENV" => "production", "APP_HOST" => "live.example.test", "SECRET_KEY_BASE_DUMMY" => "1",
            "RAILS_LOG_LEVEL" => "fatal", "LIVE_DEV_LOGIN" => nil,
            "OIDC_CLIENT_ID" => nil, "OIDC_CLIENT_SECRET" => nil }.merge(extra_env)
    Open3.capture3(env, RbConfig.ruby, "bin/rails", "runner", PROBE, chdir: Rails.root.to_s)
  end

  test "boot production avec LIVE_DEV_LOGIN : refus de démarrer" do
    _stdout, stderr, status = boot_production("LIVE_DEV_LOGIN" => "1")

    refute status.success?
    assert_includes stderr, "DevLogin::ForbiddenInProduction"
  end

  test "boot production sans le drapeau ni OIDC : ni formulaire ni bouton, POST /dev_login en 404" do
    stdout, stderr, status = boot_production({})

    assert status.success?, stderr
    result = JSON.parse(stdout.lines.grep(/\APROBE /).last.delete_prefix("PROBE "))
    assert_equal({ "dev_form" => false, "dev_login" => 404, "oidc_button" => false, "unavailable" => true }, result)
  end

  test "boot production avec un fournisseur OIDC complet : bouton OIDC, pas de formulaire de dev" do
    stdout, stderr, status = boot_production("OIDC_ISSUER" => "https://auth.example.test",
                                             "OIDC_CLIENT_ID" => "id", "OIDC_CLIENT_SECRET" => "s")

    assert status.success?, stderr
    result = JSON.parse(stdout.lines.grep(/\APROBE /).last.delete_prefix("PROBE "))
    assert_equal({ "dev_form" => false, "dev_login" => 404, "oidc_button" => true, "unavailable" => false }, result)
  end

  test "boot production avec un client OIDC sans émetteur : refus de démarrer" do
    _stdout, stderr, status = boot_production("OIDC_ISSUER" => nil, "OIDC_CLIENT_ID" => "id", "OIDC_CLIENT_SECRET" => "s")

    refute status.success?
    assert_includes stderr, "OidcProvider::IncompleteConfiguration"
  end
end
