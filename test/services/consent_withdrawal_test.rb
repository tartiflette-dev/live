require "test_helper"

# Retrait de l'accord à l'image : l'enregistrement des pistes séparées de la
# personne s'arrête sans dépendre de LiveKit ; le droit de publier est retiré,
# ou réessayé en tâche de fond si la salle ne répond pas.
class ConsentWithdrawalTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  class FakeRoomClient
    attr_reader :permissions
    attr_accessor :error

    def initialize
      @permissions = []
    end

    def update_participant(room:, identity:, can_publish:, sources: [])
      raise error if error

      @permissions << [ room, identity, can_publish ]
      {}
    end
  end

  class FakeEgressClient
    attr_reader :stopped

    def initialize
      @stopped = []
    end

    def stop(egress_id:)
      @stopped << egress_id
      { egress_id: egress_id, status: :ending, files: [] }
    end
  end

  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: "sub-marc", visibility: "published",
                               state: "live", started_at: 1.hour.ago)
    @speaker = @webinar.speakers.create!(name: "Camille Martin")
    @consent = ParticipantConsent.grant!(@speaker, recording: true, excerpts: true, adult: true)
    @room = FakeRoomClient.new
    @egress = FakeEgressClient.new
  end

  test "retrait nominal : pistes de la personne arrêtées, droit de publier retiré, aucun nouvel essai" do
    camera = track("speaker-#{@speaker.id}", "EG_cam")
    micro = track("speaker-#{@speaker.id}", "EG_mic", source: "microphone")
    other = track("host-sub-marc", "EG_host")

    assert_no_enqueued_jobs(only: PublishingRevocationJob) do
      assert_enqueued_email_with(ConsentMailer, :withdrawn, args: [ @consent ]) do
        assert_equal @consent, withdrawal.call
      end
    end

    assert @consent.reload.withdrawn?
    assert_equal %w[EG_cam EG_mic], @egress.stopped.sort
    assert_equal [ "stopping", "stopping", "recording" ], [ camera, micro, other ].map { |rec| rec.reload.status }
    assert_equal [ [ @webinar.room_name, "speaker-#{@speaker.id}", false ] ], @room.permissions
  end

  test "salle injoignable : enregistrement arrêté quand même, nouvel essai du retrait en file" do
    camera = track("speaker-#{@speaker.id}", "EG_cam")
    @room.error = RoomServiceClient::Error.new("livekit hors ligne (test)")

    assert_enqueued_with(job: PublishingRevocationJob, args: [ @webinar, @speaker ]) do
      assert_equal @consent, withdrawal.call
    end

    assert @consent.reload.withdrawn?
    assert_equal [ "EG_cam" ], @egress.stopped
    assert_equal "stopping", camera.reload.status
  end

  test "personne absente de la salle (not_found) : rien à retirer, aucun nouvel essai" do
    @room.error = RoomServiceClient::RemoteError.new("participant inconnu", code: "not_found")

    assert_no_enqueued_jobs(only: PublishingRevocationJob) { withdrawal.call }

    assert @consent.reload.withdrawn?
  end

  test "spectateur en prise de parole : sa main se referme" do
    viewer = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)
    hand = HandRaise.create!(webinar: @webinar, registration: viewer, state: "granted", raised_at: Time.current, granted_at: Time.current)
    consent = ParticipantConsent.grant!(viewer, recording: true, excerpts: false, adult: true)
    camera = track("viewer-#{viewer.id}", "EG_viewer")

    ConsentWithdrawal.new(@webinar, viewer, client: @room, egress_client: @egress).call

    assert consent.reload.withdrawn?
    assert_equal "revoked", hand.reload.state
    assert_equal [ [ @webinar.room_name, "viewer-#{viewer.id}", false ] ], @room.permissions
    assert_equal "stopping", camera.reload.status
  end

  test "co-animateur invité : son accord, porté par son compte pour CE webinaire, est retiré et sa publication fermée" do
    cohost = User.create!(email: "camille@example.test", oidc_sub: "sub-camille", email_verified: true,
                          email_verified_for: "camille@example.test")
    @webinar.webinar_hosts.create!(email: cohost.email, invited_by_sub: "sub-marc")
    consent = ParticipantConsent.grant!(cohost, webinar: @webinar, recording: true, excerpts: false, adult: true)
    camera = track("host-sub-camille", "EG_cohost")

    assert_equal consent, ConsentWithdrawal.new(@webinar, cohost, client: @room, egress_client: @egress).call

    assert consent.reload.withdrawn?
    assert_equal [ [ @webinar.room_name, "host-sub-camille", false ] ], @room.permissions
    assert_equal "stopping", camera.reload.status
  end

  test "sans accord en cours : rien n'est arrêté ni demandé à LiveKit, aucun mail" do
    @consent.withdraw!
    track("speaker-#{@speaker.id}", "EG_cam")

    assert_no_enqueued_emails { assert_nil withdrawal.call }
    assert_empty @egress.stopped
    assert_empty @room.permissions
  end

  private

  def withdrawal
    ConsentWithdrawal.new(@webinar, @speaker, client: @room, egress_client: @egress)
  end

  def track(identity, egress_id, source: "camera")
    @webinar.recordings.create!(kind: "track", status: "recording", egress_id: egress_id, track_sid: "TR_#{egress_id}",
                                participant_identity: identity, track_source: source, started_at: 1.minute.ago)
  end
end
