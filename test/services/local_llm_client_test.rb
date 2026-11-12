require "test_helper"

# LocalLlmClient — contrat OpenAI-compat vers llama-swap.
# Pas de WebMock dans ce dépôt : Net::HTTP.start est remplacé par
# une fausse connexion (même patron que NextcloudClientTest). Aucun appel
# réseau, aucun GPU. Le comportement réel de glm-4-9b (bloc ```json malgré
# response_format) a été relevé par un essai unique.
class LocalLlmClientTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body)

  class FakeHttp
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def request(req)
      @requests << req
      raise @response if @response.is_a?(Exception)

      @response
    end
  end

  setup do
    @client = LocalLlmClient.new(base_url: "http://gt.test:11434/v1/", model: "glm-4-9b")
  end

  test "from_env : coupé sauf QA_LLM_ENABLED=true avec une QA_LLM_URL ; modèle glm-4-9b par défaut" do
    url = { "QA_LLM_URL" => "http://llm.test:11434/v1" }
    assert_nil LocalLlmClient.from_env({})
    assert_nil LocalLlmClient.from_env(url.merge("QA_LLM_ENABLED" => "1"))

    client = LocalLlmClient.from_env(url.merge("QA_LLM_ENABLED" => "true"))
    assert_equal "glm-4-9b", client.model
    assert_equal "http://llm.test:11434/v1/chat/completions", client.instance_variable_get(:@endpoint).to_s
    assert_equal "qwen", LocalLlmClient.from_env(url.merge("QA_LLM_ENABLED" => "true", "QA_LLM_MODEL" => "qwen")).model
  end

  test "from_env : activé sans QA_LLM_URL, coupé (aucun hôte par défaut) ; la raison le dit" do
    assert_nil LocalLlmClient.from_env("QA_LLM_ENABLED" => "true")
    assert_nil LocalLlmClient.from_env("QA_LLM_ENABLED" => "true", "QA_LLM_URL" => "")
    assert_equal "llm_unconfigured", LocalLlmClient.unavailable_reason("QA_LLM_ENABLED" => "true")
    assert_equal "llm_disabled", LocalLlmClient.unavailable_reason({})
    assert_equal "llm_disabled", LocalLlmClient.unavailable_reason("QA_LLM_ENABLED" => "1", "QA_LLM_URL" => "http://llm.test/v1")
  end

  test "requête : modèle, messages, sortie JSON, aucun réglage de chargement (ttl) ; objet rendu" do
    http, result, options = call_with(completion(%({"is_question": true})))

    request = http.requests.sole
    assert_equal "/v1/chat/completions", request.path
    payload = JSON.parse(request.body)
    assert_equal "glm-4-9b", payload["model"]
    assert_equal({ "type" => "json_object" }, payload["response_format"])
    assert_equal [ "max_tokens", "messages", "model", "response_format", "temperature" ], payload.keys.sort
    assert_equal({ "is_question" => true }, result)
    assert_equal [ "gt.test", 11434 ], options.first(2)
    assert_equal LocalLlmClient::TIMEOUT_SECONDS, options.last[:read_timeout]
  end

  test "chapitres : délai et longueur de réponse propres, le reste du contrat inchangé" do
    client = LocalLlmClient.from_env({ "QA_LLM_ENABLED" => "true", "QA_LLM_URL" => "http://llm.test:11434/v1" }, 60)
    assert_equal 60, client.instance_variable_get(:@timeout)
    assert_equal LocalLlmClient::TIMEOUT_SECONDS,
                 LocalLlmClient.from_env({ "QA_LLM_ENABLED" => "true", "QA_LLM_URL" => "http://llm.test/v1" }).instance_variable_get(:@timeout)

    http = FakeHttp.new(completion(%({"continues": true, "chapters": []})))
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*_args, **_kwargs, &block| block.call(http) }
    @client.complete_json([ { role: "user", content: "passage" } ], max_tokens: 500)
    assert_equal 500, JSON.parse(http.requests.sole.body)["max_tokens"]
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
  end

  test "objet enveloppé dans un bloc ```json (glm-4-9b) : accepté" do
    _, result = call_with(completion("```json\n{\"relevant\": false}\n```"))
    assert_equal({ "relevant" => false }, result)
  end

  test "pannes : HTTP non 2xx, réseau, protocole, contenu absent, texte libre, JSON non objet → Error sans le texte" do
    [
      FakeResponse.new("503", "busy"),
      Errno::ECONNREFUSED.new,
      EOFError.new,
      Net::HTTPBadResponse.new("wrong status line"),
      Net::ProtocolError.new("question ?"),
      FakeResponse.new("200", { choices: [] }.to_json),
      completion("Voici ma réponse : oui, c'est une question."),
      completion("[1, 2]")
    ].each do |response|
      error = assert_raises(LocalLlmClient::Error) { call_with(response) }
      assert_not_includes error.message, "question"
    end
  end

  test "délai : par lecture ou TOTAL dépassé → Timeout (une Error), jamais d'attente au-delà" do
    assert_raises(LocalLlmClient::Timeout) { call_with(Net::ReadTimeout.new) }
    assert_raises(LocalLlmClient::Timeout) { call_with(Net::OpenTimeout.new) }

    @client = LocalLlmClient.new(base_url: "http://gt.test:11434/v1", model: "glm-4-9b", timeout: 0.2)
    slow = Object.new
    def slow.request(_req) = sleep(5)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(LocalLlmClient::Timeout) { call_with(nil, http: slow) }
    assert_kind_of LocalLlmClient::Error, error
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end

  private

  def completion(content)
    FakeResponse.new("200", { choices: [ { message: { role: "assistant", content: content } } ] }.to_json)
  end

  def call_with(response, http: FakeHttp.new(response))
    options = nil
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |*args, **kwargs, &block|
      options = [ *args, kwargs ]
      block.call(http)
    end
    result = @client.complete_json([ { role: "user", content: "question ?" } ])
    [ http, result, options ]
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end
end
