require "test_helper"

class ReplayStatsTest < ActiveSupport::TestCase
  include ReplayHelpers

  test "par personne : vues, temps regardé, part vue et passages, dernier visionnage d'abord" do
    with_recordings_root do
      replay = replay_cafe
      registration = confirmed_registration(replay.webinar, "ines@example.test", name: "Inès")
      user = spectator_user
      t0 = Time.zone.parse("2030-01-20 10:00")
      replay.views.create!(registration: registration, session_key: session_key, started_at: t0, last_seen_at: t0 + 10.minutes,
                           watched_seconds: 600, intervals: [ [ 0.0, 600.0 ] ])
      replay.views.create!(registration: registration, session_key: session_key, started_at: t0 + 1.day,
                           last_seen_at: t0 + 1.day, watched_seconds: 300, intervals: [ [ 300.0, 900.0 ] ])
      replay.views.create!(registration: registration, session_key: session_key, started_at: t0 + 2.days,
                           last_seen_at: t0 + 2.days, watched_seconds: 0, intervals: [])
      replay.views.create!(user: user, session_key: session_key, started_at: t0, last_seen_at: t0 + 3.days,
                           watched_seconds: 1699, intervals: [ [ 0.0, 1699.0 ] ])

      stats = ReplayStats.new(replay)
      first, second = stats.rows

      assert_equal user, first.viewer
      assert first.via_account?
      assert_equal "spectatrice", first.name
      assert_in_delta 0.5, first.ratio, 0.001

      assert_equal registration, second.viewer
      assert_equal "Inès", second.name
      assert_equal 2, second.views_count, "une séance sans lecture n'est pas une vue"
      assert_in_delta 900.0, second.watched_seconds
      assert_equal [ [ 0.0, 900.0 ] ], second.intervals
      assert_in_delta 900.0 / 3398, second.ratio, 0.001
      assert_equal t0 + 2.days, second.last_seen_at
      assert_equal 3, stats.total_views
    end
  end
end
