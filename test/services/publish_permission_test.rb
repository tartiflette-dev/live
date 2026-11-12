require "test_helper"

# PublishPermission — la seule règle du droit de publier dans la salle :
# animation de droit exemptée ;
# co-animateur invité, intervenant et spectateur seulement sous accord à
# l'image en cours, le spectateur avec la parole ; sources limitées.
class PublishPermissionTest < ActiveSupport::TestCase
  class FakeRoomClient
    attr_reader :calls
    attr_accessor :error

    def initialize
      @calls = []
    end

    def update_participant(room:, identity:, can_publish:, sources: [])
      raise error if error

      @calls << [ identity, can_publish, sources ]
      {}
    end
  end

  setup do
    @owner = User.create!(email: "marc@example.test", oidc_sub: "sub-marc")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: @owner.oidc_sub, visibility: "published",
                               state: "live", started_at: 1.hour.ago)
    @cohost = User.create!(email: "camille@example.test", oidc_sub: "sub-camille", email_verified: true,
                           email_verified_for: "camille@example.test")
    @webinar.webinar_hosts.create!(email: @cohost.email, invited_by_sub: @owner.oidc_sub)
    @speaker = @webinar.speakers.create!(name: "Basile")
    @viewer = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)
    @room = FakeRoomClient.new
    @permission = PublishPermission.new(@webinar, client: @room)
  end

  test "qui doit donner son accord : intervenant, spectateur, co-animateur invité ; jamais le propriétaire" do
    assert PublishPermission.exempt?(@webinar, @owner)
    assert_not PublishPermission.consent_required?(@webinar, @owner)
    [ @speaker, @viewer, @cohost ].each do |record|
      assert PublishPermission.consent_required?(@webinar, record), record.class.name
      assert_not PublishPermission.exempt?(@webinar, record)
    end
    assert_not PublishPermission.consent_required?(@webinar, nil)
  end

  test "jeton : fermé sans accord, ouvert sous accord avec les seules sources permises ; le propriétaire, toutes" do
    assert_equal({ can_publish: true, sources: nil }, @permission.token_grant(@owner))
    [ @speaker, @cohost ].each do |record|
      assert_equal({ can_publish: false, sources: nil }, @permission.token_grant(record))
      ParticipantConsent.grant!(record, webinar: @webinar, recording: true, excerpts: false, adult: true)
      assert_equal({ can_publish: true, sources: PublishPermission::SOURCES }, @permission.token_grant(record))
    end
  end

  test "spectateur : l'accord sans la parole n'ouvre rien ; la parole sans l'accord non plus" do
    ParticipantConsent.grant!(@viewer, recording: true, excerpts: false, adult: true)
    assert_not @permission.open!(@viewer)

    ParticipantConsent.current_for(@viewer).withdraw!
    HandRaise.create!(webinar: @webinar, registration: @viewer, state: "granted", raised_at: Time.current, granted_at: Time.current)
    assert_not @permission.open!(@viewer)
    assert_empty @room.calls

    ParticipantConsent.grant!(@viewer, recording: true, excerpts: false, adult: true)
    assert @permission.open!(@viewer)
    assert_equal [ [ "viewer-#{@viewer.id}", true, PublishPermission::SOURCES ] ], @room.calls
  end

  test "absente de la salle (not_found) : rien à ouvrir ni fermer ; une panne remonte" do
    ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)
    @room.error = RoomServiceClient::RemoteError.new("inconnu", code: "not_found")
    assert_not @permission.open!(@speaker)
    assert_not @permission.close!(@speaker)

    @room.error = RoomServiceClient::Error.new("hors ligne")
    assert_raises(RoomServiceClient::Error) { @permission.close!(@speaker) }
  end

  test "identité de l'animation de droit, même sans compte pour le propriétaire" do
    assert @permission.exempt_identity?("host-sub-marc")
    assert_not @permission.exempt_identity?("host-sub-camille")
    assert_not @permission.exempt_identity?("speaker-#{@speaker.id}")
    assert PublishPermission.new(Webinar.new(host_sub: "sans-compte")).exempt_identity?("host-sans-compte")
  end
end
