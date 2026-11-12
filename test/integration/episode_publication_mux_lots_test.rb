# frozen_string_literal: true

require "test_helper"

# Règle « assemblages finalisés » (EpisodePublication.unmuxed_identities)
# face au vrai MuxParticipantJob, un montage par lot de pistes : le cas du
# Cas réel : une répétition puis la séance pour la même personne.
# Seul ffmpeg est remplacé (seam build_mux).
class EpisodePublicationMuxLotsTest < ActiveJob::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include EpisodePublicationHelpers

  # Écrit le fichier que ffmpeg aurait produit, comme le vrai service.
  class WritingMux
    def initialize(identity:, track_ids:)
      @relative = "#{Recording::PARTICIPANTS_SUBDIR}/cafe-ia-7/mux-#{identity}-#{track_ids.join('-')}.mp4"
    end

    def call
      absolute = Recording.recordings_root.join(@relative)
      FileUtils.mkdir_p(absolute.dirname)
      File.binwrite(absolute, "mux")
      ParticipantMux::Result.new(relative_path: @relative, extension: ".mp4", duration_seconds: 1.0,
                                 content_type: "video/mp4", track_source: "camera+microphone", note: nil)
    end
  end

  setup do
    @original_build = MuxParticipantJob.method(:build_mux)
    MuxParticipantJob.define_singleton_method(:build_mux) do |webinar:, identity:, track_ids:|
      WritingMux.new(identity: identity, track_ids: track_ids)
    end
  end

  teardown do
    MuxParticipantJob.define_singleton_method(:build_mux, @original_build)
  end

  test "la séance d'une personne déjà assemblée à la répétition retient le dépôt jusqu'à son propre assemblage" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      rehearsal = Time.zone.parse("2030-01-17 09:09:27")
      session_end = Time.zone.parse("2030-01-17 10:27:44")

      add_recording(webinar, kind: "track", identity: "speaker-9", source: "camera", file: "repetition.mp4",
                             started: rehearsal - 6.minutes, ended: rehearsal)
      travel_to(rehearsal + 5.seconds) { MuxParticipantJob.perform_now(webinar.id, "speaker-9") }
      assert_empty EpisodePublication.unmuxed_identities(webinar)

      add_recording(webinar, kind: "track", identity: "speaker-9", source: "camera", file: "seance.mp4",
                             started: rehearsal + 20.minutes, ended: session_end)
      assert_equal [ "speaker-9" ], EpisodePublication.unmuxed_identities(webinar), "le montage de la répétition ne couvre pas la séance"

      travel_to(session_end + 1.minute) { MuxParticipantJob.perform_now(webinar.id, "speaker-9") }
      assert_equal 2, webinar.recordings.participants.where(participant_identity: "speaker-9").count
      assert_empty EpisodePublication.unmuxed_identities(webinar)
    end
  end
end
