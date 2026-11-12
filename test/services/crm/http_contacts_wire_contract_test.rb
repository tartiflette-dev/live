# frozen_string_literal: true

require "test_helper"

# Contrat de bout en bout côté live : les jobs CRM, avec le VRAI
# Crm::HttpContactsClient, émettent sur le réseau ce que le contrat HTTP
# du CRM accepte (docs/registrations-api.md). Le faux client des
# tests de jobs ne voit pas la forme HTTP : ce test la fige.
#
# Net::HTTP est remplacé par un faux CRM qui APPLIQUE ce contrat comme le
# ferait le serveur : clé hors contrat ou contrainte violée → 422
# `param_policy` ; écriture sur une fiche sans email-preuve
# concordant → 404 `not_found` ; réponses minimales (`{id, email,
# segments}`, interaction `{id}`) ; `?search=` interdit (403).
class Crm::HttpContactsWireContractTest < ActiveJob::TestCase
  # `[]` = en-tête, comme Net::HTTPResponse (Retry-After d'un 429).
  ContractResponse = Struct.new(:code, :body, :headers) do
    def [](name) = headers.to_h[name]
  end
  ENV_KEYS = %w[CRM_SYNC_ENABLED CRM_API_TOKEN CRM_BASE_URL].freeze
  SEGMENT = { "realm" => "professional", "segment" => "participant" }.freeze

  class FakeCrmServer
    attr_reader :requests, :contacts

    # contacts : { id => email } déjà en base.
    # fail_after_write : titres d'interaction enregistrés puis répondus 502
    # une fois (écriture faite, réponse perdue).
    def initialize(contacts: {}, fail_after_write: [])
      @contacts = contacts.dup
      @next_id = 77
      @requests = []
      @fail_after_write = fail_after_write.dup
    end

    def request(req)
      path, query = req.path.split("?", 2)
      body = req.body ? JSON.parse(req.body) : {}
      params = body.merge(URI.decode_www_form(query.to_s).to_h)
      @requests << [ req.method, path, body, query ]
      route(req.method, path, params)
    end

    private

    def route(method, path, params)
      case [ method, path ]
      in [ "GET", "/api/v1/contacts/lookup" ] then lookup(params)
      in [ "GET", "/api/v1/contacts" ] then reply("403", error: "forbidden_scope")
      in [ "POST", "/api/v1/contacts" ] then create_contact(params)
      in [ "POST", %r{\A/api/v1/contacts/(\d+)/segments\z} ] then add_segment(path[%r{/contacts/(\d+)/}, 1].to_i, params)
      in [ "POST", "/api/v1/interactions" ] then create_interaction(params)
      end
    end

    def lookup(params)
      rejected = violations(params, CrmContract::LOOKUP_PERMITTED)
      return policy_refusal(rejected) if rejected.any?

      id = id_for(params["email"])
      id ? reply("200", minimal(id)) : reply("404", error: "not_found")
    end

    def create_contact(params)
      rejected = violations(params, CrmContract::CONTACT_PERMITTED)
      rejected << "email" unless params["email"].to_s.match?(URI::MailTo::EMAIL_REGEXP)
      return policy_refusal(rejected) if rejected.any?
      return reply("422", errors: [ "First name can't be blank" ]) if params["first_name"].to_s.empty?

      id = (@next_id += 1)
      @contacts[id] = params["email"]
      reply("201", minimal(id))
    end

    def add_segment(id, params)
      rejected = violations(params, CrmContract::SEGMENT_PERMITTED)
      rejected << "segment" unless params["segment"] == SEGMENT
      return policy_refusal(rejected) if rejected.any?
      return reply("404", error: "not_found") unless proven?(id, params["email"])

      reply("201", minimal(id))
    end

    def create_interaction(params)
      rejected = violations(params, CrmContract::INTERACTION_PERMITTED)
      rejected << "kind" unless params["kind"] == "form"
      rejected << "source" unless params["source"].to_s.match?(CrmContract::SOURCE)
      rejected << "source_path" unless params["source_path"].to_s.match?(CrmContract::SOURCE_PATH)
      return policy_refusal(rejected) if rejected.any?
      return reply("404", error: "not_found") unless proven?(params["contact_id"].to_i, params["email"])
      return reply("502", error: "bad_gateway") if @fail_after_write.delete(params["title"])

      reply("201", id: 5)
    end

    def violations(params, permitted)
      params.keys - permitted
    end

    def policy_refusal(rejected)
      reply("422", error: "param_policy", params: rejected)
    end

    def proven?(id, email)
      email.is_a?(String) && @contacts[id].to_s.casecmp?(email.strip)
    end

    def id_for(email)
      @contacts.find { |_, stored| stored.casecmp?(email.to_s) }&.first
    end

    def minimal(id)
      { id: id, email: @contacts[id], segments: [] }
    end

    def reply(code, payload)
      ContractResponse.new(code, JSON.generate(payload))
    end
  end

  setup do
    @saved = ENV_KEYS.index_with { |key| ENV[key] }
    ENV["CRM_SYNC_ENABLED"] = "1"
    ENV["CRM_API_TOKEN"] = "t-test"
    ENV["CRM_BASE_URL"] = "https://ops.test"
    @original_start = Net::HTTP.method(:start)
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.day.from_now, host_sub: "h", visibility: "published")
    # Publier demande la présence des animateurs (HostAttendanceRequestJob) :
    # hors sujet ici, la file repart vide.
    clear_enqueued_jobs
  end

  teardown do
    Net::HTTP.define_singleton_method(:start, @original_start)
    @saved.each { |key, value| ENV[key] = value }
  end

  test "inscription tartiflette.dev au prénom seul, avec consentement : tout passe le contrat CRM" do
    crm = serve(FakeCrmServer.new)
    request = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", source: "tartiflette.dev",
                                          profile: "dev", message: "Bonjour")
    registration, = Registration.find_or_create_for(@webinar, email: request.email, name: request.name,
                                                    registration_request: request)
    registration.confirm!
    registration.update!(marketing_consent: true, marketing_consent_at: Time.current)

    CrmSyncJob.perform_now(registration.id)

    assert_equal [ "email=camille%40example.test" ], queries_of(crm, "GET", "/api/v1/contacts/lookup")
    assert_empty requests_of(crm, "GET", "/api/v1/contacts"), "jamais ?search= (403 : hors contrat)"
    assert_equal({ "first_name" => "Camille", "last_name" => nil, "email" => "camille@example.test" },
                 bodies_of(crm, "POST", "/api/v1/contacts").first, "fiche : prénom, nom, email — sans notes")
    assert_equal({ "email" => "camille@example.test", "segment" => SEGMENT },
                 bodies_of(crm, "POST", "/api/v1/contacts/78/segments").first)
    participant, consent = bodies_of(crm, "POST", "/api/v1/interactions")
    [ participant, consent ].each do |interaction|
      assert_equal 78, interaction["contact_id"]
      assert_equal "camille@example.test", interaction["email"], "preuve par email"
      assert_empty interaction.keys - CrmContract::INTERACTION_PERMITTED
    end
    assert_equal [ "live.example.test:#{@webinar.slug}", "/w/#{@webinar.slug}" ], participant.values_at("source", "source_path")
    assert_equal [ "live.example.test:marketing_consent:#{@webinar.slug}", "/mc" ], consent.values_at("source", "source_path")
    assert_match(/Provenance : tartiflette\.dev/, participant["notes"], "la mention tartiflette.dev va en notes")
    assert_match(/^Choix : spectateur/, participant["notes"], "le choix spectateur / participant va en notes")
    assert registration.reload.crm_pushed?
    assert_equal "78", registration.crm_contact_id
    assert_not_nil registration.crm_marketing_consent_pushed_at
  end

  test "recontact accepté sur tartiflette.dev : consentement poussé avec la preuve figée à l'accord" do
    crm = serve(FakeCrmServer.new)
    request = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", source: "tartiflette.dev",
                                          marketing_box_checked: true)
    registration, = Registration.find_or_create_for(@webinar, email: request.email, name: request.name,
                                                    registration_request: request)
    request.confirm!(marketing_consent: true)
    request.update_columns(source: nil) # la preuve ne se recalcule pas
    @webinar.update_columns(kind: "bootcamp") # ni la tonalité : le libellé affiché est figé

    CrmSyncJob.perform_now(registration.id)

    _participant, consent = bodies_of(crm, "POST", "/api/v1/interactions")
    assert_equal [ "live.example.test:marketing_consent:#{@webinar.slug}", "/confirmer" ], consent.values_at("source", "source_path")
    assert_equal registration.reload.marketing_consent_at.iso8601, consent["occurred_at"]
    # Café IA : le bouton que la page a RÉELLEMENT affiché.
    assert_match(/bouton « Je confirme, et Studio Exemple peut me recontacter » de la page \/confirmer/, consent["notes"])
    assert_no_match(/Confirmer et accepter/, consent["notes"])
    assert_match(/case cochée lors d'une demande au formulaire public/, consent["notes"])
    assert_match(/provenance tartiflette\.dev, politique v#{Regexp.escape(PrivacyPolicy::VERSION)}, demande n°#{request.id} du /, consent["notes"])
    assert_empty consent.keys - CrmContract::INTERACTION_PERMITTED
    assert_not_nil registration.crm_marketing_consent_pushed_at
  end

  test "recontact accepté sur une demande de bootcamp : la note cite le bouton par défaut affiché" do
    crm = serve(FakeCrmServer.new)
    bootcamp = Webinar.create!(title: "Bootcamp", kind: "bootcamp", starts_at: 2.days.from_now, host_sub: "h",
                               visibility: "published")
    request = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", marketing_box_checked: true)
    registration, = Registration.find_or_create_for(bootcamp, email: request.email, name: request.name,
                                                    registration_request: request)
    request.confirm!(marketing_consent: true)
    assert_equal "Confirmer et accepter d'être recontacté·e", registration.reload.marketing_consent_label

    CrmSyncJob.perform_now(registration.id)

    _participant, consent = bodies_of(crm, "POST", "/api/v1/interactions")
    assert_match(/bouton « Confirmer et accepter d'être recontacté·e » de la page \/confirmer/, consent["notes"])
  end

  test "preuve sans libellé figé (accord antérieur aux libellés par émission) : le bouton par défaut, seul affiché alors" do
    assert_match(/bouton « Confirmer et accepter d'être recontacté·e »/,
                 Crm.marketing_consent_note(at: Time.current, path: "/confirmer", source: "tartiflette.dev",
                                            policy_version: "1.6"))
    assert_match(/lien dédié \/mc/, Crm.marketing_consent_note(at: Time.current, path: nil, source: nil, policy_version: nil))
    assert_match(/lien dédié \/mc \(jeton à usage unique\)/,
                 Crm.marketing_consent_note(at: Time.current, path: "/mc", source: "live.example.test",
                                            policy_version: PrivacyPolicy::VERSION),
                 "accord /mc sans libellé figé : la note cite la constante, jamais un libellé recalculé")
  end

  test "consentement via POST /mc : la note CRM cite le libellé du bouton affiché, figé à l'accord" do
    crm = serve(FakeCrmServer.new)
    registration = @webinar.registrations.create!(name: "Bob", email: "bob@example.test")
    registration.confirm!
    registration.request_marketing_consent!
    registration.apply_marketing_consent!
    assert_equal "Oui, j'accepte d'être recontacté·e", registration.reload.marketing_consent_label

    CrmSyncJob.perform_now(registration.id)

    _participant, consent = bodies_of(crm, "POST", "/api/v1/interactions")
    assert_equal [ "live.example.test:marketing_consent:#{@webinar.slug}", "/mc" ], consent.values_at("source", "source_path")
    assert_match(%r{bouton « Oui, j'accepte d'être recontacté·e » de la page /mc}, consent["notes"])
    assert_no_match(/lien dédié/, consent["notes"])
    assert_empty consent.keys - CrmContract::INTERACTION_PERMITTED
  end

  test "un rejeu de la poussée après retrait ne réaccorde rien côté CRM" do
    crm = serve(FakeCrmServer.new)
    first_request = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", marketing_box_checked: true)
    first, = Registration.find_or_create_for(@webinar, email: first_request.email, name: "Camille",
                                             registration_request: first_request)
    first_request.confirm!(marketing_consent: true)
    other_webinar = Webinar.create!(title: "Café IA 2", starts_at: 9.days.from_now, host_sub: "h", visibility: "published")
    second_request = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", marketing_box_checked: true)
    second, = Registration.find_or_create_for(other_webinar, email: second_request.email, name: "Camille",
                                              registration_request: second_request)
    second_request.confirm!(marketing_consent: true)

    CrmSyncJob.perform_now(first.id)
    Registration.withdraw_marketing_consent_of("camille@example.test")
    CrmSyncJob.perform_now(second.id) # poussée du 2e café, rejouée après le retrait
    CrmSyncJob.perform_now(first.id)

    consents = bodies_of(crm, "POST", "/api/v1/interactions").select { |body| body["title"] == "Consentement marketing" }
    assert_equal [ "live.example.test:marketing_consent:#{@webinar.slug}" ], consents.map { |body| body["source"] },
                 "seul le consentement poussé AVANT le retrait est parti"
    assert_nil second.reload.crm_marketing_consent_pushed_at
    assert first.reload.marketing_consent_withdrawn? && second.marketing_consent_withdrawn?
  end

  test "« préviens-moi » seul accepté puis retiré — consentement et retrait par le chemin notify_next" do
    crm = serve(FakeCrmServer.new)
    request = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", notify_next: true,
                                          source: "tartiflette.dev", marketing_box_checked: true)
    request.confirm!(marketing_consent: true)

    CrmNotifyNextJob.perform_now(request.id)
    notify, consent = bodies_of(crm, "POST", "/api/v1/interactions")
    assert_equal "live.example.test:notify_next", notify["source"]
    assert_equal [ "live.example.test:marketing_consent:notify_next", "/confirmer" ], consent.values_at("source", "source_path")
    assert_match(/provenance tartiflette\.dev, politique v#{Regexp.escape(PrivacyPolicy::VERSION)}, demande n°#{request.id}/, consent["notes"])
    assert_match(/bouton « Je confirme, et Studio Exemple peut me recontacter »/, consent["notes"], "« préviens-moi » = Café IA")
    assert_not_includes RegistrationRequest.crm_pending, request.reload

    RegistrationRequest.withdraw_marketing_consent_of("lou@example.test")
    assert_includes RegistrationRequest.crm_pending, request.reload, "la reprise voit le retrait à propager"
    CrmNotifyNextJob.perform_now(request.id)
    CrmNotifyNextJob.perform_now(request.id)

    titles = bodies_of(crm, "POST", "/api/v1/interactions").map { |body| body["title"] }
    assert_equal [ "Veut être prévenu·e du prochain Café IA", "Consentement marketing", "Retrait du consentement marketing" ], titles
    withdrawal = bodies_of(crm, "POST", "/api/v1/interactions").last
    assert_equal [ "live.example.test:withdrawal:notify_next", "/mc/withdraw" ], withdrawal.values_at("source", "source_path")
    assert_not_includes RegistrationRequest.crm_pending, request.reload
  end

  test "« préviens-moi » — consentement enregistré par le CRM mais 502, puis retrait : le retrait part" do
    crm = serve(FakeCrmServer.new(fail_after_write: [ "Consentement marketing" ]))
    request = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", notify_next: true,
                                          marketing_box_checked: true)
    request.confirm!(marketing_consent: true)

    CrmNotifyNextJob.perform_now(request.id) # 502 : retry_on replanifie
    assert_nil request.reload.crm_marketing_consent_pushed_at, "réponse perdue : non marqué poussé"

    RegistrationRequest.withdraw_marketing_consent_of("lou@example.test")
    assert_includes RegistrationRequest.crm_pending, request.reload, "la reprise voit le retrait"
    CrmNotifyNextJob.perform_now(request.id)

    titles = bodies_of(crm, "POST", "/api/v1/interactions").map { |body| body["title"] }
    assert_equal [ "Veut être prévenu·e du prochain Café IA", "Consentement marketing",
                   "Retrait du consentement marketing" ], titles
    assert_not_nil request.reload.crm_withdrawal_pushed_at
    assert_not_includes RegistrationRequest.crm_pending, request
  end

  test "fiche existante trouvée par lookup : pas de création" do
    crm = serve(FakeCrmServer.new(contacts: { 55 => "Camille@Example.test" }))
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test")
    registration.confirm!

    CrmSyncJob.perform_now(registration.id)

    assert_empty bodies_of(crm, "POST", "/api/v1/contacts")
    assert_equal "55", registration.reload.crm_contact_id
    assert registration.crm_pushed?
  end

  test "« préviens-moi » seul : source live.example.test:notify_next, source_path /confirmer" do
    crm = serve(FakeCrmServer.new)
    request = RegistrationRequest.create!(name: "Lou Martin", email: "lou@example.test", notify_next: true,
                                          source: "tartiflette.dev")
    request.confirm!

    CrmNotifyNextJob.perform_now(request.id)

    assert_equal [ "Lou", "Martin" ], bodies_of(crm, "POST", "/api/v1/contacts").first.values_at("first_name", "last_name")
    interaction = bodies_of(crm, "POST", "/api/v1/interactions").first
    assert_equal [ "live.example.test:notify_next", "/confirmer" ], interaction.values_at("source", "source_path")
    assert request.reload.crm_pushed?
  end

  test "retrait : interaction au préfixe live.example.test, source_path /mc/withdraw, preuve par email" do
    crm = serve(FakeCrmServer.new(contacts: { 77 => "camille@example.test" }))
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test",
                                                  crm_contact_id: "77", marketing_consent_withdrawn_at: Time.current)

    CrmMarketingWithdrawalJob.perform_now(registration.id)

    interaction = bodies_of(crm, "POST", "/api/v1/interactions").first
    assert_equal [ "live.example.test:withdrawal:#{@webinar.slug}", "/mc/withdraw", "camille@example.test" ],
                 interaction.values_at("source", "source_path", "email")
    assert registration.reload.crm_withdrawal_pushed?
  end

  test "CRM SANS la recherche de fiche (lookup absent, 404 HTML) → aucune fiche créée, retry transitoire" do
    crm = serve(FakeCrmServer.new)
    crm.define_singleton_method(:lookup) { |_params| ContractResponse.new("404", "<!DOCTYPE html><h1>Not Found</h1>") }
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test")
    registration.confirm!

    assert_raises(Crm::TransientError) { CrmSyncJob.new.perform(registration.id) }

    assert_empty bodies_of(crm, "POST", "/api/v1/contacts"), "jamais de fiche créée sur un 404 hors contrat"
    assert_nil registration.reload.pushed_to_crm_at
    assert_equal 404, registration.crm_last_error_code
  end

  # ---- Quota du lookup (429) et fiche déjà connue -------------------

  test "429 sur le lookup : le job s'arrête sans retry, la ligne attend le Retry-After, sans échec compté" do
    crm = serve(FakeCrmServer.new)
    crm.define_singleton_method(:lookup) do |_params|
      ContractResponse.new("429", JSON.generate(error: "rate_limited"), { "Retry-After" => "7200" })
    end
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test")
    registration.confirm!
    io = StringIO.new

    freeze_time do
      with_logger(Logger.new(io)) { CrmSyncJob.perform_now(registration.id) }

      assert_no_enqueued_jobs(only: CrmSyncJob) # pas de retry SolidQueue qui brûlerait le quota
      assert_equal 1, queries_of(crm, "GET", "/api/v1/contacts/lookup").size
      assert_empty bodies_of(crm, "POST", "/api/v1/contacts")
      registration.reload
      assert_equal 429, registration.crm_last_error_code
      assert_equal 0, registration.crm_sync_attempts
      assert_equal 2.hours.from_now, registration.crm_next_attempt_at
      assert_match(/rate_limited registration_id=#{registration.id} http_status=429 retry_in=7200/, io.string)
      assert_no_match(/camille/i, io.string)
      assert_not Crm::Backlog.new.items.first.permanent_failure?
    end

    travel 119.minutes do
      CrmResyncJob.perform_now
      assert_no_enqueued_jobs(only: CrmSyncJob)
    end
    travel 121.minutes do
      CrmResyncJob.perform_now
      assert_enqueued_with(job: CrmSyncJob, args: [ registration.id ])
    end
  end

  test "429 sur le relookup d'un retrait : même report, sur le compteur du retrait" do
    crm = serve(FakeCrmServer.new(contacts: { 90 => "camille@example.test" }))
    crm.define_singleton_method(:lookup) { |_params| ContractResponse.new("429", "{}", { "Retry-After" => "30" }) }
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test",
                                                  crm_contact_id: "77", marketing_consent_withdrawn_at: Time.current)
    CrmMarketingWithdrawalJob.perform_now(registration.id)

    assert_no_enqueued_jobs
    registration.reload
    assert_equal [ 429, 0 ], [ registration.crm_withdrawal_last_error_code, registration.crm_withdrawal_attempts ]
    assert_not_nil registration.crm_withdrawal_next_attempt_at
    assert_nil registration.crm_last_error_code
  end

  test "fiche déjà connue pour cet email (autre café) : aucun lookup" do
    crm = serve(FakeCrmServer.new(contacts: { 90 => "camille@example.test" }))
    other = Webinar.create!(title: "Café IA #2", starts_at: 2.days.from_now, host_sub: "h", visibility: "published")
    other.registrations.create!(name: "Camille", email: "camille@example.test", crm_contact_id: "90")
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test")
    registration.confirm!

    CrmSyncJob.perform_now(registration.id)

    assert_empty queries_of(crm, "GET", "/api/v1/contacts/lookup")
    assert_equal [ 1 ], [ requests_of(crm, "POST", "/api/v1/contacts/90/segments").size ]
    assert_equal "90", registration.reload.crm_contact_id
    assert registration.crm_pushed?
  end

  test "fiche connue périmée (fusion) : le 404 de preuve relocalise, sans créer de fiche" do
    crm = serve(FakeCrmServer.new(contacts: { 90 => "camille@example.test" }))
    RegistrationRequest.create!(name: "Camille", email: "camille@example.test", crm_contact_id: "55")
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test")
    registration.confirm!

    CrmSyncJob.perform_now(registration.id)

    assert_equal 1, queries_of(crm, "GET", "/api/v1/contacts/lookup").size, "un seul lookup, après le 404"
    assert_empty bodies_of(crm, "POST", "/api/v1/contacts")
    assert_equal "90", registration.reload.crm_contact_id
    assert registration.crm_pushed?
  end

  # ---- Fiche partie côté CRM ------
  # A. Une disparition DÉDUITE (404 de preuve + lookup vide) n'autorise
  #    JAMAIS une création : enregistrée (CrmDisappearance), la ligne passe
  #    dans l'état terminal de SA file (compté, sans 503).
  # B. Seul un effacement EXPLICITE (`crm:erase`) autorise une recréation,
  #    pour une confirmation strictement postérieure.
  # C. Retrait sur fiche introuvable = alerte (503), jamais un succès.
  # D. Pas de relocalisation pour une ligne confirmée avant un effacement.

  test "A : la ligne constate elle-même la disparition (id propre) → aucune création, terminal, pas de 503" do
    crm = serve(FakeCrmServer.new)
    registration = confirmed_registration("camille@example.test", confirmed_at: 1.hour.ago)
    registration.update!(crm_contact_id: "55")

    CrmSyncJob.perform_now(registration.id)
    CrmSyncJob.perform_now(registration.id) # rejoué : sans effet

    assert_empty bodies_of(crm, "POST", "/api/v1/contacts")
    assert_equal 1, queries_of(crm, "GET", "/api/v1/contacts/lookup").size
    assert CrmDisappearance.exists?(contact_id: "55")
    assert_equal 0, CrmErasure.count, "une déduction n'est pas un effacement"
    registration.reload
    assert_not_nil registration.crm_sync_contact_gone_at
    assert_nil registration.crm_last_error_code
    assert_empty Crm::Backlog.new.items, "pas de 503"
  end

  test "A : id EMPRUNTÉ à une autre ligne, fiche disparue → aucune création, même pour une confirmation récente" do
    crm = serve(FakeCrmServer.new)
    borrow_from_old_row("camille@example.test")
    registration = confirmed_registration("camille@example.test", confirmed_at: 1.minute.ago)

    CrmSyncJob.perform_now(registration.id)

    assert_empty bodies_of(crm, "POST", "/api/v1/contacts")
    assert_not_nil registration.reload.crm_sync_contact_gone_at
    assert_nil registration.crm_contact_id
  end

  test "A : « préviens-moi » sur fiche disparue → même état terminal, sur SA colonne" do
    crm = serve(FakeCrmServer.new)
    borrow_from_old_row("lou@example.test")
    request = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", notify_next: true, confirmed_at: 5.minutes.ago)

    CrmNotifyNextJob.perform_now(request.id)

    assert_empty bodies_of(crm, "POST", "/api/v1/contacts")
    assert_not_nil request.reload.crm_contact_gone_at
    assert_nil request.crm_last_error_code
  end

  test "A : consentement /mc sur fiche disparue → état terminal de la synchro, sans alerte" do
    crm = serve(FakeCrmServer.new)
    registration = confirmed_registration("camille@example.test", confirmed_at: 1.day.ago)
    registration.update!(crm_contact_id: "55", pushed_to_crm_at: 1.day.ago,
                         marketing_consent: true, marketing_consent_at: 1.hour.ago)
    CrmSyncJob.perform_now(registration.id)

    assert_empty bodies_of(crm, "POST", "/api/v1/contacts")
    assert_not_nil registration.reload.crm_sync_contact_gone_at
    assert_empty Crm::Backlog.new.items
  end

  test "C : retrait sur fiche introuvable → JAMAIS un succès : échec permanent dédié, sonde en 503" do
    crm = serve(FakeCrmServer.new)
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test",
                                                  crm_contact_id: "55", marketing_consent_withdrawn_at: Time.current)
    io = StringIO.new
    with_logger(Logger.new(io)) { CrmMarketingWithdrawalJob.perform_now(registration.id) }

    registration.reload
    assert_nil registration.crm_withdrawal_pushed_at
    assert_equal [ 404, 1 ], [ registration.crm_withdrawal_last_error_code, registration.crm_withdrawal_attempts ]
    assert CrmDisappearance.exists?(contact_id: "55")
    assert_match(/withdrawal_contact_not_found registration_id=#{registration.id}\b/, io.string)
    assert_no_match(/camille/i, io.string)
    item = Crm::Backlog.new.items.sole
    assert_equal :withdrawals, item.queue
    assert item.permanent_failure?, "la sonde alerte : un humain vérifie la fiche dans le CRM"
  end

  test "M2 : l'état terminal de la SYNCHRO ne court-circuite pas le retrait" do
    crm = serve(FakeCrmServer.new(contacts: { 55 => "camille@example.test" }))
    registration = confirmed_registration("camille@example.test", confirmed_at: 1.day.ago)
    registration.update!(crm_contact_id: "55", crm_sync_contact_gone_at: 1.hour.ago,
                         marketing_consent_withdrawn_at: Time.current)
    assert_includes Registration.crm_withdrawal_pending, registration

    CrmMarketingWithdrawalJob.perform_now(registration.id)

    assert registration.reload.crm_withdrawal_pushed?
    assert_equal 1, bodies_of(crm, "POST", "/api/v1/interactions").size
  end

  test "B : effacement explicite puis réinscription postérieure → fiche créée normalement" do
    crm = serve(FakeCrmServer.new)
    old = borrow_from_old_row("camille@example.test")
    CrmErasure.erase!("camille@example.test", now: 1.hour.ago)
    assert_not Registration.exists?(old.id), "lignes live purgées"
    registration = confirmed_registration("camille@example.test", confirmed_at: 10.minutes.ago, name: "Camille Durand")

    CrmSyncJob.perform_now(registration.id)

    assert_equal [ { "first_name" => "Camille", "last_name" => "Durand", "email" => "camille@example.test" } ],
                 bodies_of(crm, "POST", "/api/v1/contacts")
    assert registration.reload.crm_pushed?
  end

  test "B : ligne confirmée AVANT l'effacement explicite (rescapée) → ni création, ni rattachement" do
    crm = serve(FakeCrmServer.new)
    CrmErasure.erase!("camille@example.test", now: 1.hour.ago)
    registration = confirmed_registration("camille@example.test", confirmed_at: 2.hours.ago)

    CrmSyncJob.perform_now(registration.id)

    assert_empty crm.requests, "aucun appel au CRM"
    assert_not_nil registration.reload.crm_sync_contact_gone_at
  end

  test "B : double effacement explicite → comparé au DERNIER ; une ligne confirmée entre les deux ne crée pas" do
    crm = serve(FakeCrmServer.new)
    CrmErasure.erase!("camille@example.test", now: 3.hours.ago)
    CrmErasure.erase!("camille@example.test", now: 1.hour.ago)
    CrmErasure.erase!("camille@example.test", now: 5.hours.ago) # jamais de recul
    assert_in_delta 1.hour.ago, CrmErasure.erased_at("camille@example.test"), 1
    between = confirmed_registration("camille@example.test", confirmed_at: 2.hours.ago)

    CrmSyncJob.perform_now(between.id)

    assert_empty bodies_of(crm, "POST", "/api/v1/contacts")
    assert_not_nil between.reload.crm_sync_contact_gone_at
  end

  test "D : ligne confirmée avant un effacement explicite → ni écriture ni relocalisation vers la fiche recréée" do
    crm = serve(FakeCrmServer.new(contacts: { 90 => "camille@example.test" })) # fiche recréée depuis
    registration = confirmed_registration("camille@example.test", confirmed_at: 1.day.ago)
    registration.update!(crm_contact_id: "55", pushed_to_crm_at: 1.day.ago,
                         marketing_consent: true, marketing_consent_at: 1.day.ago)
    CrmErasure.erase!("autre@example.test") # sans effet sur cette adresse
    CrmErasure.create!(email_digest: CrmErasure.digest("camille@example.test"), erased_at: 2.hours.ago)

    CrmSyncJob.perform_now(registration.id)

    assert_empty crm.requests, "aucune écriture, ni sur 55 ni sur la fiche recréée 90"
    assert_equal "55", registration.reload.crm_contact_id, "pas rattachée à la fiche 90"
    assert_not_nil registration.crm_sync_contact_gone_at
  end

  test "job mort entre la création et l'écriture de l'id : la reprise retrouve la fiche par lookup, sans doublon" do
    crm = serve(FakeCrmServer.new)
    registration = confirmed_registration("camille@example.test", confirmed_at: 5.minutes.ago)
    killed = CrmSyncJob.new
    killed.define_singleton_method(:track_contact_id) { |*| raise "worker tué" }

    assert_raises(RuntimeError) { killed.perform(registration.id) }
    assert_nil registration.reload.crm_contact_id
    CrmSyncJob.perform_now(registration.id)

    assert_equal 1, bodies_of(crm, "POST", "/api/v1/contacts").size
    assert_equal "78", registration.reload.crm_contact_id
    assert registration.crm_pushed?
  end

  test "empreinte d'effacement : HMAC à clé dédiée, email normalisé, jamais en clair" do
    CrmErasure.erase!("Camille@Example.test ")
    key = Rails.application.key_generator.generate_key("crm-erasure-email-digest", 32)
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", key, "camille@example.test"), CrmErasure.sole.email_digest
    assert_not_equal Digest::SHA256.hexdigest("camille@example.test"), CrmErasure.sole.email_digest
    assert_no_match(/camille|example/i, CrmErasure.pluck(Arel.sql("*")).flatten.join(" "))
  end

  test "id EMPRUNTÉ non persisté tant que l'écriture n'est pas passée (sinon il deviendrait celui de la ligne)" do
    crm = serve(FakeCrmServer.new(contacts: { 55 => "camille@example.test" }))
    crm.define_singleton_method(:create_interaction) { |_params| ContractResponse.new("503", "{}") }
    @webinar.registrations.create!(name: "Camille", email: "camille@example.test", crm_contact_id: "55")
    registration = Webinar.create!(title: "Café IA #3", starts_at: 3.days.from_now, host_sub: "h", visibility: "published")
                          .registrations.create!(name: "Camille", email: "camille@example.test")
    registration.confirm!

    assert_raises(Crm::TransientError) { CrmSyncJob.new.perform(registration.id) }
    assert_nil registration.reload.crm_contact_id
  end

  test "retrait sans fiche locale mais connue par un autre café : aucun lookup" do
    crm = serve(FakeCrmServer.new(contacts: { 90 => "camille@example.test" }))
    other = Webinar.create!(title: "Café IA #2", starts_at: 2.days.from_now, host_sub: "h", visibility: "published")
    other.registrations.create!(name: "Camille", email: "camille@example.test", crm_contact_id: "90")
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test",
                                                  marketing_consent_withdrawn_at: Time.current)
    CrmMarketingWithdrawalJob.perform_now(registration.id)

    assert_empty queries_of(crm, "GET", "/api/v1/contacts/lookup")
    assert registration.reload.crm_withdrawal_pushed?
  end

  # ---- 404 sur une écriture : fiche périmée après fusion -------------

  test "crm_contact_id périmé (fiche fusionnée) : 404, nouveau lookup, id mis à jour, UN nouvel essai" do
    crm = serve(FakeCrmServer.new(contacts: { 90 => "camille@example.test" }))
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test",
                                                  crm_contact_id: "77", marketing_consent_withdrawn_at: Time.current)

    CrmMarketingWithdrawalJob.perform_now(registration.id)

    assert_equal [ 77, 90 ], bodies_of(crm, "POST", "/api/v1/interactions").map { |body| body["contact_id"] }
    assert_equal 1, requests_of(crm, "GET", "/api/v1/contacts/lookup").size
    assert_equal "90", registration.reload.crm_contact_id
    assert registration.crm_withdrawal_pushed?
  end

  test "consentement sur fiche fusionnée : relocalisé et poussé, crm_contact_id mis à jour" do
    crm = serve(FakeCrmServer.new(contacts: { 90 => "camille@example.test" }))
    registration = @webinar.registrations.create!(
      name: "Camille", email: "camille@example.test", confirmed_at: Time.current, crm_enrolled_at: Time.current,
      pushed_to_crm_at: 1.day.ago, crm_contact_id: "77", marketing_consent: true, marketing_consent_at: Time.current
    )

    CrmSyncJob.perform_now(registration.id)

    assert_equal [ 77, 90 ], bodies_of(crm, "POST", "/api/v1/interactions").map { |body| body["contact_id"] }
    assert_equal "90", registration.reload.crm_contact_id
    assert_not_nil registration.crm_marketing_consent_pushed_at
  end

  test "fiche disparue (lookup vide après 404) : AUCUNE fiche recréée par un retrait, pas de second essai" do
    crm = serve(FakeCrmServer.new)
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test",
                                                  crm_contact_id: "77", marketing_consent_withdrawn_at: Time.current)
    CrmMarketingWithdrawalJob.perform_now(registration.id)

    assert_empty bodies_of(crm, "POST", "/api/v1/contacts"), "une fiche effacée n'est jamais recréée par un retrait"
    assert_equal 1, bodies_of(crm, "POST", "/api/v1/interactions").size, "pas de second essai sans fiche"
    assert_nil registration.reload.crm_withdrawal_pushed_at
    assert_equal 404, registration.crm_withdrawal_last_error_code, "compteur propre au retrait"
    assert_nil registration.crm_last_error_code
  end

  test "email non concordant même après lookup (second 404) : permanente, un seul nouvel essai" do
    crm = serve(FakeCrmServer.new(contacts: { 90 => "camille@example.test" }))
    crm.define_singleton_method(:proven?) { |_id, _email| false }
    registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test",
                                                  crm_contact_id: "77", marketing_consent_withdrawn_at: Time.current)

    CrmMarketingWithdrawalJob.perform_now(registration.id)

    assert_equal [ 77, 90 ], bodies_of(crm, "POST", "/api/v1/interactions").map { |body| body["contact_id"] }
    assert_nil registration.reload.crm_withdrawal_pushed_at
    assert_equal 404, registration.crm_withdrawal_last_error_code, "compteur propre au retrait"
    assert_nil registration.crm_last_error_code
  end

  private

  def borrow_from_old_row(email)
    old = Webinar.create!(title: "Café IA #1", starts_at: 2.months.ago, host_sub: "h", visibility: "published")
    old.registrations.create!(name: "Ancienne", email: email, crm_contact_id: "55",
                              confirmed_at: 2.months.ago, pushed_to_crm_at: 2.months.ago)
  end

  def confirmed_registration(email, confirmed_at:, name: "Camille")
    @webinar.registrations.create!(name: name, email: email, confirmed_at: confirmed_at, crm_enrolled_at: confirmed_at)
  end

  def serve(crm)
    Net::HTTP.define_singleton_method(:start) { |*_a, **_k, &block| block.call(crm) }
    crm
  end

  def with_logger(logger)
    original = Rails.logger
    Rails.logger = logger
    yield
  ensure
    Rails.logger = original
  end

  def requests_of(crm, method, path)
    crm.requests.select { |m, p, _, _| m == method && path === p } # chemin exact ou Regexp
  end

  def bodies_of(crm, method, path)
    requests_of(crm, method, path).map { |request| request[2] }
  end

  def queries_of(crm, method, path)
    requests_of(crm, method, path).map(&:last)
  end
end
