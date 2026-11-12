# frozen_string_literal: true

require "test_helper"

# CrmNotifyNextJob — « Pas dispo, préviens-moi du suivant » : une demande
# confirmée entre au CRM comme participant avec une interaction dédiée.
class CrmNotifyNextJobTest < ActiveJob::TestCase
  include CrmClientStubbing

  setup do
    @prev_flag = ENV["CRM_SYNC_ENABLED"]
    ENV["CRM_SYNC_ENABLED"] = "1"
    @request = RegistrationRequest.create!(
      name: "Camille", email: "camille@example.test", source: "tartiflette.dev",
      profile: "fabrication", message: "Prévenez-moi en avance svp.", notify_next: true,
      confirmed_at: Time.current
    )
    @client = FakeCrmClient.new
  end

  teardown { ENV["CRM_SYNC_ENABLED"] = @prev_flag }

  test "demande confirmée : fiche, segment participant, interaction « prochain café »" do
    perform_with(@client)

    assert_equal %i[search create_contact add_segment create_interaction], @client.verbs
    assert_equal({ contact_id: 1001, email: "camille@example.test", realm: "professional", segment: "participant" },
                 @client.payloads(:add_segment).first)
    interaction = @client.payloads(:create_interaction).first
    assert_equal "Veut être prévenu·e du prochain Café IA", interaction[:title]
    assert_equal "live.example.test:notify_next", interaction[:source]
    assert_match(/Provenance : tartiflette\.dev/, interaction[:notes])
    assert_match(/Profil : fabrication/, interaction[:notes])
    assert_match(/Message : Prévenez-moi en avance svp\./, interaction[:notes])
    @request.reload
    assert_not_nil @request.pushed_to_crm_at
    assert_equal "1001", @request.crm_contact_id
    assert_equal 1, @request.crm_sync_attempts
  end

  test "drapeau off, non confirmée ou sans « préviens-moi » : zéro HTTP" do
    ENV["CRM_SYNC_ENABLED"] = "0"
    perform_with(@client)
    ENV["CRM_SYNC_ENABLED"] = "1"
    @request.update!(confirmed_at: nil)
    perform_with(@client)
    @request.update!(confirmed_at: Time.current, notify_next: false)
    perform_with(@client)

    assert_empty @client.calls
    assert_nil @request.reload.pushed_to_crm_at
  end

  test "rejeu après succès : idempotent" do
    perform_with(@client)
    second = FakeCrmClient.new
    perform_with(second)
    assert_empty second.calls
  end

  test "fiche existante : pas de création" do
    client = FakeCrmClient.new(search_hit: { "id" => 9, "email" => "camille@example.test" })
    perform_with(client)
    assert_equal %i[search add_segment create_interaction], client.verbs
  end

  test "5xx : raise et consigne le code, sans PII dans les logs" do
    io = StringIO.new
    failing = FakeCrmClient.new(raise_on: :create_interaction, http_status: 503)
    with_rails_logger(Logger.new(io)) do
      assert_raises(Crm::TransientError) do
        stub_crm_client(CrmNotifyNextJob, failing) { CrmNotifyNextJob.new.perform(@request.id) }
      end
    end
    @request.reload
    assert_nil @request.pushed_to_crm_at
    assert_equal 503, @request.crm_last_error_code
    assert_equal "1001", @request.crm_contact_id
    assert_match(/registration_request_id=#{@request.id}/, io.string)
    assert_no_match(/camille/i, io.string)
  end

  test "4xx : discard, code consigné, sans PII" do
    io = StringIO.new
    failing = FakeCrmClient.new(raise_on: :add_segment, raise_class: Crm::PermanentError, http_status: 422)
    with_rails_logger(Logger.new(io)) do
      stub_crm_client(CrmNotifyNextJob, failing) do
        assert_nothing_raised { CrmNotifyNextJob.perform_now(@request.id) }
      end
    end
    assert_equal 422, @request.reload.crm_last_error_code
    assert_not_includes failing.verbs, :create_interaction
    assert_no_match(/camille/i, io.string)
  end

  test "client non configuré (URL ou jeton absents) : discard, la variable à poser journalisée, sans PII" do
    logs = unconfigured_crm_logs { assert_nothing_raised { CrmNotifyNextJob.perform_now(@request.id) } }

    logs.each do |variable, log|
      assert_match(/reason=crm_unconfigured variable=#{variable}$/, log)
      assert_no_match(/missing_api_token|camille/i, log)
    end
  end

  private

  def perform_with(client)
    stub_crm_client(CrmNotifyNextJob, client) { CrmNotifyNextJob.perform_now(@request.id) }
  end
end
