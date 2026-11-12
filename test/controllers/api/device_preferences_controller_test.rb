require "test_helper"

module Api
  # Écriture des préférences de
  # périphériques. Propriété centrale : le propriétaire est le participant
  # que RECONNAÎT le serveur (session animateur, sinon jeton intervenant),
  # jamais un identifiant fourni par le client.
  class DevicePreferencesControllerTest < ActionDispatch::IntegrationTest
    include OidcSignIn

    YETI = { "deviceId" => "a1b2", "label" => "Microphone (Yeti Stereo Microphone)" }.freeze
    WEBCAM = { "deviceId" => "c3d4", "label" => "HD Webcam C270" }.freeze
    PREFERENCES = { "audioinput" => YETI, "videoinput" => WEBCAM, "audioEnabled" => true, "videoEnabled" => false }.freeze

    setup do
      @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
      @webinar = Webinar.create!(title: "Café IA #8", starts_at: 1.day.from_now, host_sub: @host.oidc_sub,
                                 visibility: "published")
      @speaker = @webinar.speakers.create!(name: "Camille Martin")
    end

    test "l'animateur enregistre SES préférences, rattachées à son compte" do
      sign_in_as(@host)
      patch_preferences(PREFERENCES)

      assert_response :success
      assert_equal PREFERENCES, JSON.parse(response.body)
      assert_equal PREFERENCES, DevicePreference.payload_for(@host.reload)
    end

    test "l'intervenant enregistre les préférences de SON Speaker" do
      patch_preferences(PREFERENCES, speaker_token: @speaker.token)

      assert_response :success
      assert_equal PREFERENCES, DevicePreference.payload_for(@speaker.reload)
      assert_nil @host.reload.device_preference
    end

    test "une écriture partielle ne change que ses clés, sur la même ligne" do
      patch_preferences(PREFERENCES, speaker_token: @speaker.token)
      patch_preferences({ "videoEnabled" => true }, speaker_token: @speaker.token)

      assert_response :success
      assert_equal PREFERENCES.merge("videoEnabled" => true), JSON.parse(response.body)
      assert_equal PREFERENCES.merge("videoEnabled" => true), DevicePreference.payload_for(@speaker.reload)
      assert_equal 1, DevicePreference.count
    end

    test "un propriétaire désigné par le client est ignoré" do
      other = @webinar.speakers.create!(name: "Basile")
      patch "/api/device_preferences",
          params: { slug: @webinar.slug, speaker_token: @speaker.token, owner_type: "Speaker", owner_id: other.id,
                    device_preferences: PREFERENCES.merge("owner_id" => other.id) },
          as: :json

      assert_response :success
      assert_nil other.reload.device_preference
      assert_equal PREFERENCES, DevicePreference.payload_for(@speaker.reload)
    end

    test "l'animateur connecté l'emporte sur un jeton intervenant présenté" do
      sign_in_as(@host)
      patch_preferences(PREFERENCES, speaker_token: @speaker.token)

      assert_response :success
      assert @host.reload.device_preference
      assert_nil @speaker.reload.device_preference
    end

    test "le jeton d'un intervenant ne vaut que pour son webinaire" do
      other_webinar = Webinar.create!(title: "Autre", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
      patch "/api/device_preferences",
          params: { slug: other_webinar.slug, speaker_token: @speaker.token, device_preferences: PREFERENCES },
          as: :json

      assert_response :forbidden
      assert_equal 0, DevicePreference.count
    end

    test "un intervenant révoqué n'écrit plus rien" do
      @speaker.revoke!
      patch_preferences(PREFERENCES, speaker_token: @speaker.token)

      assert_response :forbidden
      assert_equal 0, DevicePreference.count
    end

    test "un spectateur inscrit n'a pas de mémoire serveur" do
      registration = @webinar.registrations.create!(email: "viewer@example.test", name: "Alice")
      post confirm_registration_path(registration.token)
      patch_preferences(PREFERENCES)

      assert_response :forbidden
      assert_equal 0, DevicePreference.count
    end

    test "un visiteur anonyme est refusé" do
      patch_preferences(PREFERENCES)

      assert_response :forbidden
    end

    test "slug inconnu = 404" do
      patch "/api/device_preferences", params: { slug: "inconnu", device_preferences: PREFERENCES }, as: :json

      assert_response :not_found
    end

    test "refus non-JSON (415)" do
      patch "/api/device_preferences", params: { slug: @webinar.slug, speaker_token: @speaker.token }

      assert_response :unsupported_media_type
    end

    test "une structure inattendue donne 400, jamais 500" do
      patch "/api/device_preferences",
          params: { slug: @webinar.slug, speaker_token: @speaker.token, device_preferences: "micro" },
          as: :json

      assert_response :bad_request
      assert_equal 0, DevicePreference.count
    end

    test "un libellé trop long est refusé (422)" do
      patch_preferences({ "audioinput" => { "deviceId" => "a1b2", "label" => "x" * 300 } }, speaker_token: @speaker.token)

      assert_response :unprocessable_entity
      assert_equal 0, DevicePreference.count
    end

    test "CSRF : sans le jeton de la page, rien n'est écrit" do
      with_forgery_protection do
        patch_preferences(PREFERENCES, speaker_token: @speaker.token)

        assert_response :unprocessable_entity
        assert_equal 0, DevicePreference.count
      end
    end

    test "CSRF : avec le jeton de la page salle, l'écriture passe" do
      with_forgery_protection do
        get join_webinar_path(slug: @webinar.slug, t: @speaker.token)
        csrf = response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        assert csrf, "jeton CSRF absent de la page salle"

        patch_preferences(PREFERENCES, speaker_token: @speaker.token, headers: { "X-CSRF-Token" => csrf })

        assert_response :success
        assert_equal PREFERENCES, DevicePreference.payload_for(@speaker.reload)
      end
    end

    private

    def patch_preferences(preferences, speaker_token: nil, headers: {})
      patch "/api/device_preferences",
          params: { slug: @webinar.slug, speaker_token: speaker_token, device_preferences: preferences },
          headers: headers,
          as: :json
    end

    def with_forgery_protection
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end
  end
end
