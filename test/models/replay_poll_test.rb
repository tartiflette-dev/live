require "test_helper"

# Sondages du direct dans le replay : créneau en secondes de la vidéo de
# référence, réponse depuis le replay (une par personne, jamais à la place
# d'une réponse du direct), résultats direct + replay réunis pour le
# spectateur, et mesure du direct jamais faussée.
class ReplayPollTest < ActiveSupport::TestCase
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-poll")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @webinar = @replay.webinar
    @origin = @replay.recording.started_at # 09:31:06, vidéo de 56 min 38 s
    @ines = confirmed_registration(@webinar, "ines@example.test", name: "Inès")
    @spectator = spectator_user
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  def poll(opened: 10.minutes, closed: 12.minutes, kind: "choice", options: %w[Oui Non], **attributes)
    @webinar.polls.create!(position: @webinar.polls.count + 1, kind: kind, label: "Ça vous parle ?", options: options,
                           opened_at: opened && @origin + opened, closed_at: closed && @origin + closed, **attributes)
  end

  def live_answer(poll, identity, value, registration: nil)
    poll.responses.create!(respondent_identity: identity, name: identity, value: value, registration: registration)
  end

  test "créneau : de l'ouverture à la fermeture, en secondes de la vidéo de référence" do
    poll

    replay_poll = ReplayPoll.for(@replay).sole
    assert_equal [ 600.0, 720.0 ], [ replay_poll.start_second, replay_poll.end_second ]
  end

  test "un sondage ouvert peu de temps reste une minute ; resté ouvert, jusqu'à la fin de la vidéo" do
    short = poll(opened: 10.minutes, closed: 10.minutes + 15)
    open = poll(opened: 50.minutes, closed: nil)

    windows = ReplayPoll.for(@replay).to_h { |replay_poll| [ replay_poll.poll, [ replay_poll.start_second, replay_poll.end_second ] ] }
    assert_equal [ 600.0, 660.0 ], windows[short]
    assert_equal [ 3000.0, @replay.duration ], windows[open]
  end

  test "jamais lancé ou lancé après la vidéo : absent ; lancé avant le début : à 0" do
    poll(opened: nil, closed: nil)
    poll(opened: 2.hours, closed: 2.hours + 60)
    early = poll(opened: -30, closed: 90)

    replay_poll = ReplayPoll.for(@replay).sole
    assert_equal early, replay_poll.poll
    assert_equal [ 0.0, 90.0 ], [ replay_poll.start_second, replay_poll.end_second ]
  end

  test "réponse du replay : origine replay, identité de l'inscription ; remplacée par une nouvelle réponse du replay" do
    question = poll

    question.respond_from_replay!(viewer: @ines, value: [ 1 ])
    response = question.respond_from_replay!(viewer: @ines, value: [ 0 ])

    assert_equal [ "replay", "viewer-#{@ines.id}", @ines, "Inès", [ 0 ] ],
                 [ response.origin, response.respondent_identity, response.registration, response.name, response.value ]
    assert_equal 1, question.responses.count
  end

  test "compte undust : identité account-<id>, nom du compte" do
    response = poll.respond_from_replay!(viewer: @spectator, value: [ 0 ])

    assert_equal [ "account-#{@spectator.id}", @spectator, nil, "spectatrice" ],
                 [ response.respondent_identity, response.user, response.registration, response.name ]
  end

  test "déjà répondu au direct (inscription, ou compte qui animait) : refusé, la réponse du direct reste" do
    question = poll
    live_answer(question, "viewer-#{@ines.id}", [ 1 ], registration: @ines)
    host = User.find_by!(oidc_sub: "publication-host")
    live_answer(question, "host-#{host.oidc_sub}", [ 0 ])

    [ @ines, host ].each do |viewer|
      refusal = assert_raises(Poll::Refused) { question.respond_from_replay!(viewer: viewer, value: [ 0 ]) }
      assert_equal :answered_live, refusal.code
    end
    assert_equal [ "live", "live" ], question.responses.pluck(:origin)
    assert_equal [ 1 ], question.responses.find_by(registration: @ines).value
  end

  test "sondage jamais lancé, personne effacée entre-temps, réponse hors format : refusés" do
    assert_equal :not_in_replay, assert_raises(Poll::Refused) { poll(opened: nil, closed: nil).respond_from_replay!(viewer: @ines, value: [ 0 ]) }.code

    question = poll
    gone = confirmed_registration(@webinar, "parti@example.test")
    gone.delete
    assert_equal :viewer_gone, assert_raises(Poll::Refused) { question.respond_from_replay!(viewer: gone, value: [ 0 ]) }.code
    assert_raises(ActiveRecord::RecordInvalid) { question.respond_from_replay!(viewer: @ines, value: [ 7 ]) }
    assert_equal 0, question.responses.count
  end

  test "la régie et la salle ne comptent que le direct ; le replay ne fausse jamais la mesure" do
    question = poll(results_shown_at: @origin + 12.minutes)
    live_answer(question, "viewer-900", [ 0 ])
    question.respond_from_replay!(viewer: @ines, value: [ 1 ])
    question.respond_from_replay!(viewer: @spectator, value: [ 1 ])

    assert_equal({ respondents: 1, counts: [ 1, 0 ] }, question.results)
    assert_equal 1, question.public_attributes[:responses_count]
    host = question.host_attributes(respondents: true)
    assert_equal [ 1, { respondents: 1, counts: [ 1, 0 ] } ], [ host[:responses_count], host[:results] ]
    assert_equal [ [ "viewer-900" ], [] ], host[:respondents]
    assert_equal({ respondents: 2, counts: [ 0, 2 ] }, question.results(question.responses.replay))
  end

  test "spectateur : pas de résultat avant d'avoir répondu ; après, direct + replay réunis avec la part de chacun" do
    question = poll
    live_answer(question, "viewer-900", [ 0 ])

    before = ReplayPoll.for(@replay).sole.attributes_for(@ines)
    assert_equal [ nil, nil ], before.values_at(:my_response, :results)

    question.respond_from_replay!(viewer: @ines, value: [ 1 ])
    after = ReplayPoll.for(@replay).sole.attributes_for(@ines)
    assert_equal({ value: [ 1 ], origin: "replay" }, after[:my_response])
    assert_equal({ respondents: 2, counts: [ 1, 1 ], live: 1, replay: 1 }, after[:results])
    assert_equal [ question.id, "choice", %w[Oui Non], 600.0, 720.0 ], after.values_at(:id, :kind, :options, :start, :end)
  end

  test "spectateur qui a répondu au direct : sa réponse du direct et le résultat" do
    question = poll
    live_answer(question, "viewer-#{@ines.id}", [ 0 ], registration: @ines)

    attributes = ReplayPoll.for(@replay).sole.attributes_for(@ines)
    assert_equal({ value: [ 0 ], origin: "live" }, attributes[:my_response])
    assert_equal({ respondents: 1, counts: [ 1, 0 ], live: 1, replay: 0 }, attributes[:results])
  end

  test "réponse courte : le résultat se limite au nombre de réponses, jamais les textes" do
    question = poll(kind: "short_text", options: nil)
    live_answer(question, "viewer-900", "un texte du direct")
    question.respond_from_replay!(viewer: @ines, value: "mon avis")

    results = ReplayPoll.for(@replay).sole.attributes_for(@ines)[:results]
    assert_equal({ live: 1, replay: 1, respondents: 2 }, results)
  end

  test "réponse reprise au direct (direct relancé) : elle devient une réponse du direct" do
    question = poll
    question.respond_from_replay!(viewer: @ines, value: [ 1 ])
    @webinar.update!(state: "live")
    question.update_columns(closed_at: nil)

    question.respond!(identity: "viewer-#{@ines.id}", name: "Inès", value: [ 0 ], registration: @ines)

    assert_equal [ [ "live", [ 0 ] ] ], question.responses.pluck(:origin, :value)
  end

  test "base : origine connue ; une réponse du replay a une seule personne" do
    row = ->(origin, **extra) { { poll_id: poll.id, respondent_identity: "account-1", name: "X", value: [ 0 ].to_json, origin: origin,
                                  created_at: Time.current, updated_at: Time.current, **extra } }

    assert_raises(ActiveRecord::StatementInvalid) { PollResponse.insert!(row.call("autre")) }
    assert_raises(ActiveRecord::StatementInvalid) { PollResponse.insert!(row.call("replay")) }
    assert_raises(ActiveRecord::StatementInvalid) do
      PollResponse.insert!(row.call("replay", user_id: @spectator.id, registration_id: @ines.id))
    end
  end
end
