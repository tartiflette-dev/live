require "test_helper"

module Api
  # Mesures de l'émetteur caméra : l'auteur est le participant que RECONNAÎT
  # le serveur, jamais une identité fournie par le client ; seulement qui a
  # le droit de publier, seulement pendant le direct ; volume borné par
  # personne et par requête.
  class CameraSamplesControllerTest < ActionDispatch::IntegrationTest
    include OidcSignIn

    SAMPLE = {
      "publication_sid" => "TR_cam14", "event" => "sample", "top_width" => 320, "top_height" => 180,
      "frames_per_second" => 20.0, "quality_limitation_reason" => "none",
      "encoder_implementation" => "SimulcastEncoderAdapter (ExternalEncoder)", "capture_width" => 1280,
      "capture_height" => 720, "paused_layers" => 0,
      "layers" => [ { "rid" => "q", "active" => true, "width" => 320, "height" => 180, "fps" => 20.0, "reason" => "none" },
                    { "rid" => "f", "active" => true, "width" => nil, "height" => nil, "fps" => nil, "reason" => "none" } ]
    }.freeze

    setup do
      @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
      @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.from_now, host_sub: @host.oidc_sub,
                                 visibility: "published", state: "live", started_at: Time.current)
      @speaker = @webinar.speakers.create!(name: "Thomas")
      ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)
    end

    def post_sample(sample = SAMPLE, speaker_token: nil, **extra)
      post "/api/camera_samples", params: { slug: @webinar.slug, speaker_token: speaker_token, sample: sample, **extra },
                                  as: :json
    end

    test "l'intervenant enregistre la mesure sous SON identité, couches comprises" do
      post_sample(speaker_token: @speaker.token)

      assert_response :no_content
      saved = CameraSample.sole
      assert_equal "speaker-#{@speaker.id}", saved.participant_identity
      assert_equal [ 320, 180, 1280, 720, "TR_cam14", "sample" ],
                   saved.slice(:top_width, :top_height, :capture_width, :capture_height, :publication_sid, :event).values
      assert_equal "SimulcastEncoderAdapter (ExternalEncoder)", saved.encoder_implementation
      assert_equal SAMPLE["layers"], saved.layers
    end

    test "l'animateur connecté mesure sous host-<sub>" do
      sign_in_as(@host)
      post_sample

      assert_response :no_content
      assert_equal "host-sub-marc", CameraSample.sole.participant_identity
    end

    test "une identité fournie par le client est ignorée" do
      post_sample(SAMPLE.merge("participant_identity" => "speaker-999"), speaker_token: @speaker.token,
                  participant_identity: "host-sub-marc")

      assert_response :no_content
      assert_equal "speaker-#{@speaker.id}", CameraSample.sole.participant_identity
    end

    test "le repli sans simulcast est journalisé comme événement" do
      post_sample(SAMPLE.merge("event" => "simulcast_fallback"), speaker_token: @speaker.token)

      assert_response :no_content
      assert_equal "simulcast_fallback", CameraSample.sole.event
    end

    test "deux mesures à moins de 5 s : la seconde est refusée (429), rien écrit" do
      post_sample(speaker_token: @speaker.token)
      post_sample(speaker_token: @speaker.token)

      assert_response :too_many_requests
      assert_equal 1, CameraSample.count

      travel CameraSample::MIN_INTERVAL + 1.second do
        post_sample(speaker_token: @speaker.token)
      end
      assert_response :no_content
      assert_equal 2, CameraSample.count
    end

    test "spectateur inscrit sans la parole : 403 ; parole accordée : mesuré sous viewer-<id>" do
      registration = @webinar.registrations.create!(email: "viewer@example.test", name: "Alice")
      post confirm_registration_path(registration.token)
      post_sample
      assert_response :forbidden
      assert_equal 0, CameraSample.count

      ParticipantConsent.grant!(registration, recording: true, excerpts: false, adult: true)
      HandRaise.create!(webinar: @webinar, registration: registration, state: "granted", raised_at: Time.current,
                        granted_at: Time.current)
      post_sample
      assert_response :no_content
      assert_equal "viewer-#{registration.id}", CameraSample.sole.participant_identity
    end

    test "intervenant sans accord à l'image (ne publie pas) : 403" do
      other = @webinar.speakers.create!(name: "Laurent")
      post_sample(speaker_token: other.token)

      assert_response :forbidden
      assert_equal 0, CameraSample.count
    end

    test "hors direct (avant, après) : 403, même pour l'animation" do
      sign_in_as(@host)
      @webinar.update!(state: "draft", started_at: nil)
      post_sample
      assert_response :forbidden

      @webinar.update!(state: "ended", started_at: 1.hour.ago, ended_at: Time.current)
      post_sample
      assert_response :forbidden
      assert_equal 0, CameraSample.count
    end

    test "corps au-delà de 8 Ko : 413, rien écrit" do
      post_sample(SAMPLE.merge("encoder_implementation" => "x" * 9.kilobytes), speaker_token: @speaker.token)

      assert_response :content_too_large
      assert_equal 0, CameraSample.count
    end

    # La borne protège l'écriture, pas l'analyse : Rails lit le corps avant
    # la chaîne des filtres (journal des paramètres). Le refus est un 413,
    # jamais le 400 d'un corps mal formé.
    test "corps mal formé au-delà de 8 Ko : 413, pas 400" do
      post "/api/camera_samples", params: "{" + ("x" * 9.kilobytes),
                                  headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      assert_response :content_too_large
    end

    test "couche hors contrat : 422, rien écrit" do
      [ { "rid" => "q" * 9 }, { "active" => "oui" }, { "width" => 320.5 }, { "height" => -1 }, { "fps" => 500 },
        { "reason" => "x" * 33 } ].each do |change|
        post_sample(SAMPLE.merge("layers" => [ SAMPLE["layers"].first.merge(change) ]), speaker_token: @speaker.token)
        assert_response :unprocessable_entity, change.inspect
      end
      assert_equal 0, CameraSample.count
    end

    test "anonyme ou intervenant révoqué : 403, rien écrit" do
      post_sample
      assert_response :forbidden

      @speaker.revoke!
      post_sample(speaker_token: @speaker.token)
      assert_response :forbidden
      assert_equal 0, CameraSample.count
    end

    test "slug inconnu = 404, non-JSON = 415" do
      post "/api/camera_samples", params: { slug: "inconnu", sample: SAMPLE }, as: :json
      assert_response :not_found

      post "/api/camera_samples", params: { slug: @webinar.slug, speaker_token: @speaker.token }
      assert_response :unsupported_media_type
    end

    test "structure inattendue : 400 ; valeur hors bornes : 422 ; rien écrit" do
      post_sample("caméra", speaker_token: @speaker.token)
      assert_response :bad_request

      post_sample(SAMPLE.merge("event" => "autre"), speaker_token: @speaker.token)
      assert_response :unprocessable_entity
      assert_equal 0, CameraSample.count
    end
  end
end
