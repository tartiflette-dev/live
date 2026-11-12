# frozen_string_literal: true

require "test_helper"
require "rake"

# `printf '%s' adresse | bin/rails crm:erase` — effacement explicite (docs/registrations-api.md).
class CrmEraseTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "crm:erase" }
    @task = Rake::Task["crm:erase"]
    @task.reenable
    @prev = ENV["EMAIL"]
    @original_check = Crm::ErasureCheck.method(:call)
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.day.ago, host_sub: "h", visibility: "published")
    request = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", notify_next: true)
    @registration = @webinar.registrations.create!(name: "Camille", email: "camille@example.test",
                                                   confirmed_at: 2.days.ago, registration_request: request)
    HandRaise.create!(webinar: @webinar, registration: @registration, raised_at: 1.day.ago,
                      state: HandRaise::STATES.first)
    @message = @webinar.messages.create!(author_identity: "viewer-#{@registration.id}", name: "Camille", body: "Bonjour")
    @other = @webinar.registrations.create!(name: "Lou", email: "lou@example.test")
    @poll = @webinar.polls.create!(position: 1, kind: "choice", label: "A ou B ?", options: %w[A B])
    @poll.responses.create!(respondent_identity: "viewer-#{@registration.id}", registration: @registration, name: "Camille", value: [ 0 ])
    @poll.responses.create!(respondent_identity: "viewer-#{@other.id}", registration: @other, name: "Lou", value: [ 1 ])
  end

  teardown do
    ENV["EMAIL"] = @prev
    original = @original_check
    Crm::ErasureCheck.define_singleton_method(:call, original)
  end

  test "forme nominale (stdin) : purge, messages neutralisés (nom ET texte), effacement enregistré ; ni email ni texte en sortie" do
    other_message = @webinar.messages.create!(author_identity: "viewer-#{@other.id}", name: "Lou", body: "Salut")
    checked = stub_crm_check("CRM : aucune fiche trouvée pour cette adresse.")
    output, errors = run_task(stdin: "Camille@Example.test\n")

    assert_not Registration.exists?(@registration.id)
    assert_not RegistrationRequest.exists?(email: "camille@example.test")
    assert Registration.exists?(@other.id), "les autres personnes intactes"
    @message.reload
    assert_equal [ CrmErasure::ERASED_NAME, "[message retiré]" ], [ @message.name, @message.body ]
    assert_equal [ "Lou", "Salut" ], [ other_message.reload.name, other_message.body ]
    assert CrmErasure.erased_at("camille@example.test")
    assert_match(/registrations=1 registration_requests=1/, output)
    assert_match(/messages=1 hand_raises=1 poll_responses=1/, output)
    assert_equal 0, HandRaise.count
    assert_equal [ "Lou" ], @poll.responses.pluck(:name), "réponses aux sondages de la personne supprimées, les autres intactes"
    assert_match(/Rappel : vérifie que la fiche est effacée dans le CRM/, output)
    assert_match(/CRM : aucune fiche trouvée/, output)
    assert_equal [ "camille@example.test" ], checked, "le lookup porte sur l'adresse normalisée"
    assert_empty errors, "pas d'avertissement en forme nominale"
    assert_no_match(/camille|bonjour/i, output)
  end

  test "envois groupés : les marqueurs de l'adresse sont supprimés, ceux des autres restent" do
    announcement = build_announcement(@webinar, "webinar_registrants")
    announcement.save!
    [ "camille@example.test", "lou@example.test" ].zip([ @registration, @other ]).each do |email, holder|
      announcement.deliveries.create!(recipient_digest: AnnouncementDelivery.digest(email), holder: holder)
    end
    stub_crm_check("CRM : aucune fiche trouvée pour cette adresse.")

    output, = run_task(stdin: "camille@example.test\n")

    assert_equal [ AnnouncementDelivery.digest("lou@example.test") ], announcement.deliveries.pluck(:recipient_digest)
    assert_match(/announcement_deliveries=1/, output)
  end

  # Lien participants : l'adresse déclarée par un intervenant non rattaché est
  # oubliée avec son lien ; un intervenant rattaché perd son rattachement.
  test "intervenants : adresse déclarée oubliée, rattachement détaché, les autres intacts" do
    declared = @webinar.speakers.create!(name: "Camille", declared_email: "camille@example.test")
    linked = @webinar.speakers.create!(name: "Camille", registration: @registration)
    other = @webinar.speakers.create!(name: "Lou", declared_email: "lou@example.test")
    stub_crm_check("CRM : aucune fiche trouvée pour cette adresse.")

    output, = run_task(stdin: "camille@example.test\n")

    assert_equal [ nil, nil ], [ declared.reload.declared_email, declared.link_token ]
    assert_nil linked.reload.registration
    assert_equal "lou@example.test", other.reload.declared_email
    assert_match(/declared_speakers=1/, output)
  end

  # Pierre tombale (identité provisoire retirée ou remise) : son adresse est
  # libérée, l'effacement la retrouve par l'empreinte.
  test "pierre tombale de cette adresse : effacée avec ses messages" do
    tombstone = @webinar.registrations.create!(name: "Camille", email: "camille-bis@example.test", instant_access_at: 1.day.ago)
    tombstone.update!(retired_email_digest: CrmErasure.digest("camille@example.test"), email: "retire-#{tombstone.id}@retire.invalid")
    message = @webinar.messages.create!(author_identity: "viewer-#{tombstone.id}", name: "Camille", body: "Depuis l'ordinateur")
    stub_crm_check("CRM : aucune fiche trouvée pour cette adresse.")

    output, = run_task(stdin: "camille@example.test\n")

    assert_not Registration.exists?(tombstone.id)
    assert_equal CrmErasure::ERASED_NAME, message.reload.name
    assert_match(/registrations=2/, output)
  end

  # Sécurité : aucun libellé tiré du texte de la personne effacée ne
  # survit, même quand la question a d'autres auteurs.
  test "file Q&R : posée seul·e, la question disparaît ; partagée, son libellé est réécrit depuis un autre auteur" do
    alone = QaItem.enqueue!(message: @message, label: "Question de Camille seule", source: "llm")
    shared_message = @webinar.messages.create!(author_identity: "viewer-#{@registration.id}", name: "Camille", body: "Et ça, Camille ?")
    shared = QaItem.enqueue!(message: shared_message, label: "Reformulation du texte de Camille", source: "llm", llm_model: "glm-4-9b")
    lou = @webinar.messages.create!(author_identity: "viewer-#{@other.id}", name: "Lou", body: "Pareil  pour moi ?")
    QaItem.enqueue!(message: lou, label: "x", source: "llm", duplicate_of: shared.id)
    kept = QaItem.enqueue!(message: @webinar.messages.create!(author_identity: "viewer-#{@other.id}", name: "Lou", body: "Autre ?"),
                           label: "Question de Lou", source: "llm")
    camille_joins = @webinar.messages.create!(author_identity: "viewer-#{@registration.id}", name: "Camille", body: "Moi aussi")
    QaItem.enqueue!(message: camille_joins, label: "x", source: "llm", duplicate_of: kept.id)
    stub_crm_check("CRM : aucune fiche trouvée pour cette adresse.")

    output, = run_task(stdin: "camille@example.test\n")

    assert_not QaItem.exists?(alone.id)
    shared.reload
    assert_equal [ "Pareil pour moi ?", "mention", nil, lou.id ], [ shared.label, shared.source, shared.llm_model, shared.label_message_id ]
    assert_equal [ "Lou" ], shared.authors.map { |author| author[:name] }
    assert_equal [ "Question de Lou", [ "Lou" ] ], [ kept.reload.label, kept.authors.map { |author| author[:name] } ],
      "libellé tiré d'un autre auteur : gardé, seul le lien de Camille part"
    assert_match(/qa_items=2 messages=3/, output)
    assert_no_match(/Camille/, QaItem.pluck(:label).join)
  end

  # Un libellé réécrit en texte brut (non relu) ne reste pas
  # à l'écran ; la salle reçoit l'état du bandeau après commit.
  test "file Q&R : la question affichée réécrite est retirée de l'écran et la salle prévenue" do
    displayed = QaItem.enqueue!(message: @message, label: "Reformulation de Camille", source: "llm")
    lou = @webinar.messages.create!(author_identity: "viewer-#{@other.id}", name: "Lou", body: "Moi aussi ?")
    QaItem.enqueue!(message: lou, label: "x", source: "llm", duplicate_of: displayed.id)
    displayed.display!
    packets = []
    room = Object.new
    room.define_singleton_method(:send_data) { |room:, data:, kind:| packets << JSON.parse(data) }
    previous = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { room }
    stub_crm_check("CRM : aucune fiche trouvée pour cette adresse.")

    run_task(stdin: "camille@example.test\n")

    assert_equal [ "Moi aussi ?", nil ], [ displayed.reload.label, displayed.displayed_at ]
    assert_equal [ { "topic" => "qa", "displayed" => nil } ], packets
  ensure
    Rails.configuration.x.room_service_client_factory = previous
  end

  test "EMAIL= : accepté, mais un avertissement le déconseille" do
    stub_crm_check("CRM : aucune fiche trouvée pour cette adresse.")
    ENV["EMAIL"] = "camille@example.test"
    _output, errors = run_task(stdin: "")

    assert_not Registration.exists?(@registration.id)
    assert_match(/EMAIL= est déconseillé.*printf/, errors)
  end

  test "adresse invalide : refus, rien n'est touché, aucun lookup" do
    checked = stub_crm_check("ne doit pas servir")
    assert_raises(SystemExit) { run_task(stdin: "pas-une-adresse\n") }
    assert Registration.exists?(@registration.id)
    assert_equal 0, CrmErasure.count
    assert_empty checked
  end

  private

  def run_task(stdin:)
    originals = [ $stdin, $stdout, $stderr ]
    $stdin = StringIO.new(stdin)
    $stdout = StringIO.new
    $stderr = StringIO.new
    @task.invoke
    [ $stdout.string, $stderr.string ]
  ensure
    $stdin, $stdout, $stderr = originals
  end

  def stub_crm_check(line)
    checked = []
    Crm::ErasureCheck.define_singleton_method(:call) { |email, **| checked << email && line }
    checked
  end
end
