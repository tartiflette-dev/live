require "test_helper"

# Premiers battements concurrents d'une séance neuve (vrais threads, vraies
# connexions SQLite, sans transaction de test) : l'index unique et le verrou
# donnent une seule séance, sans erreur. Selon l'ordre d'arrivée, le second
# battement est crédité ou ignoré (plus ancien que le premier) : le test ne
# fixe pas lequel.
class ReplayViewConcurrencyTest < ActiveSupport::TestCase
  include ConcurrentOperations
  include ReplayHelpers

  self.use_transactional_tests = false

  setup do
    @previous_root = ENV["RECORDINGS_ROOT"]
    @tmp = Dir.mktmpdir("replay-view-concurrency")
    ENV["RECORDINGS_ROOT"] = @tmp
    @replay = replay_cafe
    @registration = confirmed_registration(@replay.webinar, "concurrence-#{SecureRandom.hex(4)}@example.test")
    @key = session_key
    @t0 = Time.zone.parse("2030-01-20 10:00:00")
  end

  teardown do
    webinar = @replay.webinar
    ReplayView.where(replay_id: @replay.id).delete_all
    Replay.where(id: @replay.id).delete_all
    Registration.where(webinar_id: webinar.id).delete_all
    Recording.where(webinar_id: webinar.id).delete_all
    Webinar.where(id: webinar.id).delete_all
    User.where(oidc_sub: "publication-host").delete_all
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  test "deux premiers battements simultanés d'une séance neuve : une seule séance" do
    beat = ->(from, to, at) { ReplayView.beat!(replay: Replay.find(@replay.id), viewer: Registration.find(@registration.id),
                                               session_key: @key, from: from, to: to, playing: true, now: at) }
    outcomes = concurrently(-> { beat.call(0, 10, @t0) }, -> { beat.call(10, 25, @t0 + 15) })

    assert outcomes.none? { |outcome| outcome.is_a?(Exception) }, outcomes.inspect
    view = ReplayView.where(replay_id: @replay.id).sole
    assert_includes 1..2, view.beats_count
    assert_operator view.watched_seconds, :>, 0
  end
end
