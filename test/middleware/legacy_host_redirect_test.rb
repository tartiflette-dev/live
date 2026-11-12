# frozen_string_literal: true

require "test_helper"

# Test unitaire Rack du mécanisme générique (aucune route Rails en jeu) ; les
# noms de l'instance staging viennent de STAGING_HOSTS (test/lib/staging_host_test.rb).
class LegacyHostRedirectTest < ActiveSupport::TestCase
  APP = ->(_env) { [ 200, { "content-type" => "text/plain" }, [ "ok" ] ] }

  def middleware(app = APP)
    LegacyHostRedirect.new(
      app,
      from: %w[ancien.example.test],
      to: "edge.example.test",
      exclude_prefixes: %w[/up /api /webhooks /cable]
    )
  end

  def request(path, host: "ancien.example.test", method: "GET", app: middleware, **options)
    Rack::MockRequest.new(app).request(method, "https://#{host}#{path}", options)
  end

  test "GET sur l'ancien nom : 301 vers le nouveau nom, même chemin et même query" do
    response = request("/webinars/cafe-ia-1?tab=recordings&lang=fr")
    assert_equal 301, response.status
    assert_equal "https://edge.example.test/webinars/cafe-ia-1?tab=recordings&lang=fr", response.location
  end

  test "la page de connexion de l'ancien nom renvoie vers le nouveau (cookie d'état OIDC)" do
    response = request("/sign_in")
    assert_equal 301, response.status
    assert_equal "https://edge.example.test/sign_in", response.location
  end

  test "HEAD sur l'ancien nom : 301 aussi" do
    response = request("/w/cafe-ia-1", method: "HEAD")
    assert_equal 301, response.status
    assert_equal "https://edge.example.test/w/cafe-ia-1", response.location
  end

  test "l'hôte est comparé sans tenir compte de la casse ni du port" do
    assert_equal 301, request("/", host: "ANCIEN.example.test").status
    assert_equal 301, request("/", host: "ancien.example.test:443").status
  end

  test "un POST n'est jamais redirigé" do
    assert_equal 200, request("/auth/pocket_id", method: "POST").status
    assert_equal 200, request("/w/cafe-ia-1/registrations", method: "POST").status
  end

  test "un POST déguisé en GET par Rack::MethodOverride n'est pas redirigé" do
    stack = Rack::MethodOverride.new(middleware)
    response = request("/sign_in", method: "POST", app: stack, params: { "_method" => "GET" })
    assert_equal 200, response.status
  end

  test "les autres méthodes non sûres ne sont pas redirigées" do
    %w[PUT PATCH DELETE OPTIONS].each do |verb|
      assert_equal 200, request("/sign_out", method: verb).status, verb
    end
  end

  test "/up et les chemins machine ne sont pas redirigés" do
    %w[/up /api/token /webhooks/livekit /webhooks/transcripts/enabled /cable].each do |path|
      assert_equal 200, request(path).status, path
    end
  end

  test "un chemin qui ressemble seulement à un préfixe exclu est redirigé" do
    assert_equal 301, request("/upload").status
    assert_equal 301, request("/apidocs").status
  end

  test "le nouveau nom n'est jamais redirigé" do
    assert_equal 200, request("/sign_in", host: "edge.example.test").status
    assert_equal 200, request("/", host: "edge.example.test", method: "HEAD").status
  end

  test "un hôte inconnu passe tel quel" do
    assert_equal 200, request("/sign_in", host: "autre.example.test").status
  end

  test "refuse une configuration dont la cible figure parmi les sources (boucle)" do
    assert_raises(ArgumentError) do
      LegacyHostRedirect.new(APP, from: %w[ancien.example.test edge.example.test], to: "edge.example.test")
    end
    assert_raises(ArgumentError) do
      LegacyHostRedirect.new(APP, from: "Edge.Example.test", to: "edge.example.test")
    end
  end
end
