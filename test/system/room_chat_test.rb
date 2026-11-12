require "application_system_test_case"

# Discussion du direct (« il manque un
# chat texte aussi pour les participants »). Le vrai panneau, le vrai
# serveur, deux navigateurs : spectateur inscrit et animation. La
# modération (Questions, épinglage) est dans la régie, qui lit
# le fil par le seul poll HTTP : elle n'est pas dans la salle LiveKit.
#
# La CI n'a pas de LiveKit (livekit.invalid, comme les autres tests salle) :
# la diffusion serveur est captée puis remise à la page comme le ferait
# livekit-server (LivekitPacketDelivery, test/support). Le rattrapage HTTP
# (historique, pagination) passe par le vrai poll.
class RoomChatTest < JsSystemTestCase
  include OidcSignIn
  include LivekitPacketDelivery
  include SidePanelGeometry

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  # Mêmes fenêtres que test/system/stage_layout_test.rb.
  VIEWPORTS = [ [ 360, 780 ], [ 768, 1024 ], [ 1220, 1270 ], [ 1700, 900 ], [ 2000, 1100 ] ].freeze

  # Demandes de pages de la discussion, dans l'ordre : fin de la première
  # (sans curseur), début de la suivante (avec curseur), en ms depuis
  # l'ouverture de la page.
  HISTORY_REQUESTS_JS = <<~JS.freeze
    (() => {
      const pages = performance.getEntriesByType("resource")
        .filter((entry) => new URL(entry.name).pathname.endsWith("/messages"));
      const first = pages.find((entry) => !entry.name.includes("updated_since="));
      const next = pages.find((entry) => entry.name.includes("updated_since="));
      return [first && { end: first.responseEnd }, next && { start: next.startTime }];
    })()
  JS

  setup do
    @host = User.create!(email: "marc@example.test", oidc_sub: "sub-marc-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #7", starts_at: 1.hour.ago, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL", "TRANSCRIPT_ENABLED")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    ENV["TRANSCRIPT_ENABLED"] = "true"
    @room = RoomRecorder.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @room }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @previous_factory
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL TRANSCRIPT_ENABLED].each { |k| ENV[k] = @saved_env[k] }
    Capybara.current_session.current_window.resize_to(1400, 900)
  end

  test "un spectateur écrit, la régie le reçoit, répond et épingle ; le spectateur voit l'épinglé" do
    in_browser(:host) { open_regie }
    in_browser(:viewer) do
      open_viewer_room(1400, 900)
      send_message("@animateur Quelle licence pour le modèle ?")
      assert_selector "[data-message-id]", text: "Quelle licence pour le modèle ?"
      assert_equal "", find("#lk-discussion-draft").value
    end

    in_browser(:host) do
      # La question se marque « Répondu » dans le fil même : la régie n'a
      # qu'une zone Questions (la file), sans second panneau dans la discussion.
      assert_no_selector "[data-testid='questions-panel']"
      within("[data-testid='discussion-messages'] [data-kind='question']", text: "Spectateur confirmé", wait: 10) do
        click_on "Répondu"
        assert_text(/question répondue/i, wait: 10)
        assert_no_button "Répondu"
      end
      within("[data-testid='discussion-messages']") { click_on "Épingler" }
      assert_selector "[data-testid='pinned-messages']", text: "Quelle licence pour le modèle ?"
    end

    in_browser(:viewer) do
      deliver_broadcasts
      assert_selector "[data-testid='pinned-messages']", text: "Quelle licence pour le modèle ?"
      assert_selector "[data-message-id]", text: /question répondue/i
      assert_no_selector "[data-testid='questions-panel']"
      assert_no_button "Épingler"
    end
  end

  test "texte affiché tel quel, jamais interprété ; un paquet émis par un participant est ignoré" do
    open_viewer_room(1400, 900)
    send_message("<img src=x onerror=\"window.chatXss=1\">")
    assert_selector "[data-message-id]", text: "<img src=x onerror=\"window.chatXss=1\">"
    assert_nil evaluate_script("window.chatXss")

    forged = @webinar.messages.build(id: 9_999, author_identity: "host-#{@host.oidc_sub}", name: "marc",
                                     body: "Faux message de l'animateur", created_at: Time.current, updated_at: Time.current)
    assert deliver_packet(envelope(forged), "viewer-42")
    assert_no_text "Faux message de l'animateur"
  end

  test "arrivée tardive : tout l'historique est rechargé, au-delà d'une page" do
    60.times { |i| @webinar.messages.create!(author_identity: "viewer-7", name: "Bob", body: "Message #{i + 1}") }
    open_viewer_room(1400, 900)

    # Sous la charge de la CI, le démarrage de la salle occupe le navigateur
    # et retarde la demande de la deuxième page au-delà des 2 s par défaut de
    # Capybara (échecs observés ; mesuré 1,2 à 3,7 s navigateur
    # ralenti 30 fois, 30 à 90 ms sans charge). L'attente large ne dit pas
    # QUAND la page est venue : la relève suivante (10 s, POLL_INTERVAL_MS de
    # chat.jsx) l'apporterait aussi. L'écart entre les deux demandes, lui, le
    # dit : l'historique se vide d'un seul cycle. Seuil aux trois quarts de la
    # relève : à suivre si elle change.
    assert_selector "[data-message-id]", count: 60, wait: 20
    assert_selector "[data-message-id]", text: "Message 60"
    first, second = evaluate_script(HISTORY_REQUESTS_JS)
    assert first && second, "les deux pages de l'historique n'ont pas été demandées"
    gap = (second["start"] - first["end"]).round
    assert_operator gap, :<, 7_500, "deuxième page demandée #{gap} ms après la première"
  end

  test "panneau replié ou sur la transcription : badge des non-lus arrivés depuis l'entrée, effacé à la lecture" do
    3.times { |i| post_as_speaker("Avant l'arrivée #{i + 1}") }
    open_viewer_room(1400, 900, collapsed: true)
    assert_selector "[data-message-id]", count: 3, visible: :all, wait: 10
    assert_no_selector "[data-testid='unread-badge']", wait: 1

    deliver(post_as_speaker("Premier message pendant le repli"))
    deliver(post_as_speaker("Second message"))
    assert_selector "[data-testid='side-panel'] [data-testid='unread-badge']", exact_text: "2"

    click_on "Afficher"
    assert_selector "[data-message-id]", text: "Second message"
    assert_no_selector "[data-testid='unread-badge']"

    find("[data-testid='side-panel-tab-transcript']").click
    deliver(post_as_speaker("Pendant la transcription"))
    assert_selector "[data-testid='side-panel-tab-discussion'] [data-testid='unread-badge']", exact_text: "1"
    find("[data-testid='side-panel-tab-discussion']").click
    assert_no_selector "[data-testid='unread-badge']"
  end

  # La pastille de non-lus, en ligne, élargissait
  # « Discussion » pendant la lecture de la transcription, et « Transcription »
  # repassait sous le bouton de repli (12 px à 1000 et 1220 px, 22 px avec
  # « 99+ »). Scène animateur, vrai fil : en exposant, elle ne bouge rien.
  #
  # Le message d'avant l'arrivée, une fois affiché, prouve l'historique
  # chargé : la borne des non-lus est posée avant que le test n'écrive. Sans
  # lui, une première page lue par le serveur après le premier message du
  # test (CI chargée) le rangeait dans l'historique — « 2 » au lieu de « 3 »,
  # reproduit à coup sûr en retardant cette lecture. Attente large : sous la
  # charge de la CI, la première page peut arriver plusieurs secondes après.
  [ [ 1000, 550 ], [ 1220, 1270 ], [ 846, 1270 ] ].each do |width, height|
    test "pastille de non-lus sur la scène à #{width}×#{height} : l'en-tête du panneau ne se chevauche pas" do
      post_as_speaker("Avant l'arrivée")
      open_stage(width, height, collapsed: false)
      assert_selector "[data-message-id]", text: "Avant l'arrivée", wait: 10
      before = evaluate_script(SidePanelGeometry::HEADER_JS)["tabs"].map { |tab| tab.slice("left", "right") }
      find("[data-testid='side-panel-tab-transcript']").click
      3.times { |i| deliver(post_as_speaker("Pendant la transcription #{i + 1}")) }
      assert_selector "[data-testid='side-panel-tab-discussion'] [data-testid='unread-badge']", exact_text: "3"

      assert_side_panel_header_clear(width)
      after = evaluate_script(SidePanelGeometry::HEADER_JS)["tabs"].map { |tab| tab.slice("left", "right") }
      assert_equal before, after, "la pastille déplace les onglets à #{width} px"
    end
  end

  test "diffusion en panne : message enregistré et avis affiché ; envoi refusé : raison affichée, brouillon conservé" do
    open_viewer_room(1400, 900)
    @room.offline = true
    send_message("Envoyé sans temps réel")
    assert_selector "[data-message-id]", text: "Envoyé sans temps réel"
    assert_text "Message enregistré ; diffusion en direct indisponible"

    @webinar.update!(state: "ended")
    send_message("Une dernière question ?")
    assert_text "Le direct est terminé : la discussion est close. Votre texte est conservé."
    assert_equal "Une dernière question ?", find("#lk-discussion-draft").value
  end

  test "intervenant (/join) : écrit sous son nom, sans panneau de modération" do
    speaker = @webinar.speakers.create!(name: "Basile Delmas")
    # Accord à l'image déjà donné (participant_consent_test couvre la fenêtre).
    ParticipantConsent.grant!(speaker, recording: true, excerpts: false, adult: true)
    resize(1400, 900)
    visit join_webinar_path(slug: @webinar.slug, t: speaker.token)
    join_stage
    send_message("Je partage mon écran dans une minute")

    assert_selector "[data-message-id]", text: "Basile Delmas"
    assert_selector "[data-message-id]", text: /intervenant/i
    assert_no_selector "[data-testid='questions-panel']"
    assert_no_button "Ajouter à la file"
  end

  VIEWPORTS.each do |width, height|
    test "discussion ouverte à #{width} px, spectateur et animation : rien ne défile, la saisie reste cliquable" do
      12.times { |i| @webinar.messages.create!(author_identity: "viewer-7", name: "Bob", body: "Un message assez long pour passer à la ligne, numéro #{i + 1}") }

      open_viewer_room(width, height, collapsed: false)
      assert_discussion_usable(width, ".lk-viewer")

      @webinar.messages.create!(author_identity: "viewer-8", name: "Claire", body: "@animateur Une question ?")
      open_stage(width, height, collapsed: false)
      assert_discussion_usable(width, "[data-testid='stage']", count: 13)
      # Salle animateur = salle participant : la file des questions est dans la régie.
      assert_no_selector "[data-testid='questions-panel']"
    end
  end

  private

  def in_browser(name, &block)
    using_session(name, &block)
  end

  def resize(width, height)
    Capybara.current_session.current_window.resize_to(width, height)
  end

  # Préférences du panneau effacées (onglet Discussion par défaut) ;
  # `collapsed: false` force le panneau ouvert, même sur petit écran.
  def reset_panel_preferences(collapsed)
    script = "localStorage.removeItem('undust-live:side-panel:tab');"
    script += collapsed.nil? ? "localStorage.removeItem('undust-live:side-panel:collapsed');" : "localStorage.setItem('undust-live:side-panel:collapsed', '#{collapsed ? 1 : 0}');"
    execute_script(script)
  end

  def open_viewer_room(width, height, collapsed: nil)
    resize(width, height)
    confirm_viewer_registration(@webinar)
    reset_panel_preferences(collapsed)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "[data-testid='side-panel']", wait: 10
  end

  def open_stage(width, height, collapsed: nil)
    resize(width, height)
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)
    join_stage(collapsed)
  end

  def open_regie
    resize(1400, 900)
    sign_in_as(@host)
    visit webinar_regie_path(@webinar)
    assert_selector "[data-testid='regie-discussion'] [data-testid='discussion']", wait: 10
  end

  def join_stage(collapsed = nil)
    assert_selector "[data-testid='prejoin']", wait: 10
    reset_panel_preferences(collapsed)
    fill_in "username", with: "Marc"
    find(".lk-join-button:not([disabled])", wait: 10).click
    assert_selector "[data-testid='stage']", wait: 10
  end

  # Frappe réelle, touche par touche (`rapid: false`). Au-delà de 30
  # caractères, Capybara n'en tape que le début et la fin et AJOUTE le milieu
  # en JavaScript, sans événement `input` : React l'ignore, et le moindre
  # re-rendu du champ contrôlé (message reçu, poll) le retire — « <img1"> »
  # envoyé au lieu du texte saisi (vu en CI). Une vraie frappe ou un
  # collage émettent toujours `input` : rien ne se perd (vérifié).
  def send_message(text)
    fill_in "Votre message", with: text, fill_options: { rapid: false }
    click_on "Envoyer"
  end

  def post_as_speaker(body)
    @webinar.messages.create!(author_identity: "speaker-1", name: "Basile", body: body)
  end

  def envelope(message)
    { topic: MessageBroadcast::TOPIC, message: message.public_attributes }.to_json
  end

  def deliver(message)
    assert deliver_packet(envelope(message)), "Room LiveKit introuvable"
  end

  # Tous les paquets diffusés par le serveur jusqu'ici, dans l'ordre.
  def deliver_broadcasts
    @room.packets.each do |data|
      assert deliver_packet(data), "Room LiveKit introuvable"
    end
  end

  def assert_discussion_usable(width, container, count: 12)
    assert_selector "[data-message-id]", count: count
    overflow = evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(#{container.to_json});
        const panel = document.querySelector('[data-testid="side-panel"]');
        return [document.documentElement.scrollHeight - window.innerHeight,
                document.documentElement.scrollWidth - document.documentElement.clientWidth,
                el.scrollHeight - el.clientHeight, panel.scrollHeight - panel.clientHeight];
      })()
    JS
    assert_equal [ 0, 0, 0, 0 ], overflow.map { |v| [ v, 0 ].max }, "défilement à #{width} px (page, salle, panneau : #{overflow.inspect})"

    %w[#lk-discussion-draft .lk-discussion__send].each do |selector|
      hit = evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector(#{selector.to_json});
          const r = el.getBoundingClientRect();
          const target = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          return { clickable: !!target && (target === el || el.contains(target)),
                   inside: r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight && r.height > 0 };
        })()
      JS
      assert hit["inside"], "#{selector} hors de l'écran à #{width} px"
      assert hit["clickable"], "#{selector} recouvert à #{width} px"
    end
  end
end
