require "test_helper"

module Api
  class TokensControllerTest < ActionDispatch::IntegrationTest
    # Endpoint UNIQUE d'émission côté salle.
    # Toute la décision de rôle vit ici (test critique
    # `token_endpoint_role_enforcement` : un `role` client est IGNORÉ).

    FAKE_KEY    = "APIfake"
    FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

    setup do
      @host   = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
      @other  = User.create!(email: "eve@example.com", oidc_sub: "sub-eve")
      @webinar = Webinar.create!(
        title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub, visibility: "published"
      )

      @prev_key    = ENV["LIVEKIT_API_KEY"]
      @prev_secret = ENV["LIVEKIT_API_SECRET"]
      @prev_url    = ENV["LIVEKIT_URL"]
      ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
      ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    end

    teardown do
      ENV["LIVEKIT_API_KEY"]    = @prev_key
      ENV["LIVEKIT_API_SECRET"] = @prev_secret
      ENV["LIVEKIT_URL"]        = @prev_url
      OmniAuth.config.mock_auth[:pocket_id] = nil
      OmniAuth.config.test_mode = false
    end

    test "new staging webinar token targets its prefixed room" do
      previous = ENV["LIVEKIT_ROOM_PREFIX"]
      ENV["LIVEKIT_ROOM_PREFIX"] = "staging-"
      webinar = Webinar.create!(title: "Isolated room", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
      assert_equal "staging-isolated-room", webinar.room_name
      sign_in_as(@host)
      post_token(slug: webinar.slug)
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "staging-isolated-room", body.fetch("room")
      claims, = JWT.decode(body.fetch("token"), FAKE_SECRET, true, algorithm: "HS256")
      assert_equal "staging-isolated-room", claims.fetch("video").fetch("room")
    ensure
      ENV["LIVEKIT_ROOM_PREFIX"] = previous
    end

    # ---- Contrat de sortie ----

    test "viewer confirmé sur un slug public" do
      confirm_viewer
      post_token(slug: @webinar.slug)
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "viewer",             body.fetch("role")
      assert_equal @webinar.room_name,   body.fetch("room")
      assert body.fetch("token").present?
      assert body.fetch("identity").start_with?("viewer-")
      # serverUrl vient de LIVEKIT_URL, sinon du LiveKit local de dev.
      assert_match(%r{\Awss?://}, body.fetch("serverUrl"))
    end

    # La page publique appelle cet endpoint au montage : un navigateur
    # ancien (hors :modern) doit obtenir son token viewer, pas un 406 —
    # sinon la salle reste vide sans message (cf. AnimateurBrowserPolicy).
    test "token viewer servi à un navigateur ancien (pas de 406)" do
      confirm_viewer
      old_ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " \
               "(KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36"
      post "/api/token", params: { slug: @webinar.slug }, as: :json, headers: { "User-Agent" => old_ua }
      assert_response :success
      assert_equal "viewer", JSON.parse(response.body).fetch("role")
    end

    test "host quand l'animateur est propriétaire" do
      sign_in_as(@host)
      post_token(slug: @webinar.slug)
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "host",             body.fetch("role")
      assert_equal "host-sub-marc",     body.fetch("identity")
    end

    test "speaker quand speaker_token valide (Speaker nominatif actif)" do
      speaker = @webinar.speakers.create!(name: "Basile")
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "speaker",              body.fetch("role")
      assert_equal "speaker-#{speaker.id}", body.fetch("identity")
    end

    # ---- Préférences de périphériques ----

    test "le token livre les préférences de l'animateur, vides s'il n'a rien choisi" do
      sign_in_as(@host)
      post_token(slug: @webinar.slug)
      empty = { "audioinput" => nil, "videoinput" => nil, "audioEnabled" => nil, "videoEnabled" => nil }
      assert_equal empty, JSON.parse(response.body).fetch("devicePreferences")

      @host.create_device_preference!(audio_input_device_id: "a1b2", audio_input_label: "Yeti", video_enabled: false)
      post_token(slug: @webinar.slug)
      preferences = JSON.parse(response.body).fetch("devicePreferences")
      assert_equal({ "deviceId" => "a1b2", "label" => "Yeti" }, preferences.fetch("audioinput"))
      assert_equal false, preferences.fetch("videoEnabled")
    end

    test "le token livre les préférences de l'intervenant, pas celles d'un autre" do
      speaker = @webinar.speakers.create!(name: "Camille Martin")
      other = @webinar.speakers.create!(name: "Basile")
      speaker.create_device_preference!(audio_input_device_id: "a1b2", audio_input_label: "Yeti")
      other.create_device_preference!(audio_input_device_id: "z9", audio_input_label: "Rode")

      post_token(slug: @webinar.slug, speaker_token: speaker.token)

      assert_equal "Yeti", JSON.parse(response.body).fetch("devicePreferences").fetch("audioinput").fetch("label")
    end

    test "le spectateur n'a pas de préférences serveur" do
      confirm_viewer
      post_token(slug: @webinar.slug)
      assert_response :success
      assert_nil JSON.parse(response.body).fetch("devicePreferences")
    end

    # ---- Accord à l'image ----

    test "le token dit à l'intervenant s'il a déjà donné son accord, avec les libellés à afficher" do
      speaker = @webinar.speakers.create!(name: "Camille Martin")
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_equal({ "given" => false, "labels" => ParticipantConsent::LABELS.stringify_keys, "contact" => "contact@example.test" },
                   JSON.parse(response.body).fetch("participantConsent"))

      ParticipantConsent.grant!(speaker, recording: true, excerpts: false, adult: true)
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_equal true, JSON.parse(response.body).fetch("participantConsent").fetch("given")
    end

    test "le spectateur a une fenêtre de consentement, l'animation non" do
      viewer = confirm_viewer
      ParticipantConsent.grant!(viewer, recording: true, excerpts: true, adult: true)
      post_token(slug: @webinar.slug)
      assert_equal true, JSON.parse(response.body).fetch("participantConsent").fetch("given")

      sign_in_as(@host)
      post_token(slug: @webinar.slug)
      assert_nil JSON.parse(response.body).fetch("participantConsent")
    end

    test "intervenant sans accord : le jeton ne publie pas ; avec un accord en cours, sources limitées" do
      speaker = @webinar.speakers.create!(name: "Camille Martin")
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_equal false, video_grant.fetch("canPublish")
      assert_operator token_lifetime, :>=, LivekitTokenService::DEFAULT_TTL - 10

      ParticipantConsent.grant!(speaker, recording: true, excerpts: false, adult: true)
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_equal true, video_grant.fetch("canPublish")
      assert_equal PublishPermission::SOURCES, video_grant.fetch("canPublishSources")
      assert_operator token_lifetime, :<=, LivekitTokenService::COHOST_TTL, "un jeton qui publie sous accord a le TTL court"
    end

    test "spectateur : le jeton ne publie qu'avec la parole accordée ET un accord en cours" do
      viewer = confirm_viewer
      ParticipantConsent.grant!(viewer, recording: true, excerpts: false, adult: true)
      post_token(slug: @webinar.slug)
      assert_equal false, video_grant.fetch("canPublish"), "accord sans parole"

      HandRaise.create!(webinar: @webinar, registration: viewer, state: "granted", raised_at: Time.current, granted_at: Time.current)
      post_token(slug: @webinar.slug)
      assert_equal true, video_grant.fetch("canPublish")
      assert_equal PublishPermission::SOURCES, video_grant.fetch("canPublishSources")
    end

    test "propriétaire : publie de droit, toutes sources, sans fenêtre" do
      sign_in_as(@host)
      post_token(slug: @webinar.slug)
      assert_equal true, video_grant.fetch("canPublish")
      assert_nil video_grant["canPublishSources"]
    end

    # ---- INVARIANT : rôle décidé SERVEUR, jamais client ----

    # critère principal : "L'endpoint token refuse un rôle host à un
    # non-animateur" — un spectateur qui POST `role: host` reçoit un token
    # viewer (jamais host).
    test "token_endpoint_role_enforcement" do
      confirm_viewer
      post_token(slug: @webinar.slug, role: "host", host_sub: @host.oidc_sub)
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "viewer", body.fetch("role"),
        "un client qui envoie role=host doit être ramené à viewer côté serveur"
    end

    test "un animateur AUTRE que le propriétaire n'obtient PAS host" do
      confirm_viewer
      sign_in_as(@other)
      post_token(slug: @webinar.slug, role: "host")
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "viewer", body.fetch("role")
    end

    test "project_host (admin) sur un webinaire d'autrui obtient host avec identity host-<son sub> ET grants roomAdmin" do
      # Identité LiveKit distincte du propriétaire,
      # pour que les pistes et le transcript soient attribués au bon
      # animateur côté enregistrement. Durcissement sécurité :
      # project_host CONSERVE roomAdmin (pilote la salle).
      autre_owner = User.create!(email: "owner-autre@example.net", oidc_sub: "sub-owner-autre")
      autre_w = Webinar.create!(title: "autre", starts_at: 1.day.from_now, host_sub: autre_owner.oidc_sub)
      sign_in_as(@host) # @host est admin donc project_host
      post_token(slug: autre_w.slug)
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "host", body.fetch("role")
      assert_equal "host-#{@host.oidc_sub}", body.fetch("identity")

      # JWT contient `roomAdmin: true` pour un project_host.
      claims, = JWT.decode(body.fetch("token"), FAKE_SECRET, true, algorithm: "HS256")
      assert_equal true, claims.fetch("video").fetch("roomAdmin")
      assert_equal true, claims.fetch("video").fetch("canPublish")
    end

    test "owner_token_jwt_porte_roomAdmin_true" do
      sign_in_as(@host)
      post_token(slug: @webinar.slug)
      body = JSON.parse(response.body)
      claims, = JWT.decode(body.fetch("token"), FAKE_SECRET, true, algorithm: "HS256")
      assert_equal true, claims.fetch("video").fetch("roomAdmin")
    end

    test "guest_host obtient role cohost SANS roomAdmin avec identity host-<son sub>" do
      # Défense privilege-escalation : un co-animateur
      # invité NE DOIT PAS tenir roomAdmin — il peut publier, mais ne
      # peut ni couper ni expulser le propriétaire/project_host.
      guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: true, email_verified_for: "jean@partenaire.example.org")
      @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @host.oidc_sub)
      sign_in_as(guest)
      post_token(slug: @webinar.slug)
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "cohost", body.fetch("role")
      # Identité toujours `host-<son sub>` (TrackRecordingSession voit
      # host-<sub> indifféremment, c'est le JWT qui diffère).
      assert_equal "host-#{guest.oidc_sub}", body.fetch("identity")

      claims, = JWT.decode(body.fetch("token"), FAKE_SECRET, true, algorithm: "HS256")
      video = claims.fetch("video")
      assert_equal true,  video.fetch("canSubscribe")
      assert_equal false, video.fetch("roomAdmin")

      # Co-animateur invité : la fenêtre de consentement et la garde serveur
      # comme un intervenant.
      assert_equal false, video.fetch("canPublish"), "sans accord à l'image, le co-animateur ne publie pas"
      assert_equal false, body.fetch("participantConsent").fetch("given")
      ParticipantConsent.grant!(guest, webinar: @webinar, recording: true, excerpts: false, adult: true)
      post_token(slug: @webinar.slug)
      assert_equal true, video_grant.fetch("canPublish")
      assert_equal PublishPermission::SOURCES, video_grant.fetch("canPublishSources")
    end

    # RGPD : le `name` du jeton est diffusé à
    # tous les abonnés de la salle dès l'arrivée. Aucun rôle n'y met une
    # adresse email.
    test "aucun nom de participant LiveKit ne contient d'arobase, quel que soit le rôle" do
      guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
      @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @host.oidc_sub)
      project_host = User.create!(email: "projet@partenaire.example.org", oidc_sub: "sub-projet")
      speaker = @webinar.speakers.create!(name: "Basile")
      ENV["LIVE_PROJECT_HOSTS"] = project_host.email

      names = {}  # rôle => claims du jeton
      sign_in_as(@host)
      names[:owner] = fresh_claims(slug: @webinar.slug)
      sign_in_as(guest)
      names[:cohost] = fresh_claims(slug: @webinar.slug)
      sign_in_as(project_host)
      names[:project_host] = fresh_claims(slug: @webinar.slug)
      delete sign_out_path
      names[:speaker] = fresh_claims(slug: @webinar.slug, speaker_token: speaker.token)
      confirm_viewer
      names[:viewer] = fresh_claims(slug: @webinar.slug)

      assert_equal %w[host- host- host- speaker- viewer-],
        names.values.map { |claims| claims.fetch("sub")[/\A[a-z]+-/] }
      names.each { |role, claims| assert_not_includes claims["name"].to_s, "@", "le nom du jeton #{role} contient une arobase : #{claims['name'].inspect}" }
      assert_equal "marc", names[:owner]["name"]
      assert_equal "jean", names[:cohost]["name"]
    ensure
      ENV.delete("LIVE_PROJECT_HOSTS")
    end

    test "guest_host_sans_email_verified_ne_recoit_pas_cohost" do
      guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: false)
      @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @host.oidc_sub)
      sign_in_as(guest, email_verified: false)
      post_token(slug: @webinar.slug)
      # Pas d'inscription côté viewer non plus → 403.
      assert_response :forbidden
    end

    test "spectateur_inscrit_ne_s_eleve_pas_host" do
      # Élévation : un spectateur confirmé ne devient JAMAIS animateur,
      # même en forgeant role=host dans la requête.
      confirm_viewer
      post_token(slug: @webinar.slug, role: "host")
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "viewer", body.fetch("role")
      assert body.fetch("identity").start_with?("viewer-")
    end

    test "intervenant_signe_ne_s_eleve_pas_host" do
      # Un intervenant avec un speaker_token valide reçoit :speaker, pas
      # :host — même en forgeant role=host.
      speaker = @webinar.speakers.create!(name: "Basile")
      post_token(slug: @webinar.slug, speaker_token: speaker.token, role: "host")
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "speaker", body.fetch("role")
    end

    test "un speaker_token altéré retombe en viewer" do
      confirm_viewer
      speaker = @webinar.speakers.create!(name: "Basile")
      valid = speaker.token
      tampered = valid[0..-2] + (valid[-1] == "a" ? "b" : "a")
      post_token(slug: @webinar.slug, speaker_token: tampered)
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "viewer", body.fetch("role")
    end

    # ---- Erreurs ----

    test "slug inconnu = 404" do
      post_token(slug: "nope")
      assert_response :not_found
    end

    test "refus non-JSON (415)" do
      post "/api/token", params: { slug: @webinar.slug }
      assert_response :unsupported_media_type
    end

    # ---- ENV LIVEKIT_URL ----

    test "serverUrl vient de LIVEKIT_URL si présent" do
      confirm_viewer
      ENV["LIVEKIT_URL"] = "wss://media.example.test"
      post_token(slug: @webinar.slug)
      body = JSON.parse(response.body)
      assert_equal "wss://media.example.test", body.fetch("serverUrl")
    end

    test "sans LIVEKIT_URL, serverUrl vise le LiveKit local de développement" do
      confirm_viewer
      ENV["LIVEKIT_URL"] = nil
      post_token(slug: @webinar.slug)
      body = JSON.parse(response.body)
      assert_equal "ws://localhost:7880", body.fetch("serverUrl")
    end

    test "viewer requires confirmed registration for this webinar" do
      post_token(slug: @webinar.slug, role: "host", identity: "host-sub-marc")
      assert_response :forbidden
      assert_equal({ "error" => "registration_required" }, response.parsed_body)

      registration = confirm_viewer
      post_token(slug: @webinar.slug, name: "Forged", identity: "forged")
      assert_response :success
      body = response.parsed_body
      assert_equal "viewer-#{registration.id}", body.fetch("identity")
      claims = JWT.decode(body.fetch("token"), FAKE_SECRET, true, algorithm: "HS256").first
      assert_equal registration.name, claims.fetch("name")
      assert_equal false, claims.fetch("video").fetch("canPublish")
      assert_equal false, claims.fetch("video").fetch("roomAdmin")
      post_token(slug: @webinar.slug)
      assert_equal "viewer-#{registration.id}", response.parsed_body.fetch("identity")

      other_webinar = Webinar.create!(title: "Autre", starts_at: 1.day.from_now,
        host_sub: @host.oidc_sub, visibility: "published")
      post_token(slug: other_webinar.slug)
      assert_response :forbidden
      registration.update!(confirmed_at: nil)
      post_token(slug: @webinar.slug)
      assert_response :forbidden
    end

    test "draft webinar never emits a viewer token even with a valid cookie" do
      confirm_viewer
      @webinar.update!(visibility: "draft")
      post_token(slug: @webinar.slug)
      assert_response :forbidden
      assert_equal "registration_required", response.parsed_body.fetch("error")
    end

    test "host beats speaker and viewer and both privileged roles work without registration" do
      @webinar.update!(visibility: "draft")
      speaker = @webinar.speakers.create!(name: "Basile")
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_response :success
      assert_equal "speaker", response.parsed_body.fetch("role")
      sign_in_as(@host)
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_response :success
      assert_equal "host", response.parsed_body.fetch("role")
    end

    test "forged registration cookie does not authorize a viewer" do
      cookies[:registration_id] = "1"
      post_token(slug: @webinar.slug)
      assert_response :forbidden
    end

    test "named_speaker_token uses stored identity and name and wins over viewer" do
      speaker = @webinar.speakers.create!(name: "Basile")
      confirm_viewer
      post_token(slug: @webinar.slug, speaker_token: speaker.token, identity: "host-forged", name: "Forged")
      assert_response :success
      body = response.parsed_body
      assert_equal "speaker", body.fetch("role")
      assert_equal "speaker-#{speaker.id}", body.fetch("identity")
      claims = JWT.decode(body.fetch("token"), FAKE_SECRET, true, algorithm: "HS256").first
      assert_equal "Basile", claims.fetch("name")
      assert_equal "speaker-#{speaker.id}", claims.fetch("sub")
      assert_equal false, claims.fetch("video").fetch("canPublish"), "pas d'accord à l'image : rien à publier"
      assert_equal false, claims.fetch("video").fetch("roomAdmin")
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_equal body.fetch("identity"), response.parsed_body.fetch("identity")
      other = @webinar.speakers.create!(name: "Marc")
      post_token(slug: @webinar.slug, speaker_token: other.token)
      assert_equal "speaker-#{other.id}", response.parsed_body.fetch("identity")
    end

    # Retirer ≠ révoquer : un intervenant seulement RÉVOQUÉ par le
    # propriétaire garde son inscription de spectateur, comme avant.
    test "après régénération l'ancien jeton ne redonne pas l'ancienne identité" do
      speaker = @webinar.speakers.create!(name: "Basile", email: "basile@example.test")
      old_identity = "speaker-#{speaker.id}"
      successor = speaker.replace!

      post_token(slug: @webinar.slug, speaker_token: speaker.token, identity: old_identity)
      assert_response :forbidden
      assert_equal "registration_required", response.parsed_body.fetch("error")

      post_token(slug: @webinar.slug, speaker_token: successor.token, identity: old_identity)
      assert_response :success
      body = response.parsed_body
      assert_equal "speaker", body.fetch("role")
      assert_equal "speaker-#{successor.id}", body.fetch("identity")
      assert_not_equal old_identity, body.fetch("identity")
      claims = JWT.decode(body.fetch("token"), FAKE_SECRET, true, algorithm: "HS256").first
      assert_equal "speaker-#{successor.id}", claims.fetch("sub")
      assert_not_includes claims.to_json, "speaker_link"
    end

    test "revoked speaker has no privileged access and still needs viewer registration" do
      speaker = @webinar.speakers.create!(name: "Basile")
      speaker.revoke!
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_response :forbidden
      assert_equal "registration_required", response.parsed_body.fetch("error")
      registration = confirm_viewer
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_response :success
      assert_equal "viewer", response.parsed_body.fetch("role")
      assert_equal "viewer-#{registration.id}", response.parsed_body.fetch("identity")
    end

    # L'intervenant RETIRÉ depuis la régie qui présente
    # son jeton n'obtient pas de jeton spectateur par repli, même inscrit.
    test "speaker removed from the room presenting their token gets no viewer fallback" do
      confirm_viewer
      speaker = @webinar.speakers.create!(name: "Basile")
      speaker.remove_from_room!

      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_response :forbidden
      assert_equal "registration_required", response.parsed_body.fetch("error")
    end

    test "named speaker is scoped to its room and host retains precedence" do
      speaker = @webinar.speakers.create!(name: "Basile")
      other = Webinar.create!(title: "Other", starts_at: 1.day.from_now, host_sub: @host.oidc_sub, visibility: "published")
      post_token(slug: other.slug, speaker_token: speaker.token)
      assert_response :forbidden
      sign_in_as(@host)
      post_token(slug: @webinar.slug, speaker_token: speaker.token)
      assert_equal "host", response.parsed_body.fetch("role")
      assert_equal "host-sub-marc", response.parsed_body.fetch("identity")
    end

    test "legacy_speaker_token_est_desormais_refuse" do
      # L'ancien `Webinar#speaker_token`
      # (signed_id purpose:speaker) et le fallback `find_signed` ont
      # été retirés. Un token signé legacy équivalent ne résout plus
      # côté serveur → 403 (pas d'inscription viewer non plus).
      legacy_token = @webinar.signed_id(purpose: :speaker)
      post_token(slug: @webinar.slug, speaker_token: legacy_token)
      assert_response :forbidden
    end

    # Un spectateur retiré depuis la régie garde son
    # cookie d'inscription confirmée, mais plus aucun jeton ne lui est émis.
    test "spectateur retiré de la salle : plus de jeton, même avec son cookie" do
      registration = confirm_viewer
      post_token(slug: @webinar.slug)
      assert_response :success

      registration.remove_from_room!
      post_token(slug: @webinar.slug)
      assert_response :forbidden
      assert_equal "registration_required", response.parsed_body.fetch("error")
    end

    # ---- prise de parole d'un spectateur ----

    test "jeton d'un spectateur avec accord : la parole accordée et active le fait publier, même après un rechargement" do
      @webinar.update!(state: "live", started_at: Time.current)
      registration = confirm_viewer
      ParticipantConsent.grant!(registration, recording: true, excerpts: false, adult: true)
      assert_equal false, fresh_video_grant.fetch("canPublish")

      hand = @webinar.hand_raises.create!(registration: registration, raised_at: Time.current, state: "waiting")
      assert_equal false, fresh_video_grant.fetch("canPublish"), "main levée, pas encore accordée"

      # Recharger la page après l'accord : le nouveau jeton garde la parole,
      # sous un TTL court (la parole se retire).
      hand.update!(state: "granted", granted_at: Time.current)
      assert_equal true, fresh_video_grant.fetch("canPublish")
      assert_equal "viewer", response.parsed_body.fetch("role"), "la salle reste celle d'un spectateur"
      assert_operator token_lifetime, :<=, LivekitTokenService::COHOST_TTL

      hand.update!(state: "revoked", revoked_at: Time.current)
      assert_equal false, fresh_video_grant.fetch("canPublish")
    end

    test "un inscrit participant entre main levée, sans publier ; une seule fois" do
      @webinar.update!(state: "live", started_at: Time.current)
      registration = confirm_viewer
      registration.update!(participation: "participant")

      assert_equal false, fresh_video_grant.fetch("canPublish")
      hand = @webinar.hand_raises.sole
      assert_equal [ registration, "waiting" ], [ hand.registration, hand.state ]

      HandRaiseControl.new(@webinar).lower_hand(registration)
      fresh_video_grant
      assert_empty @webinar.hand_raises.active, "une main baissée ne se relève pas au rechargement"
    end

    test "un inscrit spectateur entre sans main levée" do
      @webinar.update!(state: "live", started_at: Time.current)
      confirm_viewer

      fresh_video_grant
      assert_empty @webinar.hand_raises
    end

    private

    # Claims du jeton demandé à l'instant par ce navigateur.
    def fresh_claims(**payload)
      post_token(**payload)
      assert_response :success
      JWT.decode(response.parsed_body.fetch("token"), FAKE_SECRET, true, algorithm: "HS256").first
    end

    # Grant `video` d'un jeton demandé à l'instant par ce navigateur.
    def fresh_video_grant
      post_token(slug: @webinar.slug)
      assert_response :success
      video_grant
    end

    def confirm_viewer
      registration = @webinar.registrations.create!(email: "viewer@example.test", name: "Alice")
      post confirm_registration_path(registration.token)
      assert_response :redirect
      registration.reload
    end

    # POST JSON. `as: :json` sérialise le body et pose le Content-Type.
    def post_token(**payload)
      post "/api/token", params: payload, as: :json
    end

    # Durée de vie restante, en secondes, du jeton de la dernière réponse.
    def token_lifetime
      JWT.decode(response.parsed_body.fetch("token"), FAKE_SECRET, true, algorithm: "HS256").first.fetch("exp") - Time.current.to_i
    end

    # Grant `video` du jeton de la dernière réponse.
    def video_grant
      JWT.decode(response.parsed_body.fetch("token"), FAKE_SECRET, true, algorithm: "HS256").first.fetch("video")
    end

    # Helper OIDC enrichi. `email_verified: true` par
    # défaut → les tests existants qui attendent `:host` continuent de
    # fonctionner. Les tests qui exercent le cas `:guest_host sans
    # verified` passent explicitement `email_verified: false`.
    def sign_in_as(user, email_verified: true, groups: nil)
      OmniAuth.config.test_mode = true
      info = { email: user.email, email_verified: email_verified }
      raw_info = { email_verified: email_verified }
      raw_info[:groups] = groups if groups
      OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
        provider: "pocket_id",
        uid: user.oidc_sub,
        info: info,
        extra: { raw_info: raw_info }
      )
      Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
      get "/auth/pocket_id/callback"
      Rails.application.env_config.delete("omniauth.auth")
      OmniAuth.config.mock_auth[:pocket_id] = nil
      OmniAuth.config.test_mode = false
    end
  end
end
