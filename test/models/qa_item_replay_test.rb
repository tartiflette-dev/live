require "test_helper"

# Questions posées depuis le replay : même file que celles du direct
# (QaItem, source replay), ancrées à l'instant de la vidéo, avec leur
# auteur ; effacées avec l'inscription ; jamais rapprochées d'un message du
# chat par le LLM.
class QaItemReplayTest < ActiveSupport::TestCase
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("qa-replay")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    @ines = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
    @spectator = spectator_user
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  def ask(viewer = @ines, label: "  Et pour   les PME ?  ", at: 754.2)
    QaItem.ask_from_replay!(replay: @replay, viewer: viewer, label: label, at: at)
  end

  test "question d'un inscrit : file du webinaire, ouverte, texte tel quel, instant et auteur" do
    item = ask

    assert_equal [ @webinar, "replay", "open", "Et pour les PME ?", 754.2, @ines, nil ],
                 [ item.webinar, item.source, item.status, item.label, item.video_position, item.registration, item.user ]
    assert_equal [ { name: "Inès", role: "viewer" } ], item.authors
    console = item.console_attributes
    assert_equal [ "replay", 754.2, [] ], console.values_at(:source, :video_position, :messages)
    assert_includes @webinar.qa_items.queue_order, item
  end

  test "question d'un compte undust : auteur = le compte ; instant borné à la vidéo" do
    item = ask(@spectator, at: 99_999)

    assert_equal [ { name: "spectatrice", role: "account" } ], item.authors
    assert_equal @replay.duration, item.video_position
    assert_equal 0.0, ask(@spectator, at: -5).video_position
  end

  test "libellé vide ou trop long : refusé ; personne effacée entre-temps : rien" do
    assert_raises(ActiveRecord::RecordInvalid) { ask(label: "   ") }
    assert_raises(ActiveRecord::RecordInvalid) { ask(label: "x" * (QaItem::LABEL_LIMIT + 1)) }

    gone = confirmed_registration(@webinar, "parti@example.test")
    gone.delete
    assert_nil ask(gone)
    assert_equal 0, QaItem.count
  end

  test "base : une question du replay a un instant et une seule personne ; une question du direct n'en a pas" do
    row = ->(**attributes) { { webinar_id: @webinar.id, label: "?", status: "open", created_at: Time.current, updated_at: Time.current, **attributes } }

    assert_raises(ActiveRecord::StatementInvalid) { QaItem.insert!(row.call(source: "replay", registration_id: @ines.id)) }
    assert_raises(ActiveRecord::StatementInvalid) { QaItem.insert!(row.call(source: "replay", video_position: 1)) }
    assert_raises(ActiveRecord::StatementInvalid) do
      QaItem.insert!(row.call(source: "replay", video_position: 1, registration_id: @ines.id, user_id: @spectator.id))
    end
    assert_raises(ActiveRecord::StatementInvalid) { QaItem.insert!(row.call(source: "manual", registration_id: @ines.id)) }
  end

  test "le LLM ne rattache jamais un message du chat à une question du replay" do
    item = ask
    message = @webinar.messages.create!(author_identity: "viewer-77", name: "Bob", body: "Et pour les PME ?")

    live = QaItem.enqueue!(message: message, label: "Et pour les PME ?", source: "llm", duplicate_of: item.id)

    assert_not_equal item, live
    assert_equal :created, live.enqueued
    assert_empty item.reload.messages
    assert_equal [ live.id ], @webinar.qa_items.open.from_live.ids
  end

  test "effacement (crm:erase) : ses questions du replay et ses réponses du replay partent avec l'inscription" do
    ask
    other = ask(@spectator)
    poll = @webinar.polls.create!(position: 1, kind: "choice", label: "?", options: %w[A B],
                                  opened_at: @replay.recording.started_at + 60, closed_at: @replay.recording.started_at + 120)
    poll.respond_from_replay!(viewer: @ines, value: [ 0 ])

    counts = CrmErasure.erase!(@ines.email)

    assert_equal 1, counts[:qa_items]
    assert_equal 1, counts[:poll_responses]
    assert_equal [ other ], QaItem.all.to_a
    assert_equal 0, PollResponse.count
  end

  test "compte supprimé : ses questions du replay partent avec lui" do
    ask(@spectator)

    @spectator.delete

    assert_equal 0, QaItem.count
  end
end
