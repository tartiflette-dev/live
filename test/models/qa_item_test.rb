require "test_helper"

# File Q&R : création ou rattachement sous verrou, auteurs
# tirés des messages, une seule question à l'écran par webinaire.
class QaItemTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @webinar = Webinar.create!(title: "Café IA #8", host_sub: "sub-host", starts_at: 1.hour.ago, state: "live")
    @alice = @webinar.messages.create!(author_identity: "viewer-11", name: "Alice", body: "Et pour l'auto-hébergement ?")
    @bob = @webinar.messages.create!(author_identity: "viewer-12", name: "Bob", body: "On peut l'héberger chez soi ?")
  end

  test "un message crée une question ; le même message rejoué rend la même, sans doublon" do
    item = QaItem.enqueue!(message: @alice, label: "  Peut-on   auto-héberger ?  ", source: "llm", llm_model: "glm-4-9b")

    assert_predicate item, :open?
    assert_equal "Peut-on auto-héberger ?", item.label
    assert_equal item, QaItem.enqueue!(message: @alice, label: "Autre libellé", source: "llm")
    assert_equal 1, @webinar.qa_items.count
    assert_equal 1, item.qa_item_messages.count
  end

  test "rattachement à une question ouverte : plusieurs auteurs, un seul item ; une question close n'attire rien" do
    item = QaItem.enqueue!(message: @alice, label: "Peut-on auto-héberger ?", source: "llm")
    assert_equal item, QaItem.enqueue!(message: @bob, label: "Ignoré", source: "llm", duplicate_of: item.id)
    assert_equal [ "Alice", "Bob" ], item.reload.authors.map { |author| author[:name] }
    assert_equal [ "viewer", "viewer" ], item.authors.map { |author| author[:role] }

    item.answer!
    carol = @webinar.messages.create!(author_identity: "speaker-3", name: "Carol", body: "Et en local ?")
    other = QaItem.enqueue!(message: carol, label: "Et en local ?", source: "llm", duplicate_of: item.id)
    assert_not_equal item, other
    assert_equal [ { name: "Carol", role: "speaker" } ], other.authors
  end

  test "le libellé est tiré du message qui a créé la question, pas de ceux qui s'y rattachent" do
    item = QaItem.enqueue!(message: @alice, label: "Peut-on auto-héberger ?", source: "llm")
    QaItem.enqueue!(message: @bob, label: "Ignoré", source: "llm", duplicate_of: item.id)

    assert_equal @alice, item.reload.label_message
  end

  test "un message effacé (ou disparu) n'entre jamais dans la file" do
    @alice.update_columns(body: CrmErasure::ERASED_BODY)
    assert_nil QaItem.enqueue!(message: @alice, label: "Peu importe", source: "manual")
    @bob.delete
    assert_nil QaItem.enqueue!(message: @bob, label: "Peu importe", source: "llm")
    assert_empty @webinar.qa_items
  end

  test "un auteur qui reformule deux fois compte une seule fois" do
    item = QaItem.enqueue!(message: @alice, label: "Peut-on auto-héberger ?", source: "llm")
    again = @webinar.messages.create!(author_identity: "viewer-11", name: "Alice", body: "Je repose ma question ?")
    QaItem.enqueue!(message: again, label: "x", source: "llm", duplicate_of: item.id)

    assert_equal 1, item.reload.authors.size
    assert_equal 2, item.messages.size
  end

  test "libellé obligatoire et borné ; un texte brut trop long est tronqué à l'entrée dans la file" do
    item = QaItem.enqueue!(message: @alice, label: "x" * 900, source: "mention")
    assert_equal QaItem::LABEL_LIMIT, item.label.length

    assert_raises(ActiveRecord::RecordInvalid) { item.relabel!("   ") }
    assert_raises(ActiveRecord::RecordInvalid) { item.relabel!("y" * 501) }
    assert item.relabel!("Peut-on héberger le modèle chez soi ?")
    assert_not item.relabel!(" Peut-on héberger le modèle chez soi ? ")
  end

  test "transitions idempotentes ; répondre ou écarter retire de l'écran ; rouvrir efface la réponse" do
    item = QaItem.enqueue!(message: @alice, label: "Question", source: "llm")
    assert item.display!
    assert_not item.display!

    assert item.answer!
    answered_at = item.answered_at
    assert_nil item.displayed_at
    assert_not item.answer!
    assert_equal answered_at, item.reload.answered_at

    assert item.reopen!
    assert_nil item.answered_at
    assert item.dismiss!
    assert_predicate item, :dismissed?
  end

  test "une seule question à l'écran par webinaire ; une question close ne s'affiche pas" do
    first = QaItem.enqueue!(message: @alice, label: "Première", source: "llm")
    second = QaItem.enqueue!(message: @bob, label: "Seconde", source: "llm")

    first.display!
    second.display!
    assert_equal [ second.id ], @webinar.qa_items.displayed.pluck(:id)

    first.dismiss!
    assert_raises(QaItem::NotDisplayable) { first.display! }
    assert_raises(ActiveRecord::RecordNotUnique) { first.update_columns(status: "open", displayed_at: Time.current) }
  end

  test "file : ouvertes d'abord, puis répondues et écartées, chacune dans l'ordre d'arrivée" do
    answered = QaItem.enqueue!(message: @alice, label: "Répondue", source: "llm")
    answered.answer!
    open = QaItem.enqueue!(message: @bob, label: "Ouverte", source: "llm")

    assert_equal [ open.id, answered.id ], @webinar.qa_items.queue_order.pluck(:id)
  end

  test "forme publique : le libellé seul ; forme console : auteurs et messages, jamais l'identité technique" do
    host_message = @webinar.messages.create!(author_identity: "host-sub-secret", name: "marc", body: "Qui veut une démo ?")
    item = QaItem.enqueue!(message: host_message, label: "Démo ?", source: "manual")

    assert_equal %i[id label displayed_at], item.public_attributes.keys
    console = item.console_attributes
    assert_equal [ { name: "marc", role: "host" } ], console[:authors]
    assert_equal "Qui veut une démo ?", console[:messages].first[:body]
    assert_not_includes console.to_json, "sub-secret"
  end

  test "chaque nouveau message est proposé à l'extraction, après commit" do
    assert_enqueued_with(job: QaExtractionJob) do
      @webinar.messages.create!(author_identity: "viewer-11", name: "Alice", body: "Encore une question ?")
    end
  end
end
