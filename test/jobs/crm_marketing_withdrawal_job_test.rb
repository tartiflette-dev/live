require "test_helper"

class CrmMarketingWithdrawalJobTest < ActiveJob::TestCase
  include CrmClientStubbing

  class FakeClient
    attr_reader :calls

    def initialize(search_hit: nil, raise_on: nil, http_status: 500)
      @search_hit  = search_hit
      @raise_on    = raise_on
      @http_status = http_status
      @calls       = []
    end

    def search_by_email(email)
      @calls << [ :search, email ]
      @search_hit
    end

    def create_interaction(attrs)
      if @raise_on == :create_interaction
        err = Crm::TransientError.new("crm:http_#{@http_status}")
        err.http_status = @http_status
        raise err
      end
      @calls << [ :create_interaction, attrs ]
      { "id" => 999 }
    end
  end

  setup do
    @prev_flag = ENV["CRM_SYNC_ENABLED"]
    ENV["CRM_SYNC_ENABLED"] = "1"
    @webinar = Webinar.create!(
      title: "Café IA", starts_at: 1.day.from_now, host_sub: "host", visibility: "published"
    )
    @registration = @webinar.registrations.create!(
      name: "Alice", email: "alice@example.test", confirmed_at: Time.current,
      pushed_to_crm_at: Time.current, crm_contact_id: "42",
      marketing_consent_withdrawn_at: Time.current
    )
    @client = FakeClient.new
  end

  teardown { ENV["CRM_SYNC_ENABLED"] = @prev_flag }

  test "drapeau off : zéro HTTP" do
    ENV["CRM_SYNC_ENABLED"] = "0"
    stub_client(@client) { CrmMarketingWithdrawalJob.perform_now(@registration.id) }
    assert_empty @client.calls
  end

  test "sans crm_contact_id ni correspondance search : no-op (rien à retirer)" do
    @registration.update!(pushed_to_crm_at: nil, crm_contact_id: nil)
    client = FakeClient.new(search_hit: nil)
    stub_client(client) { CrmMarketingWithdrawalJob.perform_now(@registration.id) }
    # On a bien tenté search_by_email, mais aucune interaction poussée.
    verbs = client.calls.map(&:first)
    assert_equal [ :search ], verbs
    assert_nil @registration.reload.crm_withdrawal_pushed_at
  end

  test "sans crm_contact_id mais contact TROUVÉ par email : interaction de retrait propagée" do
    # Scénario critique : CrmSyncJob a tourné,
    # créé le contact côté CRM, puis crashé avant de persister
    # `crm_contact_id`. Un retrait doit quand même propager.
    @registration.update!(pushed_to_crm_at: nil, crm_contact_id: nil)
    client = FakeClient.new(search_hit: { "id" => 777, "email" => "alice@example.test" })
    stub_client(client) { CrmMarketingWithdrawalJob.perform_now(@registration.id) }
    verbs = client.calls.map(&:first)
    assert_equal [ :search, :create_interaction ], verbs
    payload = client.calls.find { |v, _| v == :create_interaction }.last
    assert_equal 777, payload[:contact_id]
    # Après succès, on persiste aussi le contact_id localement.
    assert_equal "777", @registration.reload.crm_contact_id
    assert_not_nil @registration.reload.crm_withdrawal_pushed_at
  end

  test "contact présent : POST interaction `kind=form` source withdrawal:<slug>" do
    stub_client(@client) { CrmMarketingWithdrawalJob.perform_now(@registration.id) }
    # Avec crm_contact_id posé en setup, pas de search — directement interaction.
    verbs = @client.calls.map(&:first)
    assert_equal [ :create_interaction ], verbs
    payload = @client.calls.find { |v, _| v == :create_interaction }.last
    assert_equal 42, payload[:contact_id]
    assert_equal "form", payload[:kind]
    assert_equal "live.example.test:withdrawal:#{@webinar.slug}", payload[:source]
    assert_match(/Retrait du consentement/i, payload[:title])
  end

  test "transient : raise, log sans PII" do
    failing = FakeClient.new(raise_on: :create_interaction, http_status: 502)
    io = StringIO.new
    original = Rails.logger
    Rails.logger = Logger.new(io)
    begin
      assert_raises(Crm::TransientError) do
        stub_client(failing) { CrmMarketingWithdrawalJob.new.perform(@registration.id) }
      end
    ensure
      Rails.logger = original
    end
    assert_match(/http_status=502/, io.string)
    assert_no_match(/alice@example\.test/, io.string)
    assert_no_match(/\bAlice\b/, io.string)
  end

  test "échecs du retrait comptés sur SON compteur, jamais sur celui de l'inscription" do
    @registration.update!(crm_sync_attempts: 7, crm_last_error_code: 503)
    transient = FakeClient.new(raise_on: :create_interaction, http_status: 502)
    assert_raises(Crm::TransientError) do
      stub_client(transient) { CrmMarketingWithdrawalJob.new.perform(@registration.id) }
    end
    @registration.reload
    assert_equal 1, @registration.crm_withdrawal_attempts
    assert_equal 502, @registration.crm_withdrawal_last_error_code
    assert_not_nil @registration.crm_withdrawal_last_attempt_at
    assert_equal [ 7, 503 ], [ @registration.crm_sync_attempts, @registration.crm_last_error_code ], "inscription intacte"

    stub_client(FakeClient.new) { CrmMarketingWithdrawalJob.perform_now(@registration.id) }
    assert @registration.reload.crm_withdrawal_pushed?
    assert_nil @registration.crm_withdrawal_last_error_code, "succès : erreur du retrait effacée"
  end

  test "idempotent : si crm_withdrawal_pushed_at posé, aucun appel HTTP" do
    @registration.update!(
      marketing_consent_withdrawn_at: Time.current,
      crm_withdrawal_pushed_at: Time.current
    )
    stub_client(@client) { CrmMarketingWithdrawalJob.perform_now(@registration.id) }
    assert_empty @client.calls
  end

  test "pose atomique de crm_withdrawal_pushed_at après succès HTTP" do
    stub_client(@client) { CrmMarketingWithdrawalJob.perform_now(@registration.id) }
    assert_not_nil @registration.reload.crm_withdrawal_pushed_at
    # Rejeu : plus aucun HTTP (idempotent user double-click + retry).
    second = FakeClient.new
    stub_client(second) { CrmMarketingWithdrawalJob.perform_now(@registration.id) }
    assert_empty second.calls
  end

  test "pas retiré : pas de push (défense en profondeur)" do
    @registration.update!(marketing_consent_withdrawn_at: nil)
    stub_client(@client) { CrmMarketingWithdrawalJob.perform_now(@registration.id) }
    assert_empty @client.calls
  end

  test "client non configuré (URL ou jeton absents) : discard, la variable à poser journalisée, sans PII" do
    logs = unconfigured_crm_logs { assert_nothing_raised { CrmMarketingWithdrawalJob.perform_now(@registration.id) } }

    logs.each do |variable, log|
      assert_match(/reason=crm_unconfigured variable=#{variable}$/, log)
      assert_no_match(/missing_api_token|alice/i, log)
    end
  end

  private

  def stub_client(client)
    stub_mod = Module.new { define_method(:build_client) { client } }
    CrmMarketingWithdrawalJob.prepend(stub_mod)
    yield
  ensure
    stub_mod&.module_eval { define_method(:build_client) { super() } }
  end
end
