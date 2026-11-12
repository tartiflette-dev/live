# frozen_string_literal: true

require "test_helper"

# CrmSyncJob — sémantique : tout inscrit confirmé entre au
# CRM comme participant (fiche + segment + interaction) ; le consentement
# marketing est une poussée distincte, retirable, seule autorisation de
# prospection.
#
# Garde-fous testés :
#   - drapeau CRM_SYNC_ENABLED off → zéro HTTP, aucune mutation.
#   - inscription non confirmée → zéro HTTP.
#   - confirmée sans consentement → participant poussé, pas de consentement.
#   - confirmée avec consentement → participant + consentement.
#   - rejeu → zéro HTTP (idempotence des deux marqueurs).
#   - retrait avant / pendant l'envoi → le consentement n'est pas poussé
#     ou son retrait est propagé ; le participant reste.
#   - CRM 5xx → raise TransientError + code ; 4xx → discard + code.
#   - jamais de PII dans les logs.
class CrmSyncJobTest < ActiveJob::TestCase
  include CrmClientStubbing

  setup do
    @prev_flag = ENV["CRM_SYNC_ENABLED"]
    ENV["CRM_SYNC_ENABLED"] = "1"
    @webinar = Webinar.create!(
      title: "Café IA 42", starts_at: 1.day.from_now, host_sub: "sub-host", visibility: "published"
    )
    @registration = Registration.create!(
      webinar: @webinar, name: "Alice Dupont", email: "alice@example.test",
      confirmed_at: Time.current, crm_enrolled_at: Time.current
    )
    @client = FakeCrmClient.new
  end

  teardown do
    ENV["CRM_SYNC_ENABLED"] = @prev_flag
  end

  test "drapeau off : zéro HTTP, aucune mutation" do
    ENV["CRM_SYNC_ENABLED"] = "0"
    perform_with(@client)
    assert_empty @client.calls
    assert_nil @registration.reload.pushed_to_crm_at
  end

  test "non confirmé : zéro HTTP" do
    @registration.update!(confirmed_at: nil)
    perform_with(@client)
    assert_empty @client.calls
    assert_nil @registration.reload.pushed_to_crm_at
  end

  test "confirmé sous la politique v1.0 (sans entrée CRM) : zéro HTTP, pas de rétroactivité" do
    @registration.update!(crm_enrolled_at: nil)
    perform_with(@client)
    assert_empty @client.calls
    assert_nil @registration.reload.pushed_to_crm_at
  end

  test "confirmé SANS consentement marketing : la personne entre au CRM comme participant" do
    perform_with(@client)

    assert_equal %i[search create_contact add_segment create_interaction], @client.verbs
    contact = @client.payloads(:create_contact).first
    assert_equal "Alice", contact[:first_name]
    assert_equal "Dupont", contact[:last_name]
    assert_equal "alice@example.test", contact[:email]
    segment = @client.payloads(:add_segment).first
    assert_equal({ contact_id: 1001, email: "alice@example.test", realm: "professional", segment: "participant" }, segment)
    interaction = @client.payloads(:create_interaction).first
    assert_equal 1001, interaction[:contact_id]
    assert_equal "form", interaction[:kind]
    assert_equal "Inscription webinaire — Café IA 42", interaction[:title]
    assert_equal "live.example.test:#{@webinar.slug}", interaction[:source]
    assert_no_match(/Provenance/, interaction[:notes], "inscription du formulaire HTML : pas de provenance")

    @registration.reload
    assert_not_nil @registration.pushed_to_crm_at
    assert_equal "1001", @registration.crm_contact_id
    assert_nil @registration.crm_last_error_code
    assert_equal 1, @registration.crm_sync_attempts
    assert_nil @registration.crm_marketing_consent_pushed_at, "aucun consentement à pousser"
  end

  test "inscription venue de l'API : provenance, profil et message en notes d'interaction" do
    request = RegistrationRequest.create!(
      name: "Alice", email: "alice@example.test", source: "tartiflette.dev", profile: "dev",
      message: "Je viens avec une question sur les agents."
    )
    @registration.update!(registration_request: request)

    perform_with(@client)

    notes = @client.payloads(:create_interaction).first[:notes]
    assert_match(/Provenance : tartiflette\.dev/, notes)
    assert_match(/Profil : dev/, notes)
    assert_match(/Message : Je viens avec une question sur les agents\./, notes)
  end

  # Le choix part dans les notes, seul champ libre du
  # contrat CRM (segment et source_path inchangés).
  test "le choix spectateur / participant part dans les notes d'interaction, segment et source inchangés" do
    { "spectator" => "Choix : spectateur", "participant" => "Choix : participant (intervenir en caméra et micro)" }.each do |participation, line|
      client = FakeCrmClient.new
      @registration = Registration.create!(webinar: @webinar, name: "Inès", email: "#{participation}@example.test",
                                           participation: participation, confirmed_at: Time.current, crm_enrolled_at: Time.current)

      perform_with(client)

      interaction = client.payloads(:create_interaction).first
      assert_includes interaction[:notes].lines.map(&:chomp).second, line
      assert_equal "/w/#{@webinar.slug}", interaction[:source_path]
      assert_equal "participant", client.payloads(:add_segment).first[:segment]
    end
  end

  test "contact déjà présent côté CRM : pas de create, segment posé sur la fiche existante" do
    client = FakeCrmClient.new(search_hit: { "id" => 777, "email" => "alice@example.test" })
    perform_with(client)
    assert_equal %i[search add_segment create_interaction], client.verbs
    assert_equal 777, client.payloads(:add_segment).first[:contact_id]
    assert_equal "777", @registration.reload.crm_contact_id
  end

  test "confirmé AVEC consentement marketing : participant puis consentement, deux marqueurs" do
    @registration.update!(marketing_consent: true, marketing_consent_at: 1.hour.ago)
    perform_with(@client)

    assert_equal %i[search create_contact add_segment create_interaction create_interaction], @client.verbs
    consent = @client.payloads(:create_interaction).last
    assert_equal "Consentement marketing", consent[:title]
    assert_equal "live.example.test:marketing_consent:#{@webinar.slug}", consent[:source]
    assert_equal 1001, consent[:contact_id]
    @registration.reload
    assert_not_nil @registration.pushed_to_crm_at
    assert_not_nil @registration.crm_marketing_consent_pushed_at
  end

  test "participant déjà poussé, consentement validé ensuite : seule l'interaction de consentement part" do
    @registration.update!(pushed_to_crm_at: 1.day.ago, crm_contact_id: "555",
                          marketing_consent: true, marketing_consent_at: Time.current)
    perform_with(@client)
    assert_equal %i[create_interaction], @client.verbs
    assert_equal 555, @client.payloads(:create_interaction).first[:contact_id]
    assert_not_nil @registration.reload.crm_marketing_consent_pushed_at
  end

  test "rejeu après succès : idempotent, aucune requête" do
    @registration.update!(marketing_consent: true, marketing_consent_at: Time.current)
    perform_with(@client)
    first_pushed = @registration.reload.pushed_to_crm_at

    second_client = FakeCrmClient.new
    perform_with(second_client)

    assert_empty second_client.calls, "une 2e exécution ne doit émettre AUCUN appel"
    assert_equal first_pushed, @registration.reload.pushed_to_crm_at
  end

  test "consentement retiré avant le job : participant poussé, consentement jamais poussé" do
    @registration.update!(marketing_consent: false, marketing_consent_at: 1.day.ago,
                          marketing_consent_withdrawn_at: Time.current)
    perform_with(@client)
    assert_equal %i[search create_contact add_segment create_interaction], @client.verbs
    assert_nil @registration.reload.crm_marketing_consent_pushed_at
  end

  test "CRM 5xx (transient) : raise, consigne le code HTTP SEUL, pas de pushed_to_crm_at" do
    failing = FakeCrmClient.new(raise_on: :search, raise_class: Crm::TransientError, http_status: 502)
    assert_raises(Crm::TransientError) do
      stub_crm_client(CrmSyncJob, failing) { CrmSyncJob.new.perform(@registration.id) }
    end
    @registration.reload
    assert_nil @registration.pushed_to_crm_at
    assert_equal 1, @registration.crm_sync_attempts
    assert_equal 502, @registration.crm_last_error_code
  end

  test "CRM 4xx (permanent) : discard_on consigne le code HTTP et abandonne" do
    failing = FakeCrmClient.new(raise_on: :create_contact, raise_class: Crm::PermanentError, http_status: 422)
    stub_crm_client(CrmSyncJob, failing) do
      assert_nothing_raised { CrmSyncJob.perform_now(@registration.id) }
    end
    assert_nil @registration.reload.pushed_to_crm_at
    assert_equal 422, @registration.reload.crm_last_error_code
  end

  test "segment refusé (endpoint CRM absent) : abandon AVANT l'interaction, fiche tracée" do
    failing = FakeCrmClient.new(raise_on: :add_segment, raise_class: Crm::PermanentError, http_status: 404)
    stub_crm_client(CrmSyncJob, failing) { CrmSyncJob.perform_now(@registration.id) }
    assert_equal %i[search create_contact], failing.verbs
    @registration.reload
    assert_nil @registration.pushed_to_crm_at
    assert_equal 404, @registration.crm_last_error_code
    assert_equal "1001", @registration.crm_contact_id, "la fiche créée reste rattachée pour la reprise et le retrait"
  end

  test "SÉCURITÉ : logs du job ne portent AUCUN PII (email, nom)" do
    io = StringIO.new
    with_rails_logger(Logger.new(io)) do
      failing = FakeCrmClient.new(raise_on: :create_contact, raise_class: Crm::PermanentError, http_status: 422)
      stub_crm_client(CrmSyncJob, failing) { CrmSyncJob.perform_now(@registration.id) }
    end
    log_output = io.string
    assert_match(/registration_id=#{@registration.id}/, log_output)
    assert_match(/http_status=422/, log_output)
    assert_no_match(/alice@example\.test/, log_output, "email jamais loggué")
    assert_no_match(/Alice/, log_output, "prénom jamais loggué")
    assert_no_match(/Dupont/, log_output, "nom jamais loggué")
  end

  test "client non configuré (URL ou jeton absents) : discard, la variable à poser journalisée, sans PII" do
    logs = unconfigured_crm_logs { assert_nothing_raised { CrmSyncJob.perform_now(@registration.id) } }

    logs.each do |variable, log|
      assert_match(/reason=crm_unconfigured variable=#{variable}$/, log)
      assert_no_match(/missing_api_token|alice|dupont/i, log)
    end
    assert_nil @registration.reload.pushed_to_crm_at
  end

  test "autre ArgumentError : discard, raison générique, jamais son message" do
    io = StringIO.new
    with_rails_logger(Logger.new(io)) do
      stub = Module.new { define_method(:build_client) { raise ArgumentError, "adresse alice@example.test refusée" } }
      CrmSyncJob.prepend(stub)
      begin
        assert_nothing_raised { CrmSyncJob.perform_now(@registration.id) }
      ensure
        stub.module_eval { define_method(:build_client) { super() } }
      end
    end
    assert_match(/reason=argument_error$/, io.string)
    assert_no_match(/alice/i, io.string)
  end

  test "SÉCURITÉ : logs transient ne portent AUCUN PII (email, nom)" do
    io = StringIO.new
    with_rails_logger(Logger.new(io)) do
      failing = FakeCrmClient.new(raise_on: :search, raise_class: Crm::TransientError, http_status: 500)
      assert_raises(Crm::TransientError) do
        stub_crm_client(CrmSyncJob, failing) { CrmSyncJob.new.perform(@registration.id) }
      end
    end
    log_output = io.string
    assert_match(/http_status=500/, log_output)
    assert_no_match(/alice@example\.test/, log_output)
    assert_no_match(/Alice/, log_output)
    assert_no_match(/Dupont/, log_output)
  end

  # ---- Retrait concurrent -----------------

  test "interleaving : retrait pendant la poussée du participant → participant poussé, consentement NON poussé" do
    @registration.update!(marketing_consent: true, marketing_consent_at: Time.current)
    registration = @registration
    client = FakeCrmClient.new
    client.define_singleton_method(:create_contact) do |attrs|
      registration.update!(marketing_consent: false, marketing_consent_withdrawn_at: Time.current)
      super(attrs)
    end
    perform_with(client)

    assert_equal 1, client.payloads(:create_interaction).size, "jamais d'interaction de consentement après un retrait"
    @registration.reload
    assert_not_nil @registration.crm_contact_id, "crm_contact_id persisté dès la fiche connue"
    assert_not_nil @registration.pushed_to_crm_at, "le retrait n'empêche pas l'entrée du participant"
    assert_nil @registration.crm_marketing_consent_pushed_at
  end

  test "interleaving : retrait PENDANT l'envoi du consentement → enqueue CrmMarketingWithdrawalJob" do
    @registration.update!(pushed_to_crm_at: 1.day.ago, crm_contact_id: "42",
                          marketing_consent: true, marketing_consent_at: Time.current)
    registration = @registration
    client = FakeCrmClient.new
    client.define_singleton_method(:create_interaction) do |attrs|
      registration.update!(marketing_consent: false, marketing_consent_withdrawn_at: Time.current)
      super(attrs)
    end
    assert_enqueued_with(job: CrmMarketingWithdrawalJob, args: [ @registration.id ]) do
      perform_with(client)
    end
    @registration.reload
    assert_not_nil @registration.crm_marketing_consent_pushed_at, "l'envoi a eu lieu avant le retrait"
    assert @registration.marketing_consent_withdrawn?
  end

  test "registration disparue : discard sans exception" do
    @registration.destroy!
    stub_crm_client(CrmSyncJob, @client) do
      assert_nothing_raised { CrmSyncJob.perform_now(@registration.id) }
    end
    assert_empty @client.calls
  end

  # ---- Un job CRM à la fois par personne --------------------------------

  test "clé de concurrence partagée par les jobs CRM d'une même personne, sans email en clair" do
    other_webinar = Webinar.create!(title: "Café IA 43", starts_at: 2.days.from_now, host_sub: "h", visibility: "published")
    sibling = other_webinar.registrations.create!(name: "Alice", email: "alice@example.test")
    request = RegistrationRequest.create!(name: "Alice", email: "alice@example.test", notify_next: true)
    stranger = other_webinar.registrations.create!(name: "Bob", email: "bob@example.test")

    keys = [
      CrmSyncJob.new(@registration.id).concurrency_key,
      CrmSyncJob.new(sibling.id).concurrency_key,
      CrmMarketingWithdrawalJob.new(@registration.id).concurrency_key,
      CrmNotifyNextJob.new(request.id).concurrency_key
    ]
    assert_equal 1, keys.uniq.size
    assert_not_equal keys.first, CrmSyncJob.new(stranger.id).concurrency_key
    assert_no_match(/alice/i, keys.first)
    assert_equal 1, CrmSyncJob.concurrency_limit
  end

  private

  def perform_with(client)
    stub_crm_client(CrmSyncJob, client) { CrmSyncJob.perform_now(@registration.id) }
  end
end
