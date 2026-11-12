require "test_helper"

# Sondages du direct : format de question, cycle prévu →
# ouvert → fermé, résultat montré, réponses et agrégat. Les courses entre
# requêtes sont dans poll_concurrency_test.rb.
class PollTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA #8", starts_at: 1.hour.ago, host_sub: "sub-marc", state: "live")
  end

  def choice(label = "A, B ou C ?", options: %w[A B C], **attributes)
    @webinar.polls.create!(position: @webinar.polls.count + 1, kind: "choice", label: label, options: options, **attributes)
  end

  def scale(options = { min: 1, max: 5, min_label: "pas du tout", max_label: "tout à fait" })
    @webinar.polls.create!(position: @webinar.polls.count + 1, kind: "scale", label: "Confiance ?", options: options)
  end

  def respond(poll, identity, value, name: identity)
    poll.respond!(identity: identity, name: name, value: value)
  end

  test "choix : 2 à 6 libellés distincts, nettoyés ; `multiple` ne vaut que pour un choix" do
    poll = choice(options: [ " Oui ", "Non", "" ], multiple: true)
    assert_equal %w[Oui Non], poll.options
    assert poll.multiple

    assert_not @webinar.polls.build(position: 9, kind: "choice", label: "?", options: [ "Seul" ]).valid?
    assert_not @webinar.polls.build(position: 9, kind: "choice", label: "?", options: %w[A A]).valid?
    assert_not @webinar.polls.build(position: 9, kind: "choice", label: "?", options: %w[1 2 3 4 5 6 7]).valid?
    assert_not @webinar.polls.build(position: 9, kind: "choice", label: "?", options: [ "x" * 121, "B" ]).valid?
    assert_not @webinar.polls.build(position: 9, kind: "short_text", label: "x" * 301).valid?

    text = @webinar.polls.create!(position: 9, kind: "short_text", label: "Un mot ?", multiple: true, options: %w[A B])
    assert_equal [ false, nil ], [ text.multiple, text.options ]
  end

  test "libellés de réponse alignés sur les comptes : options, valeurs de l'échelle, aucun pour la réponse courte" do
    assert_equal %w[A B C], choice.format.answer_labels
    assert_equal %w[1 2 3 4 5], scale.format.answer_labels
    assert_nil @webinar.polls.create!(position: 9, kind: "short_text", label: "Un mot ?").format.answer_labels
  end

  test "échelle : min 0 ou 1, max 2 à 10, libellés facultatifs" do
    assert_equal({ "min" => 1, "max" => 5, "min_label" => "pas du tout", "max_label" => "tout à fait" }, scale.options)
    assert_equal({ "min" => 0, "max" => 10, "min_label" => nil, "max_label" => nil }, scale({ "min" => "0", "max" => "10" }).options)
    assert_not @webinar.polls.build(position: 9, kind: "scale", label: "?", options: { min: 2, max: 5 }).valid?
    assert_not @webinar.polls.build(position: 9, kind: "scale", label: "?", options: { min: 1, max: 11 }).valid?
    assert_not @webinar.polls.build(position: 9, kind: "scale", label: "?", options: [ 1, 5 ]).valid?
    assert_not @webinar.polls.build(position: 9, kind: "quiz", label: "?").valid?
  end

  test "ouvrir exige le direct en cours ; un sondage lancé ne se rouvre pas" do
    poll = choice
    @webinar.update!(state: "draft")
    assert_equal :webinar_not_live, assert_raises(Poll::Refused) { poll.open! }.code

    @webinar.update!(state: "live")
    poll.open!
    assert_equal "open", poll.state
    poll.close!
    assert_equal :already_opened, assert_raises(Poll::Refused) { poll.open! }.code
    assert_equal "closed", poll.reload.state
  end

  test "ouvrir un sondage ferme celui qui était ouvert et masque le résultat montré" do
    first = choice("Première ?")
    first.open!
    first.show_results!
    second = choice("Seconde ?")

    second.open!

    assert_equal [ "closed", false ], [ first.reload.state, first.results_shown? ]
    assert_equal second, Poll.current_for(@webinar)
  end

  test "à l'écran : le sondage ouvert, sinon celui dont le résultat est montré, sinon rien" do
    poll = choice
    assert_nil Poll.current_for(@webinar)
    poll.open!
    assert_equal poll, Poll.current_for(@webinar)
    poll.close!
    assert_nil Poll.current_for(@webinar), "fermé sans résultat montré : la pop-up disparaît"
    assert poll.show_results!
    assert_equal poll, Poll.current_for(@webinar)
    assert_not poll.show_results!, "idempotent"
    assert poll.hide_results!
    assert_not poll.hide_results!
    assert_nil Poll.current_for(@webinar)
  end

  test "montrer un résultat : jamais avant l'ouverture, ni pendant qu'un autre sondage est ouvert" do
    shown = choice
    assert_equal :never_opened, assert_raises(Poll::Refused) { shown.show_results! }.code
    assert_equal :never_opened, assert_raises(Poll::Refused) { shown.close! }.code
    shown.open!
    other = choice("Autre ?")
    other.open!

    assert_equal :other_poll_open, assert_raises(Poll::Refused) { shown.reload.show_results! }.code
    assert other.show_results!, "le sondage ouvert peut montrer son résultat en direct"
    other.close!
    assert shown.show_results!
    assert_not other.reload.results_shown?, "un seul résultat à l'écran"
  end

  test "réponses courtes : résultat montré seulement une fois le sondage fermé" do
    text = @webinar.polls.create!(position: 1, kind: "short_text", label: "Un mot ?")
    text.open!
    assert_not text.results_showable?
    assert_equal :poll_open, assert_raises(Poll::Refused) { text.show_results! }.code
    text.close!
    assert text.show_results!

    graded = scale
    graded.open!
    assert graded.results_showable?, "choix et échelle : montrables en direct"
  end

  test "edit! et remove! relisent sous verrou : un sondage lancé depuis le chargement est refusé" do
    stale = Poll.find(choice.id)
    Poll.find(stale.id).open!
    assert_equal :already_opened, assert_raises(Poll::Refused) { stale.edit!(label: "Trop tard ?") }.code
    assert_equal :already_opened, assert_raises(Poll::Refused) { stale.remove! }.code
    assert_equal "A, B ou C ?", stale.reload.label
  end

  test "lancé, le sondage n'est plus modifiable ni supprimable ; prévu, il l'est" do
    planned = choice
    planned.update!(label: "Reformulée ?", planned_minute: 12, note: "après la démo")
    launched = choice("Lancée ?")
    launched.open!

    assert_not launched.update(label: "Autre texte")
    assert_not launched.reload.update(note: "trop tard")
    assert_equal :already_opened, assert_raises(Poll::Refused) { launched.destroy }.code
    assert Poll.exists?(launched.id)
    planned.destroy!
    assert_not Poll.exists?(planned.id)
  end

  test "réponse : une par identité, remplacée tant que le sondage est ouvert, refusée ensuite" do
    poll = choice
    assert_equal :poll_closed, assert_raises(Poll::Refused) { respond(poll, "viewer-1", [ 0 ]) }.code
    poll.open!

    respond(poll, "viewer-1", [ 0 ], name: "Alice")
    respond(poll, "viewer-1", "2", name: "Alice")
    assert_equal [ [ "viewer-1", "Alice", [ 2 ] ] ], poll.responses.pluck(:respondent_identity, :name, :value)

    poll.close!
    assert_equal :poll_closed, assert_raises(Poll::Refused) { respond(poll, "viewer-1", [ 1 ]) }.code
  end

  test "le direct terminé, plus aucune réponse" do
    poll = choice
    poll.open!
    @webinar.update!(state: "ended")
    assert_equal :webinar_not_live, assert_raises(Poll::Refused) { respond(poll, "viewer-1", [ 0 ]) }.code
  end

  test "valeur hors format refusée : choix inexistant, plusieurs choix sans `multiple`, flottant, texte vide ou long" do
    single = choice
    single.open!
    [ [ 3 ], [ 0, 1 ], [], 1.5, "A", { "0" => 1 } ].each do |value|
      assert_raises(ActiveRecord::RecordInvalid, value.inspect) { respond(single, "viewer-1", value) }
    end

    text = @webinar.polls.create!(position: 5, kind: "short_text", label: "Un mot ?")
    text.open!
    [ "   ", "x" * 201, 42 ].each do |value|
      assert_raises(ActiveRecord::RecordInvalid, value.inspect) { respond(text, "viewer-1", value) }
    end
    respond(text, "viewer-1", "  Génial  ")
    assert_equal "Génial", text.responses.sole.value

    graded = scale
    graded.open!
    [ 0, 6, "trois", 2.5 ].each do |value|
      assert_raises(ActiveRecord::RecordInvalid, value.inspect) { respond(graded, "viewer-1", value) }
    end
  end

  test "agrégat : choix multiple (un répondant compte pour chaque option cochée), échelle avec moyenne, textes" do
    multi = choice(multiple: true)
    multi.open!
    respond(multi, "viewer-1", [ 0, 2 ])
    respond(multi, "viewer-2", [ 2 ])
    respond(multi, "host-marc", [ 1, 2 ])
    assert_equal({ respondents: 3, counts: [ 1, 1, 3 ] }, multi.results)

    graded = scale
    graded.open!
    respond(graded, "viewer-1", 4)
    respond(graded, "viewer-2", 5)
    respond(graded, "viewer-3", 5)
    assert_equal({ respondents: 3, counts: [ 0, 0, 0, 1, 2 ], average: 4.7 }, graded.results)

    text = @webinar.polls.create!(position: 9, kind: "short_text", label: "Un mot ?")
    text.open!
    respond(text, "viewer-1", "Clair")
    respond(text, "viewer-2", "Trop rapide")
    assert_equal({ respondents: 2, answers: [ "Clair", "Trop rapide" ] }, text.results)
  end

  test "participants : compteur, et résultat seulement montré ; animation : noms par option" do
    poll = choice
    poll.open!
    respond(poll, "viewer-1", [ 0 ], name: "Alice")
    respond(poll, "viewer-2", [ 2 ], name: "Bob")

    hidden = poll.public_attributes
    assert_equal [ true, 2, nil ], hidden.values_at(:open, :responses_count, :results)
    assert_not_includes hidden.to_json, "Alice"

    poll.show_results!
    assert_equal({ respondents: 2, counts: [ 1, 0, 1 ] }, poll.public_attributes[:results])

    detail = poll.host_attributes(respondents: true)
    assert_equal [ [ "Alice" ], [], [ "Bob" ] ], detail[:respondents]
    assert_equal [ "open", false, true ], detail.values_at(:state, :editable, :results_shown)
  end

  test "réponses courtes montrées à la salle : anonymes, les plus récentes d'abord gardées" do
    text = @webinar.polls.create!(position: 1, kind: "short_text", label: "Un mot ?")
    text.open!
    3.times { |i| respond(text, "viewer-#{i}", "Mot #{i}", name: "Personne #{i}") }
    text.close!
    text.show_results!

    assert_equal [ "Mot 0", "Mot 1", "Mot 2" ], text.public_attributes.dig(:results, :answers)
    assert_not_includes text.public_attributes.to_json, "Personne"
    assert_equal({ name: "Personne 0", text: "Mot 0" }, text.host_attributes(respondents: true)[:respondents].first)
  end

  test "un sondage prévu ne coûte aucune requête de réponses à la régie" do
    poll = choice
    queries = 0
    counter = ->(*, payload) { queries += 1 if payload[:sql].include?("poll_responses") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { poll.host_attributes }
    assert_equal 0, queries
    assert_equal [ 0, nil ], poll.host_attributes.values_at(:responses_count, :results)
  end
end
