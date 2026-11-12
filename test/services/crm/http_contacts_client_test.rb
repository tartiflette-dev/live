# frozen_string_literal: true

require "test_helper"

# HttpContactsClient — contrat HTTP vers le CRM.
#
# Pas de WebMock dans ce repo : on stub `Net::HTTP.start` avec une petite
# fausse connexion qui enregistre la dernière requête et renvoie une
# fausse réponse configurable. Suffisant pour les 3 méthodes et les 3
# familles d'erreurs (2xx/4xx/5xx/réseau).
class Crm::HttpContactsClientTest < ActiveSupport::TestCase
  # `[]` = en-tête, comme Net::HTTPResponse (Retry-After d'un 429).
  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](name) = headers.to_h[name]
  end

  class FakeHttp
    attr_reader :last_request

    def initialize(response)
      @response = response
    end

    def request(req)
      @last_request = req
      @response
    end
  end

  setup do
    @env_token  = ENV["CRM_API_TOKEN"]
    @env_url    = ENV["CRM_BASE_URL"]
    ENV["CRM_API_TOKEN"] = "t-test"
    ENV["CRM_BASE_URL"]  = "https://ops.test"
  end

  teardown do
    ENV["CRM_API_TOKEN"] = @env_token
    ENV["CRM_BASE_URL"]  = @env_url
  end

  test "CONTRAT search_by_email : GET /api/v1/contacts/lookup?email=, jamais ?search=" do
    body = JSON.generate(id: 1, email: "alice@example.test", segments: [])
    stub_response(FakeResponse.new("200", body)) do |fake|
      hit = Crm::HttpContactsClient.new(logger: silent_logger).search_by_email("alice@example.test")

      assert_equal 1, hit["id"]
      assert_equal "GET", fake.last_request.method
      assert_equal "/api/v1/contacts/lookup?email=alice%40example.test", fake.last_request.path
      assert_equal "Bearer t-test", fake.last_request["Authorization"]
    end
  end

  test "search_by_email : 404 = pas de fiche (nil), PAS une erreur permanente" do
    stub_response(FakeResponse.new("404", JSON.generate(error: "not_found"))) do
      assert_nil Crm::HttpContactsClient.new(logger: silent_logger).search_by_email("alice@example.test")
    end
  end

  test "un 404 HORS contrat (CRM sans cette recherche, route absente) n'est JAMAIS « pas de fiche »" do
    client = Crm::HttpContactsClient.new(logger: silent_logger)
    [ "<!DOCTYPE html><h1>Not Found</h1>", "", JSON.generate(error: "route_not_found"), JSON.generate(status: 404) ].each do |body|
      stub_response(FakeResponse.new("404", body)) do
        [
          -> { client.search_by_email("alice@example.test") },
          -> { client.create_interaction(VALID_INTERACTION) },
          -> { client.add_segment(9, email: "a@b.example.org", realm: "professional", segment: "participant") }
        ].each do |call|
          err = assert_raises(Crm::TransientError, body.inspect) { call.call }
          assert_equal 404, err.http_status
          assert_equal "crm:unexpected_404", err.message
        end
      end
    end
  end

  test "404 sur segment / interaction : ContactNotFoundError (permanente), distincte d'un 404 de lookup" do
    stub_response(FakeResponse.new("404", JSON.generate(error: "not_found"))) do
      client = Crm::HttpContactsClient.new(logger: silent_logger)
      [
        -> { client.create_interaction(VALID_INTERACTION) },
        -> { client.add_segment(9, email: "a@b.example.org", realm: "professional", segment: "participant") }
      ].each do |call|
        err = assert_raises(Crm::ContactNotFoundError) { call.call }
        assert_kind_of Crm::PermanentError, err
        assert_equal 404, err.http_status
        assert_equal "crm:contact_not_found", err.message
      end
    end
  end

  test "422 corps hors contrat : PermanentError sans recopier le corps" do
    body = JSON.generate(error: "param_policy", params: [ "notes" ])
    stub_response(FakeResponse.new("422", body)) do
      err = assert_raises(Crm::PermanentError) do
        Crm::HttpContactsClient.new(logger: silent_logger).search_by_email("pas-une-adresse")
      end
      assert_equal 422, err.http_status
      assert_equal "crm:http_422", err.message
    end
  end

  # ---- Contrat HTTP du CRM ---
  # Corps À PLAT, exactement les clés du contrat ; listes :
  # test/support/fake_crm_client.rb (CrmContract).
  VALID_INTERACTION = {
    contact_id: 42, email: "camille@example.test", kind: "form", occurred_at: "2026-10-30T12:00:00Z",
    title: "T", source: "live.example.test:cafe-ia", source_path: "/w/cafe-ia", notes: "n"
  }.freeze

  test "CONTRAT create_contact : corps À PLAT, prénom/nom/email seulement (pas de notes)" do
    stub_response(FakeResponse.new("201", JSON.generate(id: 42, email: "camille@example.test", segments: []))) do |fake|
      contact = Crm::HttpContactsClient.new(logger: silent_logger).create_contact(
        first_name: "Camille", last_name: nil, email: "camille@example.test"
      )
      assert_equal 42, contact["id"]
      req = fake.last_request
      assert_equal "/api/v1/contacts", req.path
      assert_equal "POST", req.method
      assert_equal "application/json", req["Content-Type"]
      body = JSON.parse(req.body)
      assert_equal({ "first_name" => "Camille", "last_name" => nil, "email" => "camille@example.test" }, body)
      assert_empty body.keys - CrmContract::CONTACT_PERMITTED
    end
  end

  test "CONTRAT create_interaction : corps À PLAT, contact_id et email-preuve au premier niveau" do
    stub_response(FakeResponse.new("201", JSON.generate(id: 9))) do |fake|
      Crm::HttpContactsClient.new(logger: silent_logger).create_interaction(VALID_INTERACTION)
      assert_equal "/api/v1/interactions", fake.last_request.path
      body = JSON.parse(fake.last_request.body)
      assert_equal VALID_INTERACTION.transform_keys(&:to_s), body
      assert_empty body.keys - CrmContract::INTERACTION_PERMITTED
    end
  end

  test "CONTRAT : sources et chemins acceptés par le contrat CRM" do
    client = Crm::HttpContactsClient.new(logger: silent_logger)
    stub_response(FakeResponse.new("201", JSON.generate(id: 9))) do
      [
        [ "live.example.test:cafe-ia", "/w/cafe-ia" ],
        [ "live.example.test:marketing_consent:cafe-ia", "/mc" ],
        [ "live.example.test:withdrawal:cafe-ia", "/mc/withdraw" ],
        [ "live.example.test:notify_next", "/confirmer" ]
      ].each do |source, source_path|
        client.create_interaction(VALID_INTERACTION.merge(source: source, source_path: source_path))
        assert_match CrmContract::SOURCE, source
        assert_match CrmContract::SOURCE_PATH, source_path
      end
    end
  end

  test "CONTRAT : tout écart au contrat CRM est refusé AVANT tout appel HTTP" do
    called = false
    client = Crm::HttpContactsClient.new(logger: silent_logger)
    with_net_http_start(->(*_a, **_k) { called = true }) do
      [
        -> { client.create_contact(first_name: "A", email: "a@b.example.org", notes: "x") },
        -> { client.create_interaction(VALID_INTERACTION.merge(contact: {})) },
        -> { client.create_interaction(VALID_INTERACTION.except(:email)) },
        -> { client.create_interaction(VALID_INTERACTION.merge(kind: "note")) },
        -> { client.create_interaction(VALID_INTERACTION.merge(source: "tartiflette.dev")) },
        -> { client.create_interaction(VALID_INTERACTION.merge(source: "live.example.test")) },
        -> { client.create_interaction(VALID_INTERACTION.merge(source: "live.example.testm:x")) },
        -> { client.create_interaction(VALID_INTERACTION.merge(source: "live.example.test:a:b:c")) },
        -> { client.create_interaction(VALID_INTERACTION.merge(source_path: "/admin")) },
        -> { client.create_interaction(VALID_INTERACTION.except(:source_path)) },
        -> { client.add_segment(1, email: "a@b.example.org", realm: "professional", segment: "prospect") },
        -> { client.add_segment(1, email: "", realm: "professional", segment: "participant") }
      ].each_with_index { |call, index| assert_raises(Crm::ContractError, "cas #{index}") { call.call } }
    end
    assert_not called
  end

  test "CONTRAT add_segment : email-preuve à côté de segment" do
    stub_response(FakeResponse.new("201", JSON.generate(id: 42, email: "a@b.example.org", segments: []))) do |fake|
      Crm::HttpContactsClient.new(logger: silent_logger).add_segment(42, email: "a@b.example.org", realm: "professional",
                                                                  segment: "participant")

      req = fake.last_request
      assert_equal "POST", req.method
      assert_equal "/api/v1/contacts/42/segments", req.path
      assert_equal "Bearer t-test", req["Authorization"]
      assert_equal({ "email" => "a@b.example.org", "segment" => { "realm" => "professional", "segment" => "participant" } },
                   JSON.parse(req.body))
      assert_empty JSON.parse(req.body).keys - CrmContract::SEGMENT_PERMITTED
    end
  end

  test "add_segment : 200 (segment déjà présent) est un succès" do
    stub_response(FakeResponse.new("200", JSON.generate(id: 42, email: "a@b.example.org", segments: []))) do
      assert_nothing_raised do
        Crm::HttpContactsClient.new(logger: silent_logger).add_segment("42", email: "a@b.example.org", realm: "professional",
                                                                       segment: "participant")
      end
    end
  end

  test "add_segment refuse un identifiant de contact non entier (pas d'injection de chemin)" do
    assert_raises(ArgumentError) do
      Crm::HttpContactsClient.new(logger: silent_logger).add_segment("42/../../admin", email: "a@b.example.org", realm: "professional",
                                                                               segment: "participant")
    end
  end

  test "5xx soulève une TransientError portant son http_status" do
    stub_response(FakeResponse.new("502", "bad gateway")) do
      err = assert_raises(Crm::TransientError) do
        Crm::HttpContactsClient.new(logger: silent_logger).search_by_email("x@y.example.org")
      end
      assert_equal 502, err.http_status
      assert_equal "crm:http_502", err.message
    end
  end

  test "429 : RateLimitedError (transitoire) portant le Retry-After du CRM" do
    rate_limited = JSON.generate(error: "rate_limited")
    {
      "42" => [ 42, 42.seconds ],                 # fenêtre de la minute
      "600" => [ 600, 1.hour ],                   # quota du jour, bascule proche : au moins 1 h
      "7200" => [ 7200, 2.hours ],                # quota du jour
      nil => [ 60, 60.seconds ],                  # sans en-tête : une minute
      "n'importe quoi" => [ 60, 60.seconds ],
      "999999" => [ 86_400, 24.hours ]            # borné à 24 h
    }.each do |header, (seconds, defer)|
      stub_response(FakeResponse.new("429", rate_limited, { "Retry-After" => header })) do
        err = assert_raises(Crm::RateLimitedError, header.inspect) do
          Crm::HttpContactsClient.new(logger: silent_logger).search_by_email("x@y.example.org")
        end
        assert_kind_of Crm::TransientError, err
        assert_equal 429, err.http_status
        assert_equal seconds, err.retry_after, header.inspect
        assert_equal defer, err.defer_for, header.inspect
      end
    end
  end

  test "429 : Retry-After en date HTTP" do
    freeze_time do
      header = 90.seconds.from_now.httpdate
      stub_response(FakeResponse.new("429", "{}", { "Retry-After" => header })) do
        err = assert_raises(Crm::RateLimitedError) { Crm::HttpContactsClient.new(logger: silent_logger).search_by_email("x@y.example.org") }
        assert_equal 90, err.retry_after
      end
    end
  end

  test "ContractError = échec permanent, code 422, avant tout appel" do
    err = assert_raises(Crm::ContractError) do
      Crm::HttpContactsClient.new(logger: silent_logger).add_segment(9, email: "a@b.example.org", realm: "professional", segment: "x")
    end
    assert_kind_of Crm::PermanentError, err
    assert_equal 422, err.http_status
  end

  test "422 soulève une PermanentError SANS copier le body (qui peut contenir du PII du CRM)" do
    body = JSON.generate(errors: [ "Email alice@example.test invalid" ])
    stub_response(FakeResponse.new("422", body)) do
      err = assert_raises(Crm::PermanentError) do
        Crm::HttpContactsClient.new(logger: silent_logger).create_contact(first_name: "A", email: "bad")
      end
      assert_equal 422, err.http_status
      assert_equal "crm:http_422", err.message
      assert_no_match(/alice/i, err.message)
    end
  end

  test "panne réseau (connect timeout) remonte en TransientError sans fuite" do
    with_net_http_start(->(*_a, **_k) { raise Net::OpenTimeout, "ops.test: openssl handshake" }) do
      err = assert_raises(Crm::TransientError) do
        Crm::HttpContactsClient.new(logger: silent_logger).search_by_email("x@y.example.org")
      end
      assert_equal 0, err.http_status
      assert_equal "crm:network", err.message, "l'exception d'origine ne doit JAMAIS être dans le message"
    end
  end

  test "ArgumentError si le token est absent" do
    ENV["CRM_API_TOKEN"] = ""
    assert_raises(ArgumentError) { Crm::HttpContactsClient.new }
  end

  test "ArgumentError si CRM_BASE_URL est absente : aucun hôte par défaut" do
    [ nil, "" ].each do |value|
      ENV["CRM_BASE_URL"] = value
      error = assert_raises(Crm::UnconfiguredError) { Crm::HttpContactsClient.new }
      assert_kind_of ArgumentError, error, "les appelants (rescue/discard_on ArgumentError) la traitent comme avant"
      assert_equal "CRM_BASE_URL", error.variable
      assert_equal "CRM_BASE_URL manquant", error.message
    end
  end

  # ---- Confidentialité des logs & exceptions ---

  test "log de succès : pas d'email ni de query sensible ni de jeton" do
    body = JSON.generate(id: 1, email: "alice@example.test")
    captured = capture_log do |logger|
      stub_response(FakeResponse.new("200", body)) do
        Crm::HttpContactsClient.new(logger: logger).search_by_email("alice@example.test")
      end
    end
    assert_match(/\[Crm::HttpContactsClient\] crm_http ok/, captured)
    assert_match(%r{path=/api/v1/contacts/lookup }, captured, "chemin loggué sans query")
    assert_match(/http_status=200/, captured)
    assert_match(/duration_ms=\d+/, captured)
    assert_no_match(/alice@example\.test/, captured, "jamais l'email dans un log")
    assert_no_match(/email=/i, captured, "jamais la query loggée (contient l'email)")
    assert_no_match(/t-test/, captured, "jamais le jeton Bearer dans un log")
    assert_no_match(/Authorization/i, captured, "jamais l'en-tête Authorization dans un log")
  end

  test "log d'erreur 4xx : pas de body, pas d'email, pas de jeton" do
    body = JSON.generate(errors: [ "Email alice@example.test invalid" ])
    captured = capture_log do |logger|
      stub_response(FakeResponse.new("422", body)) do
        assert_raises(Crm::PermanentError) do
          Crm::HttpContactsClient.new(logger: logger).create_contact(
            email: "alice@example.test", first_name: "Alice", last_name: "Dupont"
          )
        end
      end
    end
    assert_match(/crm_http error/, captured)
    assert_match(/http_status=422/, captured)
    assert_match(/outcome=PermanentError/, captured)
    assert_no_match(/alice/i, captured, "ni l'email ni le prénom dans un log")
    assert_no_match(/Dupont/, captured, "ni le nom de famille dans un log")
    assert_no_match(/t-test/, captured, "jamais le jeton Bearer")
  end

  test "log d'erreur 5xx : pas de body" do
    captured = capture_log do |logger|
      stub_response(FakeResponse.new("500", "stack trace with alice@example.test")) do
        assert_raises(Crm::TransientError) do
          Crm::HttpContactsClient.new(logger: logger).search_by_email("alice@example.test")
        end
      end
    end
    assert_match(/http_status=500/, captured)
    assert_no_match(/alice/i, captured)
    assert_no_match(/stack trace/, captured, "aucun fragment de body n'est loggué")
  end

  test "log de panne réseau : pas de hostname ni de détails de l'exception" do
    captured = capture_log do |logger|
      with_net_http_start(->(*_a, **_k) { raise SocketError, "getaddrinfo: Name or service not known" }) do
        assert_raises(Crm::TransientError) do
          Crm::HttpContactsClient.new(logger: logger).search_by_email("alice@example.test")
        end
      end
    end
    assert_match(/outcome=TransientError/, captured)
    assert_match(/http_status=0/, captured)
    assert_no_match(/getaddrinfo/, captured, "le détail du SocketError ne doit pas fuiter")
    assert_no_match(/alice/i, captured)
  end

  private

  def silent_logger
    Logger.new(IO::NULL)
  end

  def capture_log
    io = StringIO.new
    yield Logger.new(io)
    io.string
  end

  def stub_response(response)
    fake = FakeHttp.new(response)
    with_net_http_start(->(*_a, **_k, &block) { block.call(fake) }) do
      yield(fake)
    end
  end

  # Remplace temporairement `Net::HTTP.start` par un lambda, sans dépendre
  # d'un `minitest/mock` (absent de minitest 6 que ce repo embarque).
  def with_net_http_start(stub)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |*a, **k, &b|
      stub.call(*a, **k, &b)
    end
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
  end
end
