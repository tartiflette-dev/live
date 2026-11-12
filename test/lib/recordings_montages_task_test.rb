# frozen_string_literal: true

require "test_helper"
require "rake"

# `bin/rails "recordings:montages[slug,identité]"` :
# rattrapage du montage de la séance de speaker-9, que
# l'assemblage de sa répétition masquait.
class RecordingsMontagesTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "recordings:montages" }
    @task = Rake::Task["recordings:montages"]
    @task.reenable
    @root = Dir.mktmpdir("montages-task-")
    @prev_root = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = @root
    @webinar = Webinar.create!(title: "Café IA #7", starts_at: 3.hours.ago, host_sub: "sub-marc",
                               state: "ended", started_at: 2.hours.ago, ended_at: 1.hour.ago)
    @original_build_mux = MuxParticipantJob.method(:build_mux)
  end

  teardown do
    original = @original_build_mux
    MuxParticipantJob.define_singleton_method(:build_mux) { |**opts| original.call(**opts) }
    ENV["RECORDINGS_ROOT"] = @prev_root
    FileUtils.remove_entry(@root)
  end

  test "produit le montage manquant d'une personne sans toucher au précédent, et le liste" do
    rehearsal = track("speaker-9", 2.hours.ago)
    old_path = "_participants/#{@webinar.slug}/mux-speaker-9.m4a"
    write(old_path)
    old = @webinar.recordings.create!(kind: :participant, status: :done, participant_identity: "speaker-9",
                                      source_track_ids: [ rehearsal.id ], path: old_path, started_at: 100.minutes.ago)
    session = track("speaker-9", 90.minutes.ago)
    new_path = "_participants/#{@webinar.slug}/mux-speaker-9-seance.m4a"
    write(new_path)
    built = []
    MuxParticipantJob.define_singleton_method(:build_mux) do |track_ids:, **|
      built << track_ids
      Struct.new(:call).new(ParticipantMux::Result.new(relative_path: new_path, track_source: "microphone"))
    end

    output = capture_io { @task.invoke(@webinar.slug, "speaker-9") }.first

    assert_equal [ [ session.id ] ], built
    assert_equal [ "done", old_path ], old.reload.values_at(:status, :path)
    fresh = @webinar.recordings.participants.where.not(id: old.id).sole
    assert_equal [ "done", new_path ], fresh.values_at(:status, :path)
    assert_match(/speaker-9 · montage ##{old.id} · done · #{Regexp.escape(old_path)}/, output)
    assert_match(/speaker-9 · montage ##{fresh.id} · done · #{Regexp.escape(new_path)} · pistes #{session.id}/, output)
  end

  test "une personne dont une piste capte encore est laissée pour plus tard" do
    @webinar.recordings.create!(kind: :track, status: :recording, participant_identity: "host-sub-marc",
                                track_source: "microphone", track_sid: "TR_live", egress_id: "EG_live", started_at: 1.minute.ago)

    output = capture_io { @task.invoke(@webinar.slug, "host-sub-marc") }.first

    assert_match(/host-sub-marc : une piste capte encore/, output)
    assert_empty @webinar.recordings.participants
  end

  test "mode refaire : le montage existant est refait sous son nom" do
    rehearsal = track("speaker-9", 2.hours.ago)
    path = "_participants/#{@webinar.slug}/mux-speaker-9.m4a"
    write(path)
    mux = @webinar.recordings.create!(kind: :participant, status: :done, participant_identity: "speaker-9",
                                      source_track_ids: [ rehearsal.id ], path: path, started_at: 100.minutes.ago)
    built = []
    MuxParticipantJob.define_singleton_method(:build_mux) do |track_ids:, **|
      built << track_ids
      Struct.new(:call).new(ParticipantMux::Result.new(relative_path: path, track_source: "microphone"))
    end

    EpisodePublication.create!(webinar: @webinar, status: "published", started_at: 1.day.ago)

    output = capture_io { @task.invoke(@webinar.slug, "speaker-9", "refaire") }.first

    assert_equal [ [ rehearsal.id ] ], built
    assert_equal [ "done", path ], mux.reload.values_at(:status, :path)
    assert_match(/Assemblages refaits depuis le dernier dépôt dans Nextcloud : relancer la publication/, output)
  end

  # Le rappel suit les assemblages refaits depuis le dernier dépôt, avec ou
  # sans « refaire » (montage en échec relancé).
  test "rappel de publication : seulement si un assemblage a été refait depuis un dépôt" do
    rehearsal = track("speaker-9", 2.hours.ago)
    path = "_participants/#{@webinar.slug}/mux-speaker-9.m4a"
    write(path)
    mux = @webinar.recordings.create!(kind: :participant, status: :failed, participant_identity: "speaker-9",
                                      source_track_ids: [ rehearsal.id ], path: path, started_at: 100.minutes.ago,
                                      ended_at: 90.minutes.ago)
    MuxParticipantJob.define_singleton_method(:build_mux) do |**|
      Struct.new(:call).new(ParticipantMux::Result.new(relative_path: path, track_source: "microphone"))
    end

    without_deposit = capture_io { @task.invoke(@webinar.slug, "speaker-9") }.first
    assert_equal "done", mux.reload.status, "le montage a bien été refait"

    publication = EpisodePublication.create!(webinar: @webinar, status: "published", started_at: 1.minute.from_now)
    @task.reenable
    unchanged = capture_io { @task.invoke(@webinar.slug, "speaker-9") }.first

    mux.update!(status: :failed)
    publication.update!(started_at: 1.hour.ago)
    @task.reenable
    relaunched = capture_io { @task.invoke(@webinar.slug, "speaker-9") }.first

    refute_match(/relancer la publication/, without_deposit)
    refute_match(/relancer la publication/, unchanged)
    assert_match(/Assemblages refaits depuis le dernier dépôt dans Nextcloud : relancer la publication/, relaunched)
  end

  test "mode inconnu : arrêt avant tout montage" do
    track("speaker-9", 2.hours.ago)

    error = assert_raises(SystemExit) { capture_io { @task.invoke(@webinar.slug, "speaker-9", "ecraser") } }

    refute error.success?
    assert_empty @webinar.recordings.participants
  end

  test "activations : reprend media_started_at du journal egress, sans toucher une piste déjà calée" do
    Rake::Task["recordings:activations"].reenable
    camera = track("host-sub-marc", 2.hours.ago)
    camera.update!(egress_id: "EG_testMontageA", track_source: "camera")
    micro = track("host-sub-marc", 2.hours.ago)
    micro.update!(egress_id: "EG_testMontageB", media_started_at: Time.utc(2026, 11, 4, 8, 33, 36, 400_000))
    log = <<~LOG
      2026-11-04T08:33:36.400Z	INFO	egress	info/io.go:178	egress_active	{"nodeID": "NE_x", "clusterID": "", "egressID": "EG_testMontageB", "requestType": "track"}
      2026-11-04T08:33:37.171Z	INFO	egress	pipeline/watch.go:252	pipeline playing	{"nodeID": "NE_x", "egressID": "EG_testMontageA"}
      2026-11-04T08:33:37.172Z	INFO	egress	info/io.go:178	egress_active	{"nodeID": "NE_x", "clusterID": "", "egressID": "EG_testMontageA", "requestType": "track"}
      2026-11-04T09:31:44.145Z	INFO	egress	info/io.go:178	egress_ending	{"nodeID": "NE_x", "egressID": "EG_testMontageA"}
      2026-11-04T08:33:37.000Z	INFO	egress	info/io.go:178	egress_active	{"nodeID": "NE_x", "egressID": "EG_inconnu"}
    LOG

    output = with_stdin(log) { capture_io { Rake::Task["recordings:activations"].invoke }.first }

    assert_equal Time.utc(2026, 11, 4, 8, 33, 37, 172_000), camera.reload.media_started_at
    assert_equal Time.utc(2026, 11, 4, 8, 33, 36, 400_000), micro.reload.media_started_at
    assert_match(/EG_testMontageA · piste ##{camera.id} host-sub-marc camera · calée sur 2026-11-04T08:33:37.172Z/, output)
    assert_match(/EG_testMontageB · piste ##{micro.id} host-sub-marc microphone · déjà calée, inchangée/, output)
    assert_match(/2 piste\(s\) reconnue\(s\) sur 3 activation\(s\) lue\(s\)/, output)
  end

  private

  def with_stdin(text)
    previous = $stdin
    $stdin = StringIO.new(text)
    yield
  ensure
    $stdin = previous
  end

  def track(identity, started_at)
    path = "#{@webinar.slug}/#{SecureRandom.uuid}.ogg"
    write(path)
    @webinar.recordings.create!(kind: :track, status: :done, participant_identity: identity, track_source: "microphone",
                                path: path, started_at: started_at, ended_at: started_at + 5.minutes)
  end

  def write(relative)
    full = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, "x")
  end
end
