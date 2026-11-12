# Faux client du LLM local (LocalLlmClient) pour la file Q&R : aucun appel
# réseau, aucun GPU. Rend `response` (Hash, ou bloc recevant les messages du
# prompt), ou lève `error`. Garde chaque prompt reçu.
class FakeLlmClient
  attr_reader :model, :prompts

  def initialize(response = nil, model: "glm-4-9b", error: nil, &block)
    @response = block || response
    @model = model
    @error = error
    @prompts = []
  end

  def complete_json(messages, **_options)
    @prompts << messages
    raise @error if @error

    @response.respond_to?(:call) ? @response.call(messages) : @response
  end

  def self.verdict(is_question:, relevant: true, reformulation: nil, duplicate_of: nil)
    { "is_question" => is_question, "relevant" => relevant, "reformulation" => reformulation, "duplicate_of" => duplicate_of }
  end
end

# Installe un faux client (ou nil = LLM coupé) le temps d'un bloc.
module QaLlmStubbing
  def with_llm(client)
    previous = Rails.configuration.x.qa_llm_client_factory
    Rails.configuration.x.qa_llm_client_factory = -> { client }
    yield
  ensure
    Rails.configuration.x.qa_llm_client_factory = previous
  end
end
