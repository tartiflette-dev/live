require "test_helper"

# Nouvel essai du retrait du droit de publier après un retrait d'accord à
# l'image que la salle LiveKit n'a pas reçu : borné, jamais avalé.
class PublishingRevocationJobTest < ActiveJob::TestCase
  class FakeRoomClient
    attr_reader :calls
    attr_accessor :error

    def initialize
      @calls = []
    end

    def update_participant(room:, identity:, can_publish:, sources: [])
      @calls << [ room, identity, can_publish ]
      raise error if error

      {}
    end
  end

  setup do
    # ActiveJob::TestCase ne vide pas les mails livrés : un test précédent en
    # laissait un, et `deliveries.sole` échouait selon l'ordre des tests.
    ActionMailer::Base.deliveries.clear
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: "sub-marc", visibility: "published",
                               state: "live", started_at: 1.hour.ago)
    @speaker = @webinar.speakers.create!(name: "Camille Martin")
    ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true).withdraw!
    @room = FakeRoomClient.new
    @saved_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @room }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @saved_factory
  end

  test "retire le droit de publier de l'intervenant" do
    PublishingRevocationJob.perform_now(@webinar, @speaker)

    assert_equal [ [ @webinar.room_name, "speaker-#{@speaker.id}", false ] ], @room.calls
  end

  test "salle toujours injoignable : cinq essais, puis alerte à l'animateur propriétaire et l'erreur remonte" do
    User.create!(email: "marc@example.test", oidc_sub: "sub-marc")
    @room.error = RoomServiceClient::Error.new("livekit hors ligne (test)")
    log = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = Logger.new(log)

    perform_enqueued_jobs do
      assert_raises(RoomServiceClient::Error) { PublishingRevocationJob.perform_later(@webinar, @speaker) }
    end

    assert_equal 5, @room.calls.size
    alert = ActionMailer::Base.deliveries.sole
    assert_equal [ "marc@example.test" ], alert.to
    assert_equal "Café IA #9 — droit de publier non retiré, sans accord à l'image", alert.subject
    assert_includes alert.text_part.body.to_s, "Camille Martin (speaker-#{@speaker.id})"
    assert_match(/ERROR -- : \[publishing_revocation\] droit de publier toujours ouvert après 5 essais/, log.string)
  ensure
    Rails.logger = previous_logger
  end

  test "nouvel accord donné entre-temps : le droit de publier reste" do
    ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)

    PublishingRevocationJob.perform_now(@webinar, @speaker)

    assert_empty @room.calls
  end

  # Cas rejoué : l'accord seul ne suffit pas à un spectateur,
  # il lui faut aussi la parole. Revenu avec un ancien jeton qui publie, il
  # est fermé, que sa main soit absente ou seulement en attente (qui reste
  # levée).
  test "spectateur avec accord mais sans la parole : le droit de publier est retiré" do
    viewer = consenting_viewer
    PublishingRevocationJob.perform_now(@webinar, viewer)

    waiting = @webinar.hand_raises.create!(registration: viewer, state: "waiting", raised_at: Time.current)
    PublishingRevocationJob.perform_now(@webinar, viewer)

    assert_equal [ [ @webinar.room_name, "viewer-#{viewer.id}", false ] ] * 2, @room.calls
    assert_equal "waiting", waiting.reload.state
  end

  test "spectateur avec accord et la parole : le droit de publier reste" do
    viewer = consenting_viewer
    hand = @webinar.hand_raises.create!(registration: viewer, state: "granted", raised_at: Time.current, granted_at: Time.current)

    PublishingRevocationJob.perform_now(@webinar, viewer)

    assert_empty @room.calls
    assert_equal "granted", hand.reload.state
  end

  test "spectateur qui a la parole sans accord : sa main se referme, ce qui retire le droit" do
    viewer = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)
    hand = @webinar.hand_raises.create!(registration: viewer, state: "granted", raised_at: Time.current, granted_at: Time.current)

    PublishingRevocationJob.perform_now(@webinar, viewer)

    assert_equal [ [ @webinar.room_name, "viewer-#{viewer.id}", false ] ], @room.calls
    assert_equal "revoked", hand.reload.state
  end

  private

  def consenting_viewer
    viewer = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)
    ParticipantConsent.grant!(viewer, recording: true, excerpts: false, adult: true)
    viewer
  end
end
