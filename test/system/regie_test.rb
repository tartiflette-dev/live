require "application_system_test_case"

# Régie du direct :
# la salle de l'animation est celle des participants, les commandes sont
# dans un autre onglet, sans vidéo : démarrer / terminer le direct,
# enregistrement, mains levées, mise en avant, discussion.
#
# Le vrai composant, les vrais endpoints. LiveKit est remplacé côté serveur
# par FakeRoomService (lecture de la salle par RoomSnapshot, écriture de la
# mise en avant) ; la régie ne touche jamais LiveKit depuis le navigateur.
# Les tests propres à chaque bloc repris de la salle vivent avec leur
# composant : end_live_confirmation_test (fin en deux temps),
# regie_recording_control_states_test (enregistrement), hand_raises_room_test
# (mains levées), room_chat_test (modération).
class RegieTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  # Texte brut d'un egress composite avorté, tel que le serveur le remonte :
  # long, technique, sur plusieurs lignes une fois déplié.
  RAW_EGRESS_ERROR = "Start signal not received: twirp error deadline_exceeded: room composite web page did not " \
                     "start within 15s [chrome] exited with status 1 [gst] pipeline state change PLAYING failed " \
                     "(source closed) [egress] EG_testRegie001 aborted before any segment was written to disk".freeze

  # Salle LiveKit vue par le serveur. Partagée avec le serveur Capybara
  # (même processus, autre thread) : état sous verrou.
  class FakeRoomService
    def initialize
      @lock = Mutex.new
      @metadata = ""
      @participants = []
      @metadata_writes = []
      @offline = false
    end

    def participants=(list)
      @lock.synchronize { @participants = list }
    end

    def offline! = @lock.synchronize { @offline = true }
    def metadata_writes = @lock.synchronize { @metadata_writes.dup }

    def room_metadata(room:)
      @lock.synchronize do
        raise RoomServiceClient::Error, "LiveKit injoignable (test)" if @offline

        @metadata
      end
    end

    def list_participants(room:)
      @lock.synchronize do
        raise RoomServiceClient::Error, "LiveKit injoignable (test)" if @offline

        @participants
      end
    end

    def list_agent_dispatches(room:) = []

    def update_room_metadata(room:, metadata:)
      @lock.synchronize do
        @metadata_writes << metadata
        @metadata = JSON.generate(metadata)
      end
      {}
    end

    def create_room(**) = {}
    def remove_participant(**) = {}
  end

  class ActiveEgress
    def start_room_composite(**) = { egress_id: "EG_#{SecureRandom.hex(3)}", status: :active, raw: nil }
    def stop(egress_id:) = { egress_id: egress_id, status: :ending, raw: nil }
    def list_egress(egress_id:) = { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
  end

  def self.person(identity, name, can_publish:, sources: [])
    { identity: identity, kind: "STANDARD", name: name, permission: { can_publish: can_publish },
      tracks: sources.map { |source| { sid: "TR_#{identity}_#{source}", source: source } } }
  end

  ROOM = [
    person("host-sub-marc", "Marc", can_publish: true, sources: %w[CAMERA MICROPHONE]),
    person("speaker-basile", "Basile Delmas", can_publish: true, sources: %w[CAMERA]),
    person("viewer-1", "Spectatrice", can_publish: false),
    person("viewer-2", "Spectateur", can_publish: false),
    { identity: "agent-AJ_x", kind: "AGENT", name: "", permission: { can_publish: true }, tracks: [] }
  ].freeze

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(title: "Café IA #8", starts_at: 1.hour.from_now, host_sub: @host.oidc_sub,
                               visibility: "published")
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    @room = FakeRoomService.new
    @room.participants = ROOM
    @saved_factories = [ Rails.configuration.x.room_service_client_factory, Rails.configuration.x.egress_client_factory ]
    room = @room
    egress = ActiveEgress.new
    Rails.configuration.x.room_service_client_factory = -> { room }
    Rails.configuration.x.egress_client_factory       = -> { egress }
    sign_in_host
  end

  teardown do
    Rails.configuration.x.room_service_client_factory, Rails.configuration.x.egress_client_factory = @saved_factories
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @saved_env[k] }
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
    Capybara.current_session.current_window.resize_to(1400, 900)
  end

  test "état du direct, présents, lien vers la salle ; démarre puis termine le direct, sans jamais rejoindre la salle" do
    visit webinar_regie_path(@webinar)

    assert_selector "[data-testid='regie-state'][data-state='draft']", text: /\Ahors antenne\z/i
    assert_selector "[data-testid='regie-present']", exact_text: "4 présents", wait: 10
    assert_no_selector "[data-testid='regie-clock']"
    assert_selector "a[data-testid='regie-open-room'][target='_blank'][href='#{stage_webinar_path(slug: @webinar.slug)}']",
                    text: "Ouvrir la salle"
    assert_selector "a[data-testid='regie-open-room'] [aria-hidden='true']", text: "↗"
    assert_selector "a[data-testid='regie-open-room'] .visually-hidden", text: "(nouvel onglet)", visible: :all
    %w[regie-recording regie-spotlight-section regie-hands regie-polls regie-qa regie-discussion].each do |section|
      assert_selector "[data-testid='#{section}']"
    end

    click_on "Démarrer le direct"
    assert_selector "[data-testid='regie-state'][data-state='live']", text: /\Aen direct\z/i, wait: 10
    assert_equal "live", @webinar.reload.state
    assert_selector "[data-testid='regie-clock']", text: /\A0:00:0\d\z/, wait: 10
    assert_selector "[data-testid='recording-control'][data-state='recording']", wait: 10

    click_on "Terminer le direct"
    assert_equal "live", @webinar.reload.state, "un seul clic a terminé le direct"
    sleep 0.6 # au-delà de la garde anti double-clic (500 ms)
    click_on "Confirmer la fin du direct\u00a0?"
    assert_selector "[data-testid='regie-state'][data-state='ended']", text: /\Aterminé\z/i, wait: 10
    assert_selector "[data-testid='state-button']", exact_text: "Reprendre le direct"
    assert_equal "ended", @webinar.reload.state

    # Aucun flux, aucune salle LiveKit dans la page.
    assert_no_selector "video", visible: :all
    assert_no_selector "#livekit-room, .lk-room-container, [data-lk-theme]", visible: :all
  end

  test "un changement d'état venu d'ailleurs (autre animateur, fin automatique) s'impose à la régie" do
    @webinar.update!(state: "live", started_at: 3.minutes.ago)
    visit webinar_regie_path(@webinar)
    assert_selector "[data-testid='regie-clock']", text: /\A0:0[34]:\d\d\z/

    @webinar.update!(state: "ended", ended_at: Time.current)

    assert_selector "[data-testid='regie-state'][data-state='ended']", wait: 10
    assert_selector "[data-testid='state-button']", exact_text: "Reprendre le direct"
  end

  test "mise en avant : la régie demande, le serveur écrit la salle, la liste suit ; retour à la mosaïque" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    visit webinar_regie_path(@webinar)
    open_fold("regie-spotlight-section")

    within("[data-testid='regie-spotlight']") do
      assert_selector "[data-testid='regie-stage-person']", count: 2, wait: 10
      assert_no_text "Spectatrice"
      assert_no_text "agent-AJ"
      assert_selector "[data-testid='regie-spotlight-clear'][disabled]"

      find("button[aria-label='Mettre en avant : Basile Delmas']").click
      assert_selector "[data-testid='regie-stage-person'][data-featured='true']", text: "Basile Delmas", wait: 10
      assert_selector "button[aria-pressed='true']", exact_text: "Retirer la mise en avant"
    end
    assert_equal [ { spotlight: "speaker-basile" } ], @room.metadata_writes

    within("[data-testid='regie-spotlight-section'] summary") { assert_text "Basile Delmas en avant", wait: 10 }

    click_on "Revenir à la mosaïque"
    assert_no_selector "[data-testid='regie-stage-person'][data-featured='true']", wait: 10
    within("[data-testid='regie-spotlight-section'] summary") { assert_text "mosaïque", wait: 10 }
    assert_equal [ { spotlight: "speaker-basile" }, { spotlight: nil } ], @room.metadata_writes
  end

  # Onglet masqué, la régie ne relit plus
  # son état toutes les 5 s ni le plan des sondages toutes les 2 s ; au
  # retour, elle relit les deux tout de suite.
  test "onglet masqué : plus de relecture de l'état ni des sondages, relecture immédiate au retour" do
    visit webinar_regie_path(@webinar)
    assert_selector "[data-testid='regie-present']", exact_text: "4 présents", wait: 10
    execute_script(<<~JS)
      window.__statusReads = 0;
      window.__pollReads = 0;
      const fetch0 = window.fetch;
      window.fetch = (url, ...rest) => {
        if (String(url).includes("/regie/status")) window.__statusReads += 1;
        if (String(url).endsWith("/polls")) window.__pollReads += 1;
        return fetch0(url, ...rest);
      };
      window.__hidden = true;
      Object.defineProperty(document, "hidden", { configurable: true, get: () => window.__hidden });
      document.dispatchEvent(new Event("visibilitychange"));
    JS

    sleep 6
    assert_equal 0, evaluate_script("window.__statusReads"), "relecture de l'état alors que l'onglet est masqué"
    assert_equal 0, evaluate_script("window.__pollReads"), "relecture des sondages alors que l'onglet est masqué"

    execute_script('window.__hidden = false; document.dispatchEvent(new Event("visibilitychange"));')
    sleep 0.5
    assert_equal 1, evaluate_script("window.__statusReads"), "pas de relecture immédiate de l'état au retour sur l'onglet"
    assert_equal 1, evaluate_script("window.__pollReads"), "pas de relecture immédiate des sondages au retour sur l'onglet"
  end

  test "partage d'écran en cours : signalé comme plein cadre pour tous" do
    @room.participants = ROOM + [ self.class.person("speaker-tristan", "Tristan Lemaire", can_publish: true, sources: %w[CAMERA SCREEN_SHARE]) ]
    visit webinar_regie_path(@webinar)

    within("[data-testid='regie-spotlight-section'] summary") { assert_text "partage d'écran en cours", wait: 10 }
    open_fold("regie-spotlight-section")
    assert_selector "[data-testid='regie-screen-share']", text: "Partage d'écran de Tristan Lemaire", wait: 10
  end

  # Sans accord à l'image, la salle ne laisse pas
  # publier l'intervenant ; la régie le montre quand même sur scène, en
  # attente d'accord, et peut le mettre en avant.
  test "intervenant arrivé sans accord à l'image : sur scène en attente d'accord, et mis en avant" do
    @room.participants = ROOM + [ self.class.person("speaker-mathilde", "Mathilde Courtois", can_publish: false) ]
    visit webinar_regie_path(@webinar)
    open_fold("regie-spotlight-section")

    within("[data-testid='regie-spotlight']") do
      person = find("[data-testid='regie-stage-person']", text: "Mathilde Courtois", wait: 10)
      assert_equal "en attente d'accord", person.find("[data-testid='regie-awaiting-consent']")[:textContent]
      assert_no_text "Spectatrice"
      find("button[aria-label='Mettre en avant : Mathilde Courtois']").click
      assert_selector "[data-testid='regie-stage-person'][data-featured='true']", text: "Mathilde Courtois", wait: 10
    end
    assert_equal [ { spotlight: "speaker-mathilde" } ], @room.metadata_writes
  end

  # Transcripteur absent d'une salle occupée au-delà de 3 min
  # (Webinar::TranscriptionOutage) : l'animation le lit dans la régie,
  # discret, au filet d'attention, lisible sur téléphone (320-412 px) ; le
  # bandeau disparaît au retour du transcripteur.
  test "transcription interrompue : bandeau daté en H:MM, lisible sur téléphone, retiré au retour du transcripteur" do
    @webinar.update!(state: "live", started_at: 20.minutes.ago)
    @webinar.transcriber_observed!(:dispatched, at: Time.zone.parse("2026-11-10 09:05"))
    @webinar.transcriber_observed!(:pending, at: Time.zone.parse("2026-11-10 09:08"))

    [ [ 320, 640 ], [ 412, 915 ] ].each do |width, height|
      Capybara.current_session.current_window.resize_to(width, height)
      visit webinar_regie_path(@webinar)
      notice = find("[data-testid='regie-transcription-interrupted'][role='status']", wait: 10)
      assert_equal "Transcription en direct interrompue depuis 9:05 — l'équipe est prévenue", notice.text

      m = evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector("[data-testid='regie-transcription-interrupted']");
          const box = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          return { viewport: window.innerWidth, right: box.right, left: box.left, clipped: el.scrollWidth - el.clientWidth,
                   fontSize: parseFloat(style.fontSize), border: style.borderLeftStyle, background: style.backgroundColor };
        })()
      JS
      assert_equal width, m["viewport"], "fenêtre non redimensionnée"
      assert_operator m["left"], :>=, 0, "bandeau hors écran à #{width} px"
      assert_operator m["right"], :<=, width, "bandeau déborde à #{width} px"
      assert_operator m["clipped"], :<=, 0, "texte du bandeau coupé à #{width} px"
      assert_operator m["fontSize"], :>=, 12, "bandeau illisible à #{width} px"
      assert_equal "solid", m["border"], "filet d'attention attendu"
      assert_equal "rgba(0, 0, 0, 0)", m["background"], "discret : pas d'aplat"
    end

    @webinar.transcriber_observed!(:present)
    assert_no_selector "[data-testid='regie-transcription-interrupted']", wait: 10
  end

  test "transcription en place : aucun bandeau" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    visit webinar_regie_path(@webinar)

    assert_selector "[data-testid='regie-present']", exact_text: "4 présents", wait: 10
    assert_no_selector "[data-testid='regie-transcription-interrupted']"
  end

  # Cas observé en direct : caméra émise en 320x180 tout le direct sans que la
  # régie le sache. Les mesures arrivent du navigateur de l'intervenant
  # (CameraSample).
  test "caméras : une caméra sous 720p depuis plus de 15 s s'affiche avec raison et encodeur, puis disparaît au retour en 720p" do
    @webinar.update!(state: "live", started_at: 5.minutes.ago)
    now = Time.current
    [ 25, 15, 5 ].each do |seconds_ago|
      @webinar.camera_samples.create!(participant_identity: "speaker-basile", top_width: 320, top_height: 180,
                                      quality_limitation_reason: "none", encoder_implementation: "ExternalEncoder",
                                      capture_width: 1280, capture_height: 720, created_at: now - seconds_ago.seconds)
    end
    @webinar.camera_samples.create!(participant_identity: "speaker-basile", event: "simulcast_fallback",
                                    top_width: 320, top_height: 180, quality_limitation_reason: "none",
                                    encoder_implementation: "ExternalEncoder", capture_width: 1280, capture_height: 720,
                                    created_at: now - 4.seconds)
    visit webinar_regie_path(@webinar)

    # Pendant le direct, le bloc est ouvert (rangement par moment).
    assert_selector "section[data-testid='regie-cameras-section']", wait: 10
    within("[data-testid='regie-cameras']") do
      alert = find("[data-testid='regie-camera-alert'][data-identity='speaker-basile']", wait: 10)
      assert_includes alert.text, "Caméra de Basile Delmas émise en 320×180 depuis"
      assert_includes alert.text, "aucune limite signalée : encodeur ou capture"
      assert_includes alert.text, "capture 1280×720"
      assert_includes alert.text, "encodeur ExternalEncoder"
      assert_selector "[data-testid='regie-camera-fallback']", text: "Caméra de Basile Delmas republiée sans simulcast en 720p"
      # Caméra de l'animation publiée sans aucune mesure : signalée, jamais tenue pour bonne.
      assert_selector "[data-testid='regie-cameras-unmeasured']", text: "Non mesurée : Marc."

      @webinar.camera_samples.create!(participant_identity: "speaker-basile", top_width: 1280, top_height: 720,
                                      created_at: Time.current)
      assert_selector "[data-testid='regie-cameras-ok']", text: "Aucune caméra émise sous 720p.", wait: 10
      assert_no_selector "[data-testid='regie-camera-alert']"
    end
  end

  test "caméras hors direct : bloc replié, rien n'est attendu, ni alerte ni caméra « non mesurée »" do
    visit webinar_regie_path(@webinar)

    assert_selector "details[data-testid='regie-cameras-section']:not([open])", wait: 10
    find("[data-testid='regie-cameras-section'] summary").click
    within("[data-testid='regie-cameras-section']") do
      assert_selector "[data-testid='regie-cameras-off-air']", text: "Caméras mesurées pendant le direct seulement.", wait: 10
      assert_no_selector "[data-testid='regie-cameras-unmeasured']"
    end
  end

  test "LiveKit injoignable : la régie le dit, les commandes du direct restent" do
    @room.offline!
    visit webinar_regie_path(@webinar)

    assert_selector "[data-testid='regie-present']", exact_text: "Salle LiveKit injoignable", wait: 10
    open_fold("regie-spotlight-section")
    assert_selector "[data-testid='regie-spotlight-section'] [role='alert']", text: "mise en avant est indisponible"
    assert_selector "[data-testid='state-button']", exact_text: "Démarrer le direct"
  end

  test "échec de la vue d'ensemble, pistes en cours : statut court, détail replié" do
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    @webinar.recordings.create!(kind: :composite, status: :failed, started_at: 1.minute.ago,
                                ended_at: Time.current, error_message: RAW_EGRESS_ERROR)
    # Pistes d'un intervenant qui a donné son accord à l'image : sans lui, la
    # réconciliation du statut les arrêterait.
    speaker = @webinar.speakers.create!(name: "Basile")
    ParticipantConsent.grant!(speaker, recording: true, excerpts: false, adult: true)
    %w[camera microphone].each do |source|
      @webinar.recordings.create!(kind: :track, status: :recording, egress_id: "EG_#{source}", track_sid: "TR_#{source}",
                                  participant_identity: "speaker-#{speaker.id}", track_source: source,
                                  output_prefix: "#{@webinar.slug}/#{source}", started_at: 1.minute.ago)
    end
    visit webinar_regie_path(@webinar)

    within "[data-testid='recording-error']" do
      assert_text "Vue d'ensemble en échec, pistes individuelles en cours.", wait: 10
      assert_no_text "Start signal"
    end
    assert_no_selector "[data-testid='recording-error-details'][open]"
    find("[data-testid='recording-error-details'] summary").click
    assert_text "Start signal not received"
  end

  # Charte sous le chrome undust : « Terminer le direct » au
  # filet critique, jamais en aplat rouge, contraste AA ; cibles
  # tactiles de 44 px, actions de la discussion comprises ; rien ne déborde
  # en largeur. Une colonne au téléphone et sur un demi-écran de portable
  # (720 px), deux sur un écran de bureau comme sur un écran large.
  [ [ 360, 780, 1 ], [ 720, 900, 1 ], [ 1400, 900, 2 ], [ 3440, 1440, 2 ] ].each do |width, height, columns|
    test "mise en page à #{width} px : #{columns} colonne(s), boutons lisibles, rien ne déborde" do
      @webinar.update!(state: "live", started_at: 1.minute.ago)
      @webinar.messages.create!(author_identity: "viewer-1", name: "Alice", body: "Bonjour")
      Capybara.current_session.current_window.resize_to(width, height)
      visit webinar_regie_path(@webinar)
      open_fold("regie-spotlight-section")
      assert_selector "[data-testid='regie-stage-person']", count: 2, wait: 10
      assert_selector "[data-testid='discussion-enqueue']", wait: 10

      m = evaluate_script(<<~JS)
        (() => {
          const lum = (rgb) => { const c = rgb.match(/[\\d.]+/g).slice(0, 3).map(Number).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
          const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
          const end = getComputedStyle(document.querySelector("[data-testid='state-button']"));
          const header = getComputedStyle(document.querySelector("[data-testid='regie-header']"));
          const columns = new Set(Array.from(document.querySelectorAll('#regie .regie-bloc')).map((c) => Math.round(c.getBoundingClientRect().left)));
          return {
            endBg: end.backgroundColor, endContrast: ratio(end.color, header.backgroundColor),
            buttonHeights: Array.from(document.querySelectorAll('#regie button')).filter((b) => b.getBoundingClientRect().width > 0)
              .map((b) => Math.round(b.getBoundingClientRect().height)),
            overflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth,
            columns: columns.size
          };
        })()
      JS
      assert_equal "rgba(0, 0, 0, 0)", m["endBg"], "« Terminer le direct » en aplat (#{m['endBg']})"
      assert_operator m["endContrast"], :>=, 4.5, "« Terminer le direct » : contraste #{m['endContrast'].round(2)}:1"
      assert_operator m["buttonHeights"].min, :>=, 44, "bouton sous 44 px à #{width} px (#{m['buttonHeights'].inspect})"
      assert_operator m["overflowX"], :<=, 0, "la régie déborde en largeur à #{width} px"
      assert_equal columns, m["columns"], "colonnes à #{width} px"
    end
  end

  test "inscrits : présents dans la salle, venus puis repartis, absents ; la liste suit la salle" do
    ana = @webinar.registrations.create!(name: "Ana Présente", email: "ana@example.test", confirmed_at: 1.day.ago)
    bea = @webinar.registrations.create!(name: "Béa Repartie", email: "bea@example.test", confirmed_at: 1.day.ago,
                                         room_joined_at: 20.minutes.ago)
    @webinar.registrations.create!(name: "Céline Absente", email: "celine@example.test", confirmed_at: 1.day.ago,
                                   participation: "participant")
    @room.participants = [ self.class.person("host-sub-marc", "Marc", can_publish: true),
                           self.class.person("viewer-#{ana.id}", "Ana Présente", can_publish: false) ]

    visit webinar_regie_path(@webinar)

    within "[data-testid='regie-registrations-section']" do
      assert_selector "[data-testid='regie-registrations-count']", text: "1 présent sur 3 inscrits · 2 venus dans la salle au total", wait: 10
      rows = all("[data-testid='regie-registration']")
      assert_equal [ "present", "left", "absent" ], rows.map { |row| row["data-status"] }
      assert_text "Ana Présente"
      assert_selector "[data-status='left'] [data-testid='regie-registration-status']", text: /venu, reparti/i
      assert_selector "[data-status='absent']", text: /veut intervenir/i
      # Aucun badge à pictogramme « i » (lu comme une lettre sur téléphone).
      assert_no_selector ".etat--info"
      assert_no_selector "[data-status='absent'] .etat"
      # Présence en salle : lien vers la page Présence, dans un autre onglet.
      link = find("[data-testid='regie-room-presence-link']")
      assert_equal webinar_room_presence_path(@webinar), URI(link[:href]).path
      assert_equal "_blank", link[:target]
    end

    # Ana quitte la salle, Béa revient : la régie le montre au tour suivant.
    @room.participants = [ self.class.person("viewer-#{bea.id}", "Béa Repartie", can_publish: false) ]
    Rails.cache.clear
    within "[data-testid='regie-registrations-section']" do
      assert_selector "[data-status='present']", text: "Béa Repartie", wait: 12
      assert_selector "[data-status='left']", text: "Ana Présente"
    end
  end

  private

  # Ouvre un bloc secondaire replié (RegieFold) par son titre, comme un humain.
  def open_fold(testid)
    summary = find("[data-testid='#{testid}'] > summary", wait: 10)
    scroll_to(summary, align: :center) # jamais sous la bande basse fixe du chrome
    summary.click
    assert_selector "[data-testid='#{testid}'][open]"
  end

  def sign_in_host
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: @host.oidc_sub, info: { email: @host.email }
    )
    visit "/auth/pocket_id/callback"
  end
end
