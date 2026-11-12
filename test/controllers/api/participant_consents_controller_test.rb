require "test_helper"

module Api
  # Accord à l'image. Propriétés centrales : le
  # porteur est le participant que RECONNAÎT le serveur (RoomParticipant),
  # jamais un identifiant fourni par le client ; seul qui a la parole donne
  # son accord, qui ouvre sa publication LiveKit (sources limitées) ; le
  # retrait la referme et rend la personne spectatrice.
  class ParticipantConsentsControllerTest < ActionDispatch::IntegrationTest
    include OidcSignIn

    # Salle simulée : permissions demandées à LiveKit, panne à la demande.
    class FakeRoomClient
      attr_reader :permissions
      attr_accessor :error

      def initialize
        @permissions = []
      end

      def update_participant(room:, identity:, can_publish:, sources: [])
        raise error if error

        @permissions << [ room, identity, can_publish, sources ]
        {}
      end
    end

    CHECKED = { recording: true, excerpts: true, adult: true }.freeze

    setup do
      @host = User.create!(email: "marc@example.test", oidc_sub: "sub-marc")
      @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: @host.oidc_sub,
                                 visibility: "published", state: "live", started_at: Time.current)
      @speaker = @webinar.speakers.create!(name: "Camille Martin")
      @room = FakeRoomClient.new
      @saved_factory = Rails.configuration.x.room_service_client_factory
      Rails.configuration.x.room_service_client_factory = -> { @room }
    end

    teardown do
      Rails.configuration.x.room_service_client_factory = @saved_factory
      ActionController::Base.allow_forgery_protection = false
    end

    test "l'intervenant donne SON accord : preuve figée, publication ouverte par la salle, sources limitées" do
      give_consent(CHECKED, speaker_token: @speaker.token)

      assert_response :created
      assert_equal({ "given" => true, "labels" => ParticipantConsent::LABELS.stringify_keys, "contact" => "contact@example.test" }, response.parsed_body)
      consent = ParticipantConsent.current_for(@speaker)
      assert_equal [ true, true, true ], [ consent.recording_accepted, consent.excerpts_accepted, consent.adult_declared ]
      assert_equal PrivacyPolicy::VERSION, consent.policy_version
      assert_equal [ [ @webinar.room_name, "speaker-#{@speaker.id}", true, %w[camera microphone screen_share screen_share_audio] ] ],
                   @room.permissions
    end

    test "salle injoignable à l'ouverture : 502, l'accord est gardé, un nouvel envoi redemande l'ouverture" do
      @room.error = RoomServiceClient::Error.new("livekit hors ligne (test)")
      give_consent(CHECKED, speaker_token: @speaker.token)

      assert_response :bad_gateway
      assert_equal "permission_update_failed", response.parsed_body.fetch("error")
      assert ParticipantConsent.current_for(@speaker)

      @room.error = nil
      give_consent(CHECKED, speaker_token: @speaker.token)
      assert_response :created
      assert_equal 1, ParticipantConsent.count
      assert_equal [ true ], @room.permissions.map { |permission| permission[2] }
    end

    test "parole retirée entre la vérification et l'ouverture : accord enregistré, rien d'ouvert" do
      viewer = confirm_viewer
      hand = grant_floor(viewer)

      during_grant(-> { hand.update!(state: "revoked", revoked_at: Time.current) }) { give_consent(CHECKED) }

      assert_response :created
      assert ParticipantConsent.current_for(viewer)
      assert_empty @room.permissions
    end

    test "intervenant retiré de la salle entre la vérification et l'ouverture : rien d'ouvert" do
      during_grant(-> { @speaker.remove_from_room! }) { give_consent(CHECKED, speaker_token: @speaker.token) }

      assert_empty @room.permissions
    end

    test "intervenant pas encore dans la salle (not_found) : accord gardé, l'arrivée ouvrira la publication" do
      @room.error = RoomServiceClient::RemoteError.new("participant inconnu", code: "not_found")
      give_consent(CHECKED, speaker_token: @speaker.token)

      assert_response :created
      assert ParticipantConsent.current_for(@speaker)
    end

    test "co-animateur invité : la fenêtre comme un intervenant, accord porté par son compte pour ce webinaire" do
      guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: true,
                           email_verified_for: "jean@partenaire.example.org")
      @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @host.oidc_sub)
      sign_in_as(guest)

      give_consent(CHECKED)

      assert_response :created
      assert ParticipantConsent.current_for(guest, webinar: @webinar)
      assert_equal [ [ @webinar.room_name, "host-sub-jean", true, PublishPermission::SOURCES ] ], @room.permissions

      withdraw_consent
      assert_response :success
      assert_nil ParticipantConsent.current_for(guest, webinar: @webinar)
      assert_equal [ "host-sub-jean", false ], @room.permissions.last.values_at(1, 2)
    end

    test "un porteur ou des libellés désignés par le client sont ignorés" do
      other = @webinar.speakers.create!(name: "Basile")
      give_consent(CHECKED.merge(holder_type: "Speaker", holder_id: other.id, recording_label: "autre chose"),
                   speaker_token: @speaker.token)

      assert_response :created
      assert_nil ParticipantConsent.current_for(other)
      assert_equal ParticipantConsent::LABELS[:recording], ParticipantConsent.current_for(@speaker).recording_label
    end

    test "case des extraits non cochée : accord sans extraits" do
      give_consent(CHECKED.merge(excerpts: false), speaker_token: @speaker.token)

      assert_response :created
      assert_equal false, ParticipantConsent.current_for(@speaker).excerpts_accepted
    end

    test "sans la case d'enregistrement ou d'âge, rien n'est enregistré (422)" do
      [ CHECKED.merge(recording: false), CHECKED.merge(adult: false), CHECKED.except(:adult),
        CHECKED.merge(recording: "true") ].each do |boxes|
        give_consent(boxes, speaker_token: @speaker.token)

        assert_response :unprocessable_entity
        assert_equal "consent_incomplete", response.parsed_body.fetch("error")
      end
      assert_equal 0, ParticipantConsent.count
    end

    test "spectateur à qui la parole est donnée : accord porté par SON inscription, qui ouvre sa publication" do
      viewer = confirm_viewer
      grant_floor(viewer)

      give_consent(CHECKED)

      assert_response :created
      assert ParticipantConsent.current_for(viewer)
      assert_equal [ [ @webinar.room_name, "viewer-#{viewer.id}", true, PublishPermission::SOURCES ] ], @room.permissions
    end

    test "spectateur sans la parole, ou main encore en attente : refusé" do
      viewer = confirm_viewer
      give_consent(CHECKED)
      assert_response :forbidden

      HandRaise.create!(webinar: @webinar, registration: viewer, state: "waiting", raised_at: Time.current)
      give_consent(CHECKED)
      assert_response :forbidden
      assert_equal 0, ParticipantConsent.count
    end

    test "anonyme, jeton inconnu, intervenant révoqué ou d'un autre webinaire : refusé" do
      give_consent(CHECKED)
      assert_response :forbidden

      give_consent(CHECKED, speaker_token: "x" * 32)
      assert_response :forbidden

      other_webinar = Webinar.create!(title: "Autre", starts_at: 1.day.from_now, host_sub: @host.oidc_sub, visibility: "published")
      post "/api/participant_consent", params: CHECKED.merge(slug: other_webinar.slug, speaker_token: @speaker.token), as: :json
      assert_response :forbidden

      @speaker.revoke!
      give_consent(CHECKED, speaker_token: @speaker.token)
      assert_response :forbidden
      assert_equal 0, ParticipantConsent.count
    end

    test "l'animation n'a pas de fenêtre : refusé, même avec un jeton intervenant présenté" do
      sign_in_as(@host)
      give_consent(CHECKED, speaker_token: @speaker.token)

      assert_response :forbidden
      assert_equal 0, ParticipantConsent.count
    end

    test "webinaire inconnu : 404 ; requête non JSON : 415" do
      post "/api/participant_consent", params: CHECKED.merge(slug: "inconnu", speaker_token: @speaker.token), as: :json
      assert_response :not_found

      post "/api/participant_consent", params: CHECKED.merge(slug: @webinar.slug, speaker_token: @speaker.token)
      assert_response :unsupported_media_type
    end

    test "CSRF actif : sans jeton, refus JSON 422 et rien n'est enregistré" do
      ActionController::Base.allow_forgery_protection = true

      give_consent(CHECKED, speaker_token: @speaker.token)

      assert_response :unprocessable_entity
      assert_equal "invalid_authenticity_token", response.parsed_body.fetch("error")
      assert_equal 0, ParticipantConsent.count
    end

    test "retrait de l'intervenant : horodaté, droit de publier retiré par LiveKit" do
      consent = ParticipantConsent.grant!(@speaker, recording: true, excerpts: true, adult: true)

      withdraw_consent(speaker_token: @speaker.token)

      assert_response :success
      assert_equal false, response.parsed_body.fetch("given")
      assert consent.reload.withdrawn?
      assert_equal [ [ @webinar.room_name, "speaker-#{@speaker.id}", false, [] ] ], @room.permissions
    end

    test "retrait du spectateur : sa main se referme, ce qui lui retire la parole" do
      viewer = confirm_viewer
      hand = grant_floor(viewer)
      consent = ParticipantConsent.grant!(viewer, recording: true, excerpts: false, adult: true)

      withdraw_consent

      assert_response :success
      assert consent.reload.withdrawn?
      assert_equal "revoked", hand.reload.state
      assert_equal [ [ @webinar.room_name, "viewer-#{viewer.id}", false, [] ] ], @room.permissions
    end

    test "retrait possible après avoir rendu la parole : la publication est refermée quand même" do
      viewer = confirm_viewer
      consent = ParticipantConsent.grant!(viewer, recording: true, excerpts: false, adult: true)

      withdraw_consent

      assert_response :success
      assert consent.reload.withdrawn?
      assert_equal [ [ @webinar.room_name, "viewer-#{viewer.id}", false, [] ] ], @room.permissions
    end

    test "salle injoignable : le retrait vaut quand même, le retrait du droit de publier est réessayé" do
      consent = ParticipantConsent.grant!(@speaker, recording: true, excerpts: true, adult: true)
      @room.error = RoomServiceClient::Error.new("livekit hors ligne (test)")

      assert_enqueued_with(job: PublishingRevocationJob, args: [ @webinar, @speaker ]) do
        withdraw_consent(speaker_token: @speaker.token)
      end

      assert_response :success
      assert consent.reload.withdrawn?
      assert_not ParticipantConsent.covers?(@webinar, "speaker-#{@speaker.id}")
    end

    test "retrait sans accord en cours : rien à faire, rien demandé à LiveKit" do
      withdraw_consent(speaker_token: @speaker.token)

      assert_response :success
      assert_equal false, response.parsed_body.fetch("given")
      assert_empty @room.permissions
    end

    test "retrait refusé à l'anonyme et à l'animation" do
      ParticipantConsent.grant!(@speaker, recording: true, excerpts: true, adult: true)
      withdraw_consent
      assert_response :forbidden

      sign_in_as(@host)
      withdraw_consent(speaker_token: @speaker.token)
      assert_response :forbidden
      assert ParticipantConsent.current_for(@speaker)
    end

    private

    def give_consent(boxes, speaker_token: nil)
      post "/api/participant_consent", params: boxes.merge(slug: @webinar.slug, speaker_token: speaker_token), as: :json
    end

    def withdraw_consent(speaker_token: nil)
      delete "/api/participant_consent", params: { slug: @webinar.slug, speaker_token: speaker_token }, as: :json
    end

    def confirm_viewer
      registration = @webinar.registrations.create!(name: "Inès", email: "ines@example.test")
      post confirm_registration_path(registration.token)
      assert_response :redirect
      registration
    end

    # Un geste de l'animation survient pendant l'enregistrement de l'accord,
    # après la vérification de la parole et avant l'ouverture.
    def during_grant(action)
      original = ParticipantConsent.method(:grant!)
      ParticipantConsent.define_singleton_method(:grant!) do |*args, **options|
        action.call
        original.call(*args, **options)
      end
      yield
    ensure
      ParticipantConsent.define_singleton_method(:grant!, original)
    end

    def grant_floor(registration)
      HandRaise.create!(webinar: @webinar, registration: registration, state: "granted",
                        raised_at: Time.current, granted_at: Time.current)
    end
  end
end
