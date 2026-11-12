require "application_system_test_case"

# Accord à l'image :
# un intervenant, un co-animateur invité, ou un spectateur à qui la
# parole est donnée, n'allume caméra ou micro qu'après avoir coché la case
# de l'enregistrement et « 18 ans ou plus » ; l'accord fait ouvrir la
# publication par la salle ; « Retirer mon accord » coupe tout et la referme.
#
# Pas de serveur LiveKit (livekit.invalid) : la salle simulée
# (LivekitPacketDelivery::RoomRecorder) reçoit les permissions que le
# serveur demande. « La caméra s'allume » = le navigateur ouvre une capture
# vidéo (espion sur getUserMedia) ; « elle est coupée » = cette capture est
# arrêtée.
class ParticipantConsentTest < JsSystemTestCase
  include LivekitRoomRecipe
  include LivekitPacketDelivery

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"
  PREJOIN_MIC = "[data-testid='prejoin'] .lk-button-group.audio [data-lk-source='microphone']"
  PREJOIN_CAM = "[data-testid='prejoin'] .lk-button-group.video [data-lk-source='camera']"
  BAR_CAM     = "[data-testid='room-controls'] button[data-lk-source='camera']"

  # Pistes ouvertes par la page, relevées dans `window.__captured`.
  CAPTURE_SPY_JS = <<~JS.freeze
    (() => {
      window.__captured = [];
      const getUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
      navigator.mediaDevices.getUserMedia = async (constraints) => {
        const stream = await getUserMedia(constraints);
        window.__captured.push(...stream.getTracks());
        return stream;
      };
    })();
  JS

  setup do
    @host = User.create!(email: "marc@example.test", oidc_sub: "sub-marc-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @speaker = @webinar.speakers.create!(name: "Camille Martin")
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    @room = RoomRecorder.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @room }
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
    Rails.configuration.x.room_service_client_factory = @previous_factory
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @saved_env[k] }
  end

  test "intervenant : la caméra ne s'allume qu'avec les cases enregistrement et âge cochées" do
    with_capture_spy do
      join_stage_without_media

      find(BAR_CAM, wait: 10).click
      within("[data-testid='consent-dialog']") do
        assert_text "Avant d'allumer votre caméra ou votre micro"
        check ParticipantConsent::LABELS[:excerpts]
        click_on "Allumer"
        assert_selector "[data-testid='consent-message']", text: "caméra et micro restent coupés"

        check ParticipantConsent::LABELS[:recording]
        click_on "Allumer"
        assert_selector "[data-testid='consent-message']", text: "il faut avoir 18 ans ou plus"
      end
      assert_equal 0, captured("video"), "caméra ouverte sans accord complet"
      assert_nil ParticipantConsent.current_for(@speaker)

      assert_empty @room.permissions, "rien d'ouvert côté salle sans accord"

      check ParticipantConsent::LABELS[:adult]
      click_on "Allumer"

      assert_no_selector "[data-testid='consent-dialog']", wait: 10
      assert_equal 1, wait_for { captured("video").nonzero? }
      consent = ParticipantConsent.current_for(@speaker)
      assert_equal [ true, true, true ], [ consent.recording_accepted, consent.excerpts_accepted, consent.adult_declared ]
      assert_equal [ [ "speaker-#{@speaker.id}", true ] ], @room.permissions, "l'accord fait ouvrir la publication"
      assert_selector "[data-testid='stage-bar'] [data-testid='consent-withdraw']", text: "Retirer mon accord"
    end
  end

  test "intervenant qui rejoint caméra allumée : la fenêtre s'ouvre d'emblée, refusée la caméra reste coupée" do
    with_capture_spy do
      visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
      find("[data-testid='prejoin'] .lk-join-button:not([disabled])", wait: 10).click
      assert_selector "[data-testid='consent-dialog']", wait: 10
      reset_captures

      click_on "Rester spectateur·rice"

      assert_no_selector "[data-testid='consent-dialog']"
      assert_equal false, room_prop("video"), "la salle a reçu la caméra du PreJoin sans accord"
      sleep 0.5
      assert_equal 0, captured("video")
      assert_equal 0, ParticipantConsent.count
    end
  end

  test "intervenant : « Retirer mon accord » coupe la caméra, retire le droit de publier, et le rend spectateur" do
    with_capture_spy do
      join_stage_without_media
      find(BAR_CAM, wait: 10).click
      check ParticipantConsent::LABELS[:recording]
      check ParticipantConsent::LABELS[:adult]
      click_on "Allumer"
      wait_for { captured("video").nonzero? }

      find("[data-testid='consent-withdraw']", text: "Retirer mon accord").click
      sleep 0.6 # au-delà de la garde anti double-clic (500 ms)
      find("[data-testid='consent-withdraw']", text: "Confirmer : couper caméra et micro").click

      assert_selector "[data-testid='consent-withdrawn']", text: "Accord retiré", wait: 10
      assert evaluate_script("window.__captured.filter((t) => t.kind === 'video').every((t) => t.readyState === 'ended')"),
             "la caméra est restée allumée après le retrait"
      assert ParticipantConsent.where(holder: @speaker).sole.withdrawn?
      assert_equal [ [ "speaker-#{@speaker.id}", true ], [ "speaker-#{@speaker.id}", false ] ], @room.permissions
      assert_no_selector "[data-testid='consent-withdraw']"
    end
  end

  test "spectateur à qui la parole est donnée sans accord : la fenêtre d'abord, son accord ouvre sa publication" do
    confirm_viewer_registration(@webinar)
    registration = @webinar.registrations.find_by!(email: "viewer@example.test")
    HandRaise.create!(webinar: @webinar, registration: registration, state: "granted",
                      raised_at: Time.current, granted_at: Time.current)

    with_capture_spy do
      visit public_webinar_path(slug: @webinar.slug)
      assert_selector "[data-testid='hand-raise-toggle'][data-hand-state='granted']", wait: 10
      assert_selector "[data-testid='hand-raise-status']", text: "donnez votre accord à l'image"

      find("[data-testid='hand-raise-controls'] button[data-lk-source='camera']", wait: 10).click
      check ParticipantConsent::LABELS[:recording]
      check ParticipantConsent::LABELS[:adult]
      click_on "Allumer"

      assert_equal 1, wait_for { captured("video").nonzero? }
      assert_equal false, ParticipantConsent.current_for(registration).excerpts_accepted
      assert_equal [ [ "viewer-#{registration.id}", true ] ], @room.permissions
      assert_selector ".lk-viewer__header [data-testid='consent-withdraw']"
    end
  end

  test "co-animateur invité : la fenêtre comme un intervenant ; le propriétaire allume sans fenêtre" do
    cohost = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean-#{SecureRandom.hex(4)}")
    @webinar.webinar_hosts.create!(email: cohost.email, invited_by_sub: @host.oidc_sub)

    sign_in_as(cohost)
    join_stage_without_media(stage_webinar_path(slug: @webinar.slug), name: "Jean")
    find(BAR_CAM, wait: 10).click
    assert_selector "[data-testid='consent-dialog']"
    click_on "Rester spectateur·rice"
    assert_empty @room.permissions

    sign_in_as(@host)
    join_stage_without_media(stage_webinar_path(slug: @webinar.slug), name: "Marc")
    assert_equal "ok", wait_for(timeout: 10) { evaluate_script(GRANT_LOCAL_PUBLISH_JS) }
    find(BAR_CAM, wait: 10).click
    assert_no_selector "[data-testid='consent-dialog']"
    assert_no_selector "[data-testid='consent-withdraw']"
  end

  test "scène : intervenant et co-animateur sans accord restent visibles, en attente d'accord, et peuvent être mis en avant" do
    sign_in_as(@host)
    join_stage_without_media(stage_webinar_path(slug: @webinar.slug), name: "Marc")
    assert_equal "ok", wait_for(timeout: 10) { evaluate_script(POPULATE_AWAITING_JS) }

    within("[data-testid='stage']") do
      %w[Mathilde Camille Basile].each { |name| assert_selector ".lk-participant-tile", text: name, wait: 10 }
      assert_no_selector ".lk-participant-tile", text: "Spectatrice"
      assert_selector ".lk-participant-tile", text: "Mathilde" do |tile|
        tile.assert_selector "[data-testid='consent-pending']", text: "En attente d'accord"
      end
      assert_selector ".lk-participant-tile", text: "Camille" do |tile|
        tile.assert_selector "[data-testid='consent-pending']"
      end
      assert_selector ".lk-participant-tile", text: "Basile" do |tile|
        tile.assert_no_selector "[data-testid='consent-pending']"
      end
    end
    assert_selector "[data-testid='audience-count']", text: "1 spectateur"

    execute_script(<<~JS)
      (() => {
        #{FIND_ROOM_JS}
        const metadata = JSON.stringify({ spotlight: 'speaker-mathilde' });
        room.roomInfo = Object.assign({}, room.roomInfo || {}, { metadata });
        room.emit('roomMetadataChanged', metadata);
      })()
    JS
    assert_selector ".lk-focus-stage__main .lk-participant-tile", text: "Mathilde", wait: 10
    assert_selector ".lk-focus-stage__main [data-testid='spotlight-badge'] ~ [data-testid='consent-pending']"
  end

  private

  # Salle simulée vue de la scène : un intervenant et un co-animateur que la
  # salle ne laisse pas publier (pas d'accord), un intervenant qui publie, un
  # spectateur.
  POPULATE_AWAITING_JS = <<~JS.freeze
    (() => {
      #{LivekitRoomRecipe::FIND_ROOM_JS}
      if (!room || room.state !== 'disconnected') return null;
      const grant = (canPublish) => ({ canPublish, canSubscribe: true, canPublishData: false,
                                       canPublishSources: [], hidden: false, agent: false });
      const local = room.localParticipant;
      local.permissions = grant(true);
      local.emit('participantPermissionsChanged', undefined);
      const Participant = Object.getPrototypeOf(Object.getPrototypeOf(local)).constructor;
      [['speaker-mathilde', 'Mathilde', false], ['host-sub-camille', 'Camille', false],
       ['speaker-basile', 'Basile', true], ['viewer-1', 'Spectatrice', false]].forEach(([identity, name, canPublish]) => {
        const participant = new Participant('PA_' + identity, identity, name, '', {}, undefined, 0);
        participant.permissions = grant(canPublish);
        room.remoteParticipants.set(identity, participant);
        room.emit('participantConnected', participant);
      });
      return 'ok';
    })()
  JS

  # PreJoin micro et caméra coupés, puis la salle. Sans accord, la salle ne
  # donne aucune permission de publier : Micro et Caméra ouvrent la fenêtre.
  def join_stage_without_media(path = join_webinar_path(slug: @webinar.slug, t: @speaker.token), name: nil)
    visit path
    fill_in "username", with: name if name
    # Choix du PreJoin gardés par le navigateur d'un test à l'autre : on ne
    # coupe que ce qui est allumé.
    [ PREJOIN_MIC, PREJOIN_CAM ].each do |toggle|
      button = find(toggle, wait: 10)
      button.click if button["aria-pressed"] == "true"
    end
    find("[data-testid='prejoin'] .lk-join-button:not([disabled])", wait: 10).click
    assert_selector "[data-testid='stage']", wait: 10
    reset_captures
  end

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub,
      info: { email: user.email, email_verified: true }, extra: { raw_info: { email_verified: true } }
    )
    visit "/auth/pocket_id/callback"
  end

  def captured(kind)
    evaluate_script("window.__captured.filter((t) => t.kind === #{kind.to_json}).length")
  end

  def reset_captures
    execute_script("window.__captured = []")
  end

  # Prop `audio` ou `video` donnée à <LiveKitRoom>.
  def room_prop(name)
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector('[data-testid="livekit-room"]');
        const fiberKey = Object.keys(el).find((k) => k.startsWith('__reactFiber$'));
        for (let fiber = el[fiberKey]; fiber; fiber = fiber.return) {
          const props = fiber.memoizedProps;
          if (props && #{name.to_json} in props && 'token' in props) return props[#{name.to_json}];
        }
        return null;
      })()
    JS
  end

  def with_capture_spy
    script = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: CAPTURE_SPY_JS)
    yield
  ensure
    page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: script["identifier"]) if script
  end

  def wait_for(timeout: 5)
    deadline = Time.current + timeout
    loop do
      value = yield
      return value if value
      flunk "condition jamais remplie en #{timeout} s" if Time.current > deadline
      sleep 0.1
    end
  end
end
