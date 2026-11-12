# Contrat HTTP du CRM (docs/registrations-api.md §Contrat HTTP du CRM) :
# clés autorisées par endpoint au premier niveau du corps. Toute autre
# clé → 422. À relire à chaque évolution du contrat.
module CrmContract
  SLUG = "[a-z0-9][a-z0-9_-]*"
  LOOKUP_PERMITTED = %w[email].freeze
  CONTACT_PERMITTED = %w[first_name last_name email].freeze
  SEGMENT_PERMITTED = %w[email segment].freeze
  INTERACTION_PERMITTED = %w[contact_id email occurred_at title notes kind source source_path].freeze
  SOURCE = /\Alive\.example\.test(?::#{SLUG}){1,2}\z/
  SOURCE_PATH = %r{\A/(?:w/#{SLUG}|mc|mc/withdraw|confirmer)\z}
end

# Faux client CRM partagé par les tests des jobs CRM : enregistre les
# appels (verbe, charge) et renvoie des réponses programmées. Contrat
# imité : Crm::HttpContactsClient (search_by_email, create_contact,
# create_interaction, add_segment).
class FakeCrmClient
  attr_reader :calls

  def initialize(search_hit: nil, raise_on: nil, raise_class: Crm::TransientError, http_status: 500)
    @search_hit = search_hit
    @raise_on = raise_on
    @raise_class = raise_class
    @http_status = http_status
    @calls = []
    @next_id = 1_000
  end

  def verbs
    calls.map(&:first)
  end

  def payloads(verb)
    calls.select { |called, _| called == verb }.map(&:last)
  end

  def search_by_email(email)
    record(:search, email)
    @search_hit
  end

  def create_contact(attrs)
    record(:create_contact, attrs)
    { "id" => (@next_id += 1), "email" => attrs[:email] }
  end

  def create_interaction(attrs)
    record(:create_interaction, attrs)
    { "id" => (@next_id += 1) }
  end

  def add_segment(contact_id, email:, realm:, segment:)
    record(:add_segment, { contact_id: contact_id, email: email, realm: realm, segment: segment })
    { "realm" => realm, "segment" => segment }
  end

  private

  def record(verb, payload)
    if @raise_on == verb
      err = @raise_class.new("crm:http_#{@http_status}")
      err.http_status ||= @http_status # ContractError / RateLimitedError portent le leur
      raise err
    end
    @calls << [ verb, payload ]
  end
end

# Branche un faux client sur `job_class#build_client` le temps du bloc,
# via un module préfixé neutralisé ensuite (un module préfixé ne se
# retire pas : on le rend transparent par `super`).
module CrmClientStubbing
  def stub_crm_client(job_class, client)
    stub_mod = Module.new { define_method(:build_client) { client } }
    job_class.prepend(stub_mod)
    yield
  ensure
    stub_mod&.module_eval { define_method(:build_client) { super() } }
  end

  def with_rails_logger(logger)
    original = Rails.logger
    Rails.logger = logger
    yield
  ensure
    Rails.logger = original
  end

  # Configuration du VRAI client CRM le temps du bloc (nil = variable absente).
  CRM_ENV = %w[CRM_API_TOKEN CRM_BASE_URL].freeze

  def with_crm_env(values)
    previous = CRM_ENV.index_with { |key| ENV[key] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # Une configuration incomplète par variable du client : jeton seul, URL seule.
  UNCONFIGURED_CRM = {
    "CRM_BASE_URL" => { "CRM_API_TOKEN" => "t-test", "CRM_BASE_URL" => nil },
    "CRM_API_TOKEN" => { "CRM_API_TOKEN" => nil, "CRM_BASE_URL" => "https://ops.test" }
  }.freeze

  # Lance `perform` avec le vrai client mal configuré ; rend le journal, par variable manquante.
  def unconfigured_crm_logs
    UNCONFIGURED_CRM.to_h do |variable, env|
      io = StringIO.new
      with_crm_env(env) { with_rails_logger(Logger.new(io)) { yield } }
      [ variable, io.string ]
    end
  end
end
