require "test_helper"

# Courses entre requêtes (vrais threads, vraies connexions SQLite, sans
# transaction de test) : le verrou du webinaire sérialise ouvertures,
# fermetures, résultats montrés et réponses ; l'index partiel est le
# dernier rempart du « un seul sondage ouvert ».
class PollConcurrencyTest < ActiveSupport::TestCase
  include ConcurrentOperations

  self.use_transactional_tests = false

  setup do
    @webinar = Webinar.create!(title: "Concurrence #{SecureRandom.hex(6)}", starts_at: 1.hour.ago,
                               host_sub: "sub-marc", state: "live")
    @first = @webinar.polls.create!(position: 1, kind: "choice", label: "Premier ?", options: %w[A B])
    @second = @webinar.polls.create!(position: 2, kind: "choice", label: "Second ?", options: %w[A B])
  end

  teardown do
    PollResponse.where(poll_id: Poll.where(webinar_id: @webinar.id).select(:id)).delete_all
    Poll.where(webinar_id: @webinar.id).delete_all
    @webinar.reload.destroy!
  end

  test "deux ouvertures simultanées : un seul sondage reste ouvert" do
    outcomes = concurrently(-> { Poll.find(@first.id).open! }, -> { Poll.find(@second.id).open! })

    assert outcomes.none? { |outcome| outcome.is_a?(Exception) }, outcomes.inspect
    assert_equal 1, @webinar.polls.opened.count
    assert_equal 1, @webinar.polls.where.not(closed_at: nil).count
  end

  test "la même réponse envoyée deux fois en même temps : une seule ligne, la dernière valeur" do
    @first.open!
    outcomes = concurrently(
      -> { Poll.find(@first.id).respond!(identity: "viewer-1", name: "Alice", value: [ 0 ]) },
      -> { Poll.find(@first.id).respond!(identity: "viewer-1", name: "Alice", value: [ 1 ]) }
    )

    assert outcomes.all? { |outcome| outcome.is_a?(PollResponse) }, outcomes.inspect
    assert_equal 1, @first.responses.count
    assert_includes [ [ 0 ], [ 1 ] ], @first.responses.sole.value
  end

  test "fermeture contre réponse : la réponse passe avant ou est refusée, jamais après" do
    @first.open!
    outcomes = concurrently(
      -> { Poll.find(@first.id).close! },
      -> { Poll.find(@first.id).respond!(identity: "viewer-1", name: "Alice", value: [ 0 ]) }
    )

    assert outcomes.all? { |outcome| outcome == true || outcome.is_a?(PollResponse) || (outcome.is_a?(Poll::Refused) && outcome.code == :poll_closed) }, outcomes.inspect
    assert_not @first.reload.open?
    if (response = @first.responses.first)
      assert_operator response.updated_at, :<=, @first.closed_at
    end
  end

  # La fin du direct (HandRaiseControl, verrou fichier) écrit sans le verrou
  # du webinaire : c'est la transaction IMMEDIATE de SQLite (un seul
  # écrivain) qui ordonne la fin et la réponse.
  test "fin du direct contre réponse : aucune réponse acceptée après la fin" do
    @first.open!
    outcomes = concurrently(
      -> { Webinar.find(@webinar.id).end! },
      -> { Poll.find(@first.id).respond!(identity: "viewer-1", name: "Alice", value: [ 0 ]) }
    )

    response = outcomes.last
    assert response.is_a?(PollResponse) || (response.is_a?(Poll::Refused) && response.code == :webinar_not_live), response.inspect
    assert_not outcomes.first.is_a?(Exception), outcomes.first.inspect
    assert @webinar.reload.ended?
    refused = assert_raises(Poll::Refused) { Poll.find(@first.id).respond!(identity: "viewer-2", name: "Bob", value: [ 1 ]) }
    assert_equal :webinar_not_live, refused.code
    assert_operator @first.responses.count, :<=, 1
  end

  test "modification contre ouverture : jamais de contenu modifié après le lancement" do
    outcomes = concurrently(
      -> { Poll.find(@first.id).open! },
      -> { Poll.find(@first.id).edit!(label: "Changé ?", options: %w[B A]) }
    )

    assert outcomes.all? { |outcome| outcome == true || (outcome.is_a?(Poll::Refused) && outcome.code == :already_opened) }, outcomes.inspect
    poll = @first.reload
    assert poll.opened_at
    if poll.label == "Changé ?"
      assert_operator poll.updated_at, :<=, poll.opened_at, "modifié avant l'ouverture seulement"
    else
      assert_equal [ "Premier ?", %w[A B] ], [ poll.label, poll.options ]
    end
  end

  test "suppression contre ouverture : un sondage ouvert n'est jamais supprimé" do
    outcomes = concurrently(-> { Poll.find(@first.id).open! }, -> { Poll.find(@first.id).remove! })

    if Poll.exists?(@first.id)
      assert @first.reload.open?
      assert(outcomes.any? { |outcome| outcome.is_a?(Poll::Refused) && outcome.code == :already_opened }, outcomes.inspect)
    else
      assert(outcomes.any? { |outcome| outcome.is_a?(ActiveRecord::RecordNotFound) }, "l'ouverture échoue sur un sondage supprimé : #{outcomes.inspect}")
    end
  end

  test "l'index partiel refuse un second sondage ouvert écrit hors du verrou" do
    @first.open!
    assert_raises(ActiveRecord::RecordNotUnique) do
      Poll.where(id: @second.id).update_all(opened_at: Time.current)
    end
  end
end
