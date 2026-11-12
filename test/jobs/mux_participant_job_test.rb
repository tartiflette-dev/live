# frozen_string_literal: true

require "test_helper"

# MuxParticipantJob — orchestration du montage par personne. Le service
# ParticipantMux est STUBBÉ via le seam `build_mux` : le job teste l'enveloppe
# idempotence + persistance Recording participant, pas ffmpeg lui-même
# (couvert par participant_mux_test + participant_mux_ffmpeg_test).
class MuxParticipantJobTest < ActiveJob::TestCase
  setup do
    @tmp_root = Pathname.new(Dir.mktmpdir("mux-job-test"))
    @prev_root = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = @tmp_root.to_s

    @webinar = Webinar.create!(
      title: "Job", slug: "mux-job-#{SecureRandom.hex(3)}",
      starts_at: 1.hour.ago,
      host_sub: "host-#{SecureRandom.hex(3)}",
      room_name: "room-#{SecureRandom.hex(3)}",
      state: "ended", kind: "cafe_ia"
    )
    @identity = "speaker-11"
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @prev_root
    FileUtils.remove_entry(@tmp_root) if File.directory?(@tmp_root)
    restore_build_mux!
  end

  test "crée un Recording participant et le passe en done quand le mux réussit" do
    make_track(source: "camera",     status: "done", path_suffix: ".mp4")
    make_track(source: "microphone", status: "done", path_suffix: ".ogg")

    # La sortie mux vit sous participants/<slug>/, pas <slug>/.
    output_rel = "_participants/#{@webinar.slug}/mux-ok.mp4"
    touch_absolute(output_rel) # simule la sortie ffmpeg
    swap_build_mux(FakeMux.new(result_rel: output_rel, track_source: "camera+microphone"))

    MuxParticipantJob.perform_now(@webinar.id, @identity)

    rec = @webinar.recordings.participants.find_by!(participant_identity: @identity)
    assert_equal "done", rec.status
    assert_equal output_rel, rec.path
    assert_equal "camera+microphone", rec.track_source
    assert rec.downloadable?
  end

  test "montage avec réserve : done, track_source réel et note de la piste écartée persistée" do
    make_track(source: "camera",     status: "done", path_suffix: ".webm")
    make_track(source: "microphone", status: "done", path_suffix: ".ogg")
    output_rel = "_participants/#{@webinar.slug}/mux-partial.m4a"
    touch_absolute(output_rel)
    note = "piste camera 1 écartée : aucun paquet video exploitable"
    swap_build_mux(FakeMux.new(result_rel: output_rel, extension: ".m4a", track_source: "microphone", note: note))

    MuxParticipantJob.perform_now(@webinar.id, @identity)

    rec = @webinar.recordings.participants.find_by!(participant_identity: @identity)
    assert_equal "done", rec.status
    assert_equal "microphone", rec.track_source
    assert_equal note, rec.error_message
    assert rec.caveat?
    assert rec.downloadable?
  end

  test "relance après échec : le montage réussi efface l'ancien message d'erreur" do
    track = make_track(source: "microphone", status: "done", path_suffix: ".ogg")
    output_rel = "_participants/#{@webinar.slug}/mux-retry.m4a"
    touch_absolute(output_rel)
    @webinar.recordings.create!(
      kind: :participant, status: :failed, participant_identity: @identity, source_track_ids: [ track.id ],
      started_at: 1.hour.ago, error_message: "Mux participant échoué : ancien"
    )
    swap_build_mux(FakeMux.new(result_rel: output_rel, extension: ".m4a", track_source: "microphone"))

    MuxParticipantJob.perform_now(@webinar.id, @identity)

    rec = @webinar.recordings.participants.find_by!(participant_identity: @identity)
    assert_equal "done", rec.status
    assert_nil rec.error_message
    refute rec.caveat?
    assert_equal [ track.id ], rec.source_track_ids
    assert_equal 1, @webinar.recordings.participants.count, "la relance reprend le lot, elle n'en crée pas un autre"
  end

  test "idempotent : un lot déjà monté (fichier présent) n'est pas refait" do
    track = make_track(source: "microphone", status: "done", path_suffix: ".ogg")
    existing = make_mux([ track ], "existing.m4a")

    swap_build_mux(RaiseMux.new("should not be called"))

    MuxParticipantJob.perform_now(@webinar.id, @identity)

    assert_equal [ existing.id ], @webinar.recordings.participants.ids
  end

  # Nouveau calage : les montages existants sont refaits, sous le même nom,
  # sur demande explicite seulement.
  test "reconstruction : un lot déjà monté est refait sous son nom et sa note est remplacée" do
    track = make_track(source: "microphone", status: "done", path_suffix: ".ogg")
    existing = make_mux([ track ], "existing.m4a")
    existing.update!(error_message: "calage lèvres/voix approximatif : ancien")
    fake = FakeMux.new(result_rel: existing.path, extension: ".m4a", track_source: "microphone")
    swap_build_mux(fake)

    MuxParticipantJob.perform_now(@webinar.id, @identity, rebuild: true)

    assert_equal [ [ track.id ] ], fake.built_with
    assert_equal [ existing.id ], @webinar.recordings.participants.ids, "aucun nouveau lot"
    assert_equal [ "done", existing.path, nil ], existing.reload.values_at(:status, :path, :error_message)
  end

  test "reconstruction : un lot en cours d'assemblage par un autre job n'est pas relancé" do
    track = make_track(source: "microphone", status: "done", path_suffix: ".ogg")
    in_progress = @webinar.recordings.create!(kind: :participant, status: :starting, participant_identity: @identity,
                                              source_track_ids: [ track.id ], started_at: 1.minute.ago)
    swap_build_mux(RaiseMux.new("should not be called"))

    MuxParticipantJob.perform_now(@webinar.id, @identity, rebuild: true)

    assert_equal "starting", in_progress.reload.status
  end

  test "reconstruction en échec : le montage passe failed, l'ancien fichier reste sur disque" do
    track = make_track(source: "microphone", status: "done", path_suffix: ".ogg")
    existing = make_mux([ track ], "existing.m4a")
    swap_build_mux(FailMux.new(ParticipantMux::FfmpegFailed.new("ffmpeg rc=1")))

    MuxParticipantJob.perform_now(@webinar.id, @identity, rebuild: true)

    assert_equal "failed", existing.reload.status
    assert_match(/ffmpeg rc=1/, existing.error_message)
    assert File.file?(Recording.recordings_root.join(existing.path)), "l'ancien montage n'est pas effacé"
  end

  # Cas réel : l'assemblage de la répétition de speaker-9 masquait
  # la séance, jamais montée.
  test "répétition puis séance : la séance reçoit son propre montage, celui de la répétition reste intact" do
    rehearsal = [ make_track(source: "camera", status: "done", path_suffix: ".mp4", started_at: 90.minutes.ago),
                  make_track(source: "microphone", status: "done", path_suffix: ".ogg", started_at: 90.minutes.ago) ]
    rehearsal_mux = make_mux(rehearsal, "mux-#{@identity}.mp4")
    session = [ make_track(source: "camera", status: "done", path_suffix: ".mp4", started_at: 60.minutes.ago),
                make_track(source: "microphone", status: "done", path_suffix: ".ogg", started_at: 60.minutes.ago) ]
    session_rel = "_participants/#{@webinar.slug}/mux-#{@identity}-seance.mp4"
    touch_absolute(session_rel)
    fake = FakeMux.new(result_rel: session_rel, track_source: "camera+microphone")
    swap_build_mux(fake)

    MuxParticipantJob.perform_now(@webinar.id, @identity)

    assert_equal [ session.map(&:id).sort ], fake.built_with, "le montage ne prend que les pistes de la séance"
    session_mux = @webinar.recordings.participants.where.not(id: rehearsal_mux.id).sole
    assert_equal "done", session_mux.status
    assert_equal session_rel, session_mux.path
    assert_equal session.map(&:id).sort, session_mux.source_track_ids
    assert_equal [ "done", "_participants/#{@webinar.slug}/mux-#{@identity}.mp4" ], rehearsal_mux.reload.values_at(:status, :path)
    assert rehearsal_mux.downloadable?, "le fichier de la répétition n'est pas touché"

    swap_build_mux(RaiseMux.new("should not be called"))
    MuxParticipantJob.perform_now(@webinar.id, @identity)
    assert_equal 2, @webinar.recordings.participants.count, "rien de neuf : pas de troisième montage"
  end

  # Caméra et micro qui s'arrêtent ensemble planifient
  # deux jobs ; le second ne lance pas un second ffmpeg sur le même lot.
  test "un lot en cours d'assemblage par un autre job n'est pas relancé" do
    track = make_track(source: "microphone", status: "done", path_suffix: ".ogg")
    in_progress = @webinar.recordings.create!(kind: :participant, status: :starting, participant_identity: @identity,
                                              source_track_ids: [ track.id ], started_at: 1.minute.ago)
    swap_build_mux(RaiseMux.new("should not be called"))

    MuxParticipantJob.perform_now(@webinar.id, @identity)

    assert_equal [ in_progress.id ], @webinar.recordings.participants.ids
    assert_equal "starting", in_progress.reload.status
  end

  test "un lot resté en cours au-delà du délai (job mort) est repris" do
    track = make_track(source: "microphone", status: "done", path_suffix: ".ogg")
    stale = @webinar.recordings.create!(kind: :participant, status: :starting, participant_identity: @identity,
                                        source_track_ids: [ track.id ], started_at: MuxParticipantJob::STALE_AFTER.ago - 1.minute)
    output_rel = "_participants/#{@webinar.slug}/mux-repris.m4a"
    touch_absolute(output_rel)
    swap_build_mux(FakeMux.new(result_rel: output_rel, extension: ".m4a", track_source: "microphone"))

    MuxParticipantJob.perform_now(@webinar.id, @identity)

    assert_equal [ "done", output_rel ], stale.reload.values_at(:status, :path)
  end

  test "ne tourne pas tant qu'une piste de la personne est encore active" do
    make_track(source: "camera",     status: "done",      path_suffix: ".mp4")
    make_track(source: "microphone", status: "recording", path_suffix: nil)

    swap_build_mux(RaiseMux.new("should not be called"))

    MuxParticipantJob.perform_now(@webinar.id, @identity)

    assert_nil @webinar.recordings.participants.find_by(participant_identity: @identity)
  end

  test "fail-loud : service lève → Recording participant marqué failed avec message" do
    make_track(source: "camera", status: "done", path_suffix: ".mp4")

    swap_build_mux(FailMux.new(ParticipantMux::FfmpegFailed.new("rc=1 broken")))

    MuxParticipantJob.perform_now(@webinar.id, @identity)

    rec = @webinar.recordings.participants.find_by!(participant_identity: @identity)
    assert_equal "failed", rec.status
    assert_match(/rc=1 broken/, rec.error_message)
  end

  private

  def make_mux(tracks, filename)
    path = "_participants/#{@webinar.slug}/#{filename}"
    touch_absolute(path)
    @webinar.recordings.create!(
      kind: :participant, status: :done, participant_identity: @identity, source_track_ids: tracks.map(&:id).sort,
      started_at: 1.hour.ago, ended_at: 10.minutes.ago, path: path
    )
  end

  def make_track(source:, status:, path_suffix:, started_at: 1.hour.ago)
    path = path_suffix ? "#{@webinar.slug}/#{SecureRandom.uuid}#{path_suffix}" : nil
    rec = Recording.create!(
      webinar: @webinar, kind: "track", status: status,
      participant_identity: @identity, track_source: source,
      started_at: started_at,
      ended_at: Recording::ACTIVE_STATUSES.include?(status) ? nil : 30.minutes.ago,
      path: path
    )
    touch_absolute(path) if path
    rec
  end

  def touch_absolute(relative_path)
    full = Recording.recordings_root.join(relative_path)
    FileUtils.mkdir_p(full.dirname)
    File.binwrite(full, "x")
    full
  end

  def swap_build_mux(fake)
    @original_build_mux = MuxParticipantJob.method(:build_mux)
    MuxParticipantJob.define_singleton_method(:build_mux) do |track_ids:, **_opts|
      fake.built_with << track_ids if fake.respond_to?(:built_with)
      fake
    end
  end

  def restore_build_mux!
    return unless @original_build_mux
    original = @original_build_mux
    MuxParticipantJob.define_singleton_method(:build_mux) { |**opts| original.call(**opts) }
    @original_build_mux = nil
  end

  # Doubles minimaux : reproduisent uniquement ce que le job consomme.
  class FakeMux
    attr_reader :built_with

    def initialize(result_rel:, track_source:, extension: ".mp4", note: nil)
      @built_with = []
      @result = ParticipantMux::Result.new(
        relative_path: result_rel, extension: extension, duration_seconds: 2.0,
        content_type: "video/mp4", track_source: track_source, note: note
      )
    end
    def call = @result
  end

  class RaiseMux
    def initialize(msg); @msg = msg; end
    def call; raise @msg; end
  end

  class FailMux
    def initialize(error); @error = error; end
    def call; raise @error; end
  end
end
