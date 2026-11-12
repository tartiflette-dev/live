require "application_system_test_case"

# Choix de la sortie son (« il nous faut une possibilité de sélectionner
# la sortie son », demande après un souci technique chez un
# participant) : rien dans la salle ne permettait de faire passer le son
# des autres ailleurs que sur la sortie par défaut du système.
#
# La liste des sorties est remplacée par trois sorties factices aux
# libellés connus. LiveKit pointe sur livekit.invalid : la Room n'a aucun
# participant distant, donc aucun élément audio. On vérifie la sortie que
# la Room appliquera à chaque participant, présent ou à venir
# (`room.options.audioOutput`, relu par LiveKit à la création de chacun).
class AudioOutputTest < JsSystemTestCase
  include LivekitRoomRecipe
  include OidcSignIn

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "factice-" + ("x" * 32) # clé de test (livekit.invalid), longueur suffisante pour HS256
  LOCAL_KEY   = "undust-live:device-preferences"
  OUTPUT_BUTTON = "[aria-label='Choisir la sortie son']"
  LONG_LABEL = "Haut-parleurs (Realtek(R) Audio) - Sortie numérique S/PDIF de la carte mère, connecteur arrière"

  # `window.__outputsListed` compte les listes livrées à la page.
  FAKE_OUTPUTS_JS = <<~JS.freeze
    (() => {
      window.__outputsListed = 0;
      const enumerate = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
      const output = (deviceId, label) => ({
        deviceId, groupId: 'groupe-' + deviceId, kind: 'audiooutput', label, toJSON() { return this; },
      });
      navigator.mediaDevices.enumerateDevices = async () => {
        const devices = [
          ...(await enumerate()).filter((d) => d.kind !== 'audiooutput'),
          output('default', 'Par défaut - Haut-parleurs'),
          output('haut-parleurs', 'Haut-parleurs'),
          output('casque-usb', 'Casque USB'),
          output('spdif', #{LONG_LABEL.to_json}),
        ];
        window.__outputsListed += 1;
        return devices;
      };
    })();
  JS

  # Sans autorisation micro (Chrome « cette fois », Firefox par défaut) :
  # identifiants et libellés masqués, comme le fait le navigateur.
  UNNAMED_OUTPUTS_JS = <<~JS.freeze
    (() => {
      const enumerate = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
      navigator.mediaDevices.enumerateDevices = async () => {
        const devices = (await enumerate()).map((d) => ({ deviceId: d.deviceId, groupId: d.groupId, kind: d.kind, label: d.label, toJSON() { return this; } }));
        window.__outputsListed = (window.__outputsListed || 0) + 1;
        return devices.map((d) => (d.kind === 'audiooutput' ? { ...d, deviceId: '', label: '' } : d));
      };
    })();
  JS

  # Safari : pas de setSinkId, donc pas de choix possible.
  NO_SINK_JS = "delete HTMLMediaElement.prototype.setSinkId;"

  setup do
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.day.from_now, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @speaker = @webinar.speakers.create!(name: "Camille Martin")
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

  test "intervenant : la sortie choisie dans la barre est appliquée, gardée sur ce poste, reposée à l'entrée suivante" do
    with_script_on_new_document(FAKE_OUTPUTS_JS) do
      visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
      join
      assert_selector "[data-testid='room-controls'] #{OUTPUT_BUTTON}", text: "Son"

      pick_output "Casque USB"

      assert_output_selected "Casque USB"
      assert_equal "casque-usb", wait_for { room_output.presence_in([ "casque-usb" ]) }
      assert_equal({ "deviceId" => "casque-usb", "label" => "Casque USB" }, local_preferences["audiooutput"])

      visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
      join

      assert_equal "casque-usb", wait_for { room_output.presence_in([ "casque-usb" ]) }
      assert_output_selected "Casque USB"
    end
  end

  test "la sortie son ne part jamais au serveur, et n'efface pas le micro mémorisé" do
    @speaker.create_device_preference!(audio_input_device_id: "a1b2", audio_input_label: "Micro du poste A")
    with_script_on_new_document(FAKE_OUTPUTS_JS) do
      visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
      join
      execute_script(<<~JS)
        window.__patches = [];
        const nativeFetch = window.fetch;
        window.fetch = (url, options) => {
          if (String(url).includes('/api/device_preferences')) window.__patches.push(options.body);
          return nativeFetch(url, options);
        };
      JS

      pick_output "Haut-parleurs"
      assert_equal "haut-parleurs", wait_for { room_output.presence_in([ "haut-parleurs" ]) }

      assert_equal [], evaluate_script("window.__patches")
    end
    assert_equal "Micro du poste A", @speaker.reload.device_preference.audio_input_label
  end

  test "spectateur : menu « Son » dans l'en-tête, explication de la demande d'accès au micro, rien ne déborde" do
    Capybara.current_session.current_window.resize_to(390, 844)
    confirm_viewer_registration(@webinar)
    with_script_on_new_document(FAKE_OUTPUTS_JS) do
      visit public_webinar_path(slug: @webinar.slug)
      assert_selector ".lk-viewer__header #{OUTPUT_BUTTON}", text: "Son", wait: 10
      assert_no_horizontal_scroll "menu fermé"

      find(OUTPUT_BUTTON).click
      assert_selector "##{output_menu_id} .lk-device-menu__note", text: "ni enregistré ni transmis"
      assert_selector "##{output_menu_id} li", text: LONG_LABEL
      # Ouvert, le menu peut mordre sur la marge de la vue (LiveKit le garde à
      # 5 px du bord de la FENÊTRE) : c'est la page qui ne doit pas défiler.
      assert_no_horizontal_scroll "menu ouvert, libellé long", page_only: true
      find("##{output_menu_id} li", text: "Casque USB", exact_text: true).find("button").click

      assert_equal "casque-usb", wait_for { room_output.presence_in([ "casque-usb" ]) }
      assert_equal "Casque USB", local_preferences.dig("audiooutput", "label")
    end
    assert_equal 0, DevicePreference.count
  ensure
    Capybara.current_session.current_window.resize_to(1400, 900)
  end

  test "spectateur à qui l'on donne la parole : un seul bouton « Son », celui de l'en-tête" do
    confirm_viewer_registration(@webinar)
    registration = @webinar.registrations.find_by!(email: "viewer@example.test")
    HandRaise.create!(webinar: @webinar, registration: registration, state: "granted",
                      raised_at: Time.current, granted_at: Time.current)
    ParticipantConsent.grant!(registration, recording: true, excerpts: false, adult: true)

    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "[data-testid='hand-raise-toggle'][data-hand-state='granted']", wait: 10
    assert_equal "ok", wait_for(timeout: 10) { evaluate_script(GRANT_LOCAL_PUBLISH_JS) }
    assert_selector "[data-testid='hand-raise-controls'] [data-lk-source='microphone']", wait: 10

    assert_selector OUTPUT_BUTTON, count: 1
    assert_selector ".lk-viewer__header #{OUTPUT_BUTTON}"
  end

  test "sortie mémorisée débranchée : le défaut du système, sans message d'erreur" do
    remember_in_browser("audiooutput" => { "deviceId" => "enceinte-bluetooth", "label" => "Enceinte Bluetooth" })
    with_script_on_new_document(FAKE_OUTPUTS_JS) do
      visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
      join_and_wait_for_restore

      assert_nil room_output
      assert_no_selector "[data-testid='media-error-banner']"
    end
  end

  test "sans autorisation micro (sorties non nommées) : rien n'est reposé à l'aveugle" do
    remember_in_browser("audiooutput" => { "deviceId" => "casque-usb", "label" => "Casque USB" })
    with_script_on_new_document(UNNAMED_OUTPUTS_JS) do
      visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
      join_and_wait_for_restore

      assert_nil room_output, "sortie reposée sans liste nommée : le navigateur la refuserait sans bruit"
      assert_no_selector "[data-testid='media-error-banner']"
    end
  end

  test "navigateur sans choix de sortie (Safari) : pas de bouton « Son », la salle reste utilisable" do
    with_script_on_new_document(NO_SINK_JS) do
      visit join_webinar_path(slug: @webinar.slug, t: @speaker.token)
      join

      assert_selector "[data-testid='room-controls'] .lk-room-controls__leave", text: "Quitter"
      assert_no_selector OUTPUT_BUTTON
    end
  end

  private

  def forget_browser_preferences
    visit "/" unless current_url.start_with?("http")
    execute_script("localStorage.removeItem(#{LOCAL_KEY.to_json})")
  end

  def remember_in_browser(preferences)
    execute_script("localStorage.setItem(#{LOCAL_KEY.to_json}, #{preferences.to_json.to_json})")
  end

  def local_preferences
    JSON.parse(evaluate_script("localStorage.getItem(#{LOCAL_KEY.to_json})") || "{}")
  end

  def join
    find("[data-testid='prejoin'] .lk-join-button:not([disabled])", wait: 10).click
    assert_selector "[data-testid='stage']", wait: 10
  end

  # Entre dans la salle, puis attend la liste lue par la restauration de la
  # sortie (le PreJoin en a déjà lu : on attend une lecture DE PLUS). La
  # restauration éventuelle suit cette lecture d'une microtâche : courte marge.
  def join_and_wait_for_restore
    listed = evaluate_script("window.__outputsListed || 0").to_i
    join
    wait_for { evaluate_script("window.__outputsListed || 0").to_i > listed }
    sleep 0.2
  end

  def output_menu_id
    find(OUTPUT_BUTTON, wait: 10)["aria-controls"]
  end

  def pick_output(label)
    find(OUTPUT_BUTTON, wait: 10).click
    find("##{output_menu_id} li", text: label, exact_text: true).find("button").click
  end

  def assert_output_selected(label)
    menu = "##{output_menu_id}"
    assert_selector "#{menu} li [aria-current='true']", visible: :all, text: label, exact_text: true, wait: 10
    assert_selector "#{menu} li [aria-current='true']", visible: :all, count: 1
  end

  # Sortie que la Room applique à chaque participant (présent ou à venir).
  def room_output
    evaluate_script("(() => { #{FIND_ROOM_JS} return room?.options?.audioOutput?.deviceId ?? null; })()")
  end

  def assert_no_horizontal_scroll(state, page_only: false)
    overflow = evaluate_script(<<~JS)
      [document.documentElement.scrollWidth - document.documentElement.clientWidth,
       (() => { const v = document.querySelector('.lk-viewer'); return v.scrollWidth - v.clientWidth; })()]
    JS
    overflow = overflow.first(1) if page_only
    assert_equal [ 0 ] * overflow.size, overflow.map { |v| [ v, 0 ].max }, "défilement en largeur (page, vue) — #{state}"
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
