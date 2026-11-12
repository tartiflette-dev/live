require "application_system_test_case"

# Préférences de périphériques : « sauvegarder les
# préférences de device par user ».
#
# Constat en direct : un intervenant à deux micros
# (Yeti et celui de sa webcam) devait re-choisir son micro à chaque
# arrivée ; à l'écran d'entrée, « deux en orange ». Causes :
#   - le menu vendor ne remontait jamais un choix fait sur l'aperçu : le
#     PreJoin rejoignait avec le défaut et n'enregistrait rien ;
#   - la mémoire du PreJoin était coupée pour toute invitation nominative ;
#   - quand l'actif est « default », vendor marquait aussi la première
#     entrée de la liste dès qu'aucun libellé ne commence par « Default »
#     (navigateur en français).
#
# Chromium headless fournit des périphériques factices : trois micros
# (« Fake Default Audio Input » d'identifiant `default`, « Fake Audio
# Input 1 », « Fake Audio Input 2 ») et une caméra (`fake_device_0`).
# Leurs identifiants sont propres à l'origine : ils sont lus dans la page.
# Pas de serveur LiveKit (livekit.invalid) : la Room de la page est
# retrouvée par le contexte React (LivekitRoomRecipe).
class DevicePreferencesTest < JsSystemTestCase
  include LivekitRoomRecipe
  include OidcSignIn

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"
  LOCAL_KEY   = "undust-live:device-preferences"
  PREJOIN_MIC = "[data-testid='prejoin'] .lk-button-group.audio"
  PREJOIN_CAM = "[data-testid='prejoin'] .lk-button-group.video"
  BAR_MIC     = "[data-testid='room-controls'] .lk-button-group:has([data-lk-source='microphone'])"
  BAR_CAM     = "[data-testid='room-controls'] .lk-button-group:has([data-lk-source='camera'])"

  # Identifiant d'un périphérique factice pour cette origine (autorisation
  # obtenue d'abord : sans elle, le navigateur masque les identifiants).
  DEVICE_ID_JS = <<~JS.freeze
    const [label, done] = [arguments[0], arguments[arguments.length - 1]];
    navigator.mediaDevices.getUserMedia({ audio: true, video: true })
      .then((stream) => { stream.getTracks().forEach((t) => t.stop()); return navigator.mediaDevices.enumerateDevices(); })
      .then((devices) => done((devices.find((d) => d.label === label) || {}).deviceId || null))
      .catch((err) => done('erreur : ' + err));
  JS

  # Navigateur en français dont la liste ne commence pas par le défaut
  # (Chrome range en tête le périphérique préféré) : l'entrée `default` est
  # libellée « Par défaut - … » et passe en dernier.
  FRENCH_DEVICE_LIST_JS = <<~JS.freeze
    (() => {
      const enumerate = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
      navigator.mediaDevices.enumerateDevices = async () => {
        const devices = (await enumerate()).map((d) => ({
          deviceId: d.deviceId, groupId: d.groupId, kind: d.kind, label: d.label, toJSON() { return this; },
        }));
        const byDefault = devices.find((d) => d.kind === 'audioinput' && d.deviceId === 'default');
        if (!byDefault || !byDefault.label) return devices;
        byDefault.label = 'Par défaut - Fake Audio Input 1';
        return [...devices.filter((d) => d !== byDefault), byDefault];
      };
    })();
  JS

  # Premier passage sur un navigateur : tant qu'aucune capture n'a été
  # autorisée, la liste ne livre ni identifiants ni libellés (Chromium
  # headless les montre d'emblée, faute de vraie invite).
  HIDDEN_UNTIL_CAPTURE_JS = <<~JS.freeze
    (() => {
      let allowed = false;
      const enumerate = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
      const getUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
      navigator.mediaDevices.getUserMedia = async (constraints) => {
        const stream = await getUserMedia(constraints);
        allowed = true;
        return stream;
      };
      navigator.mediaDevices.enumerateDevices = async () => {
        const devices = await enumerate();
        if (allowed) return devices;
        return devices.map((d) => ({ deviceId: '', groupId: '', kind: d.kind, label: '', toJSON() { return this; } }));
      };
    })();
  JS

  # Compte les captures demandées par la page (micro ou caméra ouverts).
  CAPTURE_COUNTER_JS = <<~JS.freeze
    (() => {
      window.__captures = 0;
      const getUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
      navigator.mediaDevices.getUserMedia = (constraints) => { window.__captures += 1; return getUserMedia(constraints); };
    })();
  JS

  setup do
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
    @webinar = create_live_webinar("Café IA #8")
    @speaker = @webinar.speakers.create!(name: "Camille Martin")
    # Accord à l'image déjà donné (participant_consent_test couvre la fenêtre).
    ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    forget_browser_preferences
  end

  teardown do
    forget_browser_preferences
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @saved_env[k] }
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "intervenant : le micro choisi au PreJoin est celui de la salle, et il revient sans mémoire locale" do
    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    assert_selected PREJOIN_MIC, "Fake Default Audio Input"

    pick PREJOIN_MIC, "Fake Audio Input 2"
    assert_selected PREJOIN_MIC, "Fake Audio Input 2"
    join

    assert_equal device_id("Fake Audio Input 2"), room_audio_option.fetch("deviceId")
    saved = wait_for { @speaker.reload.device_preference }
    assert_equal "Fake Audio Input 2", saved.audio_input_label
    assert_equal device_id("Fake Audio Input 2"), saved.audio_input_device_id

    forget_browser_preferences
    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    assert_selected PREJOIN_MIC, "Fake Audio Input 2"
  end

  test "intervenant d'un nouveau webinaire : ce navigateur se souvient de son dernier micro" do
    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    pick PREJOIN_MIC, "Fake Audio Input 1"
    join
    wait_for { @speaker.reload.device_preference }

    next_speaker = create_live_webinar("Café IA #9").speakers.create!(name: "Camille Martin")
    visit join_webinar_path(slug: next_speaker.webinar.slug, t: next_speaker.token)

    assert_selected PREJOIN_MIC, "Fake Audio Input 1"
  end

  test "animateur : préférences de son compte appliquées, micro retrouvé par libellé, caméra coupée" do
    @host.create_device_preference!(audio_input_device_id: "identifiant-d-un-autre-navigateur",
                                    audio_input_label: "Fake Audio Input 1", video_enabled: false)
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)

    assert_selected PREJOIN_MIC, "Fake Audio Input 1"
    assert_selector "#{PREJOIN_CAM} [data-lk-source='camera'][aria-pressed='false']"
    assert_no_selector "[data-testid='prejoin'] video"
  end

  test "PreJoin : l'aperçu de la caméra est attaché" do
    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)

    assert_selector "[data-testid='prejoin'] video", wait: 10
    assert evaluate_script("document.querySelector('[data-testid=\"prejoin\"] video').srcObject !== null"),
           "aucun flux attaché à la vidéo d'aperçu"
  end

  test "ce navigateur l'emporte sur un libellé venu d'un autre poste" do
    @speaker.create_device_preference!(audio_input_device_id: "id-poste-b", audio_input_label: "Fake Audio Input 1")
    remember_in_browser("audioinput" => { "deviceId" => device_id("Fake Audio Input 2"), "label" => "Fake Audio Input 2" })

    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)

    assert_selected PREJOIN_MIC, "Fake Audio Input 2"
  end

  test "première autorisation au PreJoin : le micro mémorisé est alors retrouvé par libellé" do
    @speaker.create_device_preference!(audio_input_device_id: "id-d-un-autre-navigateur",
                                       audio_input_label: "Fake Audio Input 1")
    with_script_on_new_document(HIDDEN_UNTIL_CAPTURE_JS) do
      visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)

      assert_selected PREJOIN_MIC, "Fake Audio Input 1"
    end
  end

  test "PreJoin : la caméra coupée est mémorisée, sans toucher au micro mémorisé" do
    @speaker.create_device_preference!(audio_input_device_id: "a1b2", audio_input_label: "Micro d'un autre poste")
    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    find("#{PREJOIN_CAM} [data-lk-source='camera'][aria-pressed='true']", wait: 10).click
    join

    saved = wait_for { @speaker.reload.device_preference.video_enabled == false && @speaker.device_preference }
    assert_equal true, saved.audio_enabled
    assert_equal "Micro d'un autre poste", saved.audio_input_label, "un repli sur le défaut n'est pas un choix"
  end

  test "second poste : le micro mémorisé ailleurs n'efface pas celui de ce navigateur" do
    @speaker.create_device_preference!(audio_input_device_id: "id-poste-a", audio_input_label: "Micro du poste A")
    remember_in_browser("audioinput" => { "deviceId" => device_id("Fake Audio Input 2"), "label" => "Fake Audio Input 2" })
    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    assert_selected PREJOIN_MIC, "Fake Audio Input 2"
    find("#{PREJOIN_CAM} [data-lk-source='camera'][aria-pressed='true']", wait: 10).click
    join
    wait_for { @speaker.reload.device_preference.video_enabled == false }

    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)

    assert_selected PREJOIN_MIC, "Fake Audio Input 2"
  end

  test "un seul micro en orange : navigateur en français, défaut pas en tête de liste" do
    with_script_on_new_document(FRENCH_DEVICE_LIST_JS) do
      visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)

      assert_selected PREJOIN_MIC, "Par défaut - Fake Audio Input 1"
      assert_selector "#{PREJOIN_MIC} li", visible: :all, count: 3
    end
  end

  test "aucun micro listé : le PreJoin le dit sans attendre (garde fail-loud b)" do
    no_microphone = "navigator.mediaDevices.enumerateDevices = ((enumerate) => async () => " \
                    "(await enumerate()).filter((d) => d.kind !== 'audioinput'))" \
                    "(navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices));"
    with_script_on_new_document(no_microphone) do
      visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)

      assert_selector "[data-testid='media-error-banner']", text: "Aucun microphone détecté", wait: 10
    end
  end

  test "barre de contrôle : un choix au clic est mémorisé" do
    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    join
    grant_local_publish

    pick BAR_MIC, "Fake Audio Input 1"

    assert_selected BAR_MIC, "Fake Audio Input 1"
    saved = wait_for { @speaker.reload.device_preference }
    assert_equal "Fake Audio Input 1", saved.audio_input_label
  end

  test "barre de contrôle : un enregistrement refusé par le serveur est signalé" do
    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    join
    wait_for { @speaker.reload.device_preference }
    grant_local_publish
    @speaker.revoke!

    pick BAR_MIC, "Fake Audio Input 1"

    assert_selector "[data-testid='device-preferences-error']", text: "non enregistré (serveur 403)", wait: 10
  end

  test "barre de contrôle : une bascule venue du système n'est pas mémorisée" do
    @speaker.create_device_preference!(audio_input_device_id: "a1b2", audio_input_label: "Fake Audio Input 1")
    visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
    join
    grant_local_publish

    switch_room_device("audioinput", device_id("Fake Audio Input 2"))
    assert_selected BAR_MIC, "Fake Audio Input 2"
    pick BAR_CAM, "fake_device_0"

    saved = wait_for { @speaker.reload.device_preference.video_input_label.present? && @speaker.device_preference }
    assert_equal "fake_device_0", saved.video_input_label
    assert_equal "Fake Audio Input 1", saved.audio_input_label
  end

  test "spectateur à qui l'on donne la parole : son micro préféré est posé, micro et caméra restent fermés" do
    confirm_viewer_registration(@webinar)
    preferred = device_id("Fake Audio Input 2")
    remember_in_browser("audioinput" => { "deviceId" => preferred, "label" => "Fake Audio Input 2" },
                        "audioEnabled" => true, "videoEnabled" => true)
    registration = @webinar.registrations.find_by!(email: "viewer@example.test")
    HandRaise.create!(webinar: @webinar, registration: registration, state: "granted",
                      raised_at: Time.current, granted_at: Time.current)
    # Accord à l'image déjà donné (participant_consent_test couvre la fenêtre).
    ParticipantConsent.grant!(registration, recording: true, excerpts: false, adult: true)

    with_script_on_new_document(CAPTURE_COUNTER_JS) do
      visit public_webinar_path(slug: @webinar.slug)
      wait_for_hand_raise_viewer_subscribed
      grant_local_publish
      assert_selector "[data-testid='hand-raise-controls'] [data-lk-source='microphone']", wait: 10

      assert_equal preferred, wait_for { room_active_device("audioinput").presence_in([ preferred ]) }
      # Consentement (/confidentialite) : c'est au spectateur d'ouvrir son
      # micro et sa caméra, la mémoire « activé » ne s'applique pas à lui.
      assert_selector "[data-testid='hand-raise-controls'] [data-lk-source='microphone'][aria-pressed='false']"
      assert_selector "[data-testid='hand-raise-controls'] [data-lk-source='camera'][aria-pressed='false']"
      assert_equal 0, evaluate_script("window.__captures"), "micro ou caméra ouverts sans clic du spectateur"
    end
    assert_equal 0, DevicePreference.count
  end

  private

  def create_live_webinar(title)
    Webinar.create!(title: title, starts_at: 1.day.from_now, host_sub: @host.oidc_sub,
                    visibility: "published", state: "live", started_at: Time.current)
  end

  # La mémoire du navigateur survit d'un test à l'autre (même Chrome).
  def forget_browser_preferences
    visit "/" unless current_url.start_with?("http")
    execute_script("localStorage.removeItem(#{LOCAL_KEY.to_json})")
  end

  def remember_in_browser(preferences = {}, **flags)
    preferences = preferences.merge(flags.transform_keys(&:to_s))
    execute_script("localStorage.setItem(#{LOCAL_KEY.to_json}, #{preferences.to_json.to_json})")
  end

  def device_id(label)
    id = evaluate_async_script(DEVICE_ID_JS, label)
    assert id.present? && !id.start_with?("erreur"), "périphérique factice #{label.inspect} introuvable : #{id.inspect}"
    id
  end

  def pick(group, label)
    find("#{group} .lk-button-menu:not([disabled])", wait: 10).click
    find("#{group} li", text: label, exact_text: true).find("button").click
  end

  # Exactement UNE entrée marquée, et c'est `label` (le filtre de texte de
  # Capybara s'applique avant le compte : deux assertions).
  def assert_selected(group, label)
    assert_selector "#{group} li [aria-current='true']", visible: :all, text: label, exact_text: true, wait: 10
    assert_selector "#{group} li [aria-current='true']", visible: :all, count: 1
  end

  def join
    find("[data-testid='prejoin'] .lk-join-button:not([disabled])", wait: 10).click
    assert_selector "[data-testid='stage']", wait: 10
  end

  # Options de micro données à <LiveKitRoom> (prop `audio`).
  def room_audio_option
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector('[data-testid="livekit-room"]');
        const fiberKey = Object.keys(el).find((k) => k.startsWith('__reactFiber$'));
        for (let fiber = el[fiberKey]; fiber; fiber = fiber.return) {
          const props = fiber.memoizedProps;
          if (props && 'audio' in props && 'token' in props) return props.audio;
        }
        return null;
      })()
    JS
  end

  # Publication accordée au participant local, une fois la connexion
  # (vers livekit.invalid) échouée — comme StageLayoutTest#populate_room.
  def grant_local_publish
    assert_equal "ok", wait_for(timeout: 10) { evaluate_script(GRANT_LOCAL_PUBLISH_JS) }
  end

  # `grant_local_publish` émet UNE fois `participantPermissionsChanged`.
  # `useLocalParticipantPermissions` (LiveKit) ne s'abonne qu'à l'exécution
  # des effets passifs du composant, après son affichage, et fige alors sa
  # valeur de départ prise au rendu : un évènement émis dans cet intervalle
  # est perdu pour de bon (la barre de contrôle n'apparaît jamais). Sous
  # charge, l'intervalle s'allonge et l'émission du test y tombe.
  # Le statut « main accordée » ne s'affiche qu'après le `fetch` lancé par
  # un effet passif du même rendu : il prouve que l'abonnement est en place.
  def wait_for_hand_raise_viewer_subscribed
    assert_selector "[data-testid='hand-raise-toggle'][data-hand-state='granted']", wait: 10
  end

  def switch_room_device(kind, device_id)
    evaluate_async_script(<<~JS, kind, device_id)
      const [kind, deviceId, done] = arguments;
      #{FIND_ROOM_JS}
      room.switchActiveDevice(kind, deviceId, false).then(() => done(true), (err) => done(String(err)));
    JS
  end

  def room_active_device(kind)
    evaluate_script("(() => { #{FIND_ROOM_JS} return room && room.getActiveDevice(#{kind.to_json}); })()")
  end

  def with_script_on_new_document(source)
    script = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: source)
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
