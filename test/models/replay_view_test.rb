require "test_helper"

class ReplayViewTest < ActiveSupport::TestCase
  include ReplayHelpers

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-view")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @registration = confirmed_registration(@replay.webinar, "ines@example.test", name: "Inès")
    @key = session_key
    @t0 = Time.zone.parse("2030-01-20 10:00:00")
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  def beat(from, to, at:, playing: true, viewer: @registration, key: @key)
    ReplayView.beat!(replay: @replay, viewer: viewer, session_key: key, from: from, to: to, playing: playing, now: at)
  end

  test "le passage lu entre deux battements est crédité" do
    beat(0, 14, at: @t0)
    view = beat(14, 29, at: @t0 + 15)

    assert_equal [ [ 0.0, 29.0 ] ], view.intervals
    assert_in_delta 29.0, view.watched_seconds
    assert_equal 2, view.beats_count
    assert_equal @registration, view.viewer
    assert_in_delta 29.0, view.last_position
  end

  test "un passage plus long que le temps écoulé n'est pas crédité" do
    beat(0, 10, at: @t0)
    view = beat(10, 600, at: @t0 + 15)

    assert_equal [ [ 0.0, 10.0 ] ], view.intervals
    assert_in_delta 10.0, view.watched_seconds
    assert_in_delta 600.0, view.last_position, 0.001, "la position suit quand même"
  end

  test "premier battement : au plus FIRST_BEAT_MAX_SPAN secondes" do
    view = beat(0, 3000, at: @t0)
    assert_empty view.intervals
    assert_in_delta 0.0, view.watched_seconds
  end

  test "lecture accélérée ×2 créditée ; passage revu : temps cumulé, passages fusionnés" do
    beat(0, 10, at: @t0)
    beat(10, 40, at: @t0 + 15)
    view = beat(5, 20, at: @t0 + 30)

    assert_equal [ [ 0.0, 40.0 ] ], view.intervals
    assert_in_delta 55.0, view.watched_seconds
  end

  test "battement trop rapproché du précédent : ignoré, sans écriture" do
    beat(0, 10, at: @t0)
    view = beat(10, 11, at: @t0 + 1)

    assert_equal 1, view.reload.beats_count
    assert_in_delta 10.0, view.watched_seconds
  end

  test "positions bornées à la durée de la vidéo" do
    beat(@replay.duration - 5, @replay.duration + 50, at: @t0)
    view = @replay.views.sole

    assert_equal [ [ @replay.duration - 5, @replay.duration ] ], view.intervals
  end

  test "la séance d'une personne n'accepte pas les battements d'une autre" do
    beat(0, 10, at: @t0)
    intruder = confirmed_registration(@replay.webinar, "autre@example.test")

    assert_raises(ReplayView::Refused) { beat(10, 20, at: @t0 + 15, viewer: intruder) }
    assert_raises(ReplayView::Refused) { beat(10, 20, at: @t0 + 15, viewer: spectator_user) }
  end

  test "au plus MAX_SESSIONS_PER_DAY séances par personne et par jour" do
    ReplayView::MAX_SESSIONS_PER_DAY.times do |index|
      @replay.views.create!(registration: @registration, session_key: session_key, started_at: @t0 - index.minutes,
                            last_seen_at: @t0)
    end

    error = assert_raises(ReplayView::Refused) { beat(0, 10, at: @t0) }
    assert_equal "sessions_cap", error.message
    assert beat(0, 10, at: @t0 + 1.day + 1.hour).persisted?, "le lendemain, une nouvelle séance s'ouvre"
  end

  test "identifiant de séance : un UUID v4, rien d'autre" do
    assert_raises(ActiveRecord::RecordInvalid) { beat(0, 10, at: @t0, key: "pas-un-uuid") }
  end

  test "un compte undust ouvre ses propres séances" do
    user = spectator_user
    view = beat(0, 12, at: @t0, viewer: user, key: session_key)

    assert_equal user, view.viewer
    assert_nil view.registration
  end

  test "au-delà de MAX_INTERVALS passages distincts, le temps compte mais le passage n'est pas gardé" do
    intervals = Array.new(ReplayView::MAX_INTERVALS) { |index| [ index * 10.0, index * 10.0 + 2 ] }
    view = @replay.views.create!(registration: @registration, session_key: @key, started_at: @t0,
                                 last_seen_at: @t0, beats_count: 1, intervals: intervals)

    beat(3000, 3010, at: @t0 + 15)

    assert_equal ReplayView::MAX_INTERVALS, view.reload.intervals.size
    assert_in_delta 10.0, view.watched_seconds
  end

  test "effacement d'une personne : ses séances partent avec ses inscriptions" do
    beat(0, 10, at: @t0)
    CrmErasure.erase!(@registration.email)

    assert_equal 0, ReplayView.count
  end

  test "merge_intervals fusionne chevauchements et trous de moins d'une seconde" do
    assert_equal [ [ 0.0, 20.0 ], [ 30.0, 40.0 ] ],
                 ReplayView.merge_intervals([ [ 30.0, 40.0 ], [ 0.0, 10.0 ], [ 10.5, 20.0 ], [ 5.0, 8.0 ] ])
  end
end
