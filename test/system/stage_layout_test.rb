require "application_system_test_case"

# Mise en page de la scène animateur :
#   - tout tassé sur une rangée en haut de l'écran (vignettes de 260 px,
#     barre animateur et barre de contrôle côte à côte) ;
#   - panneau transcription posé SUR la barre de contrôle : « Masquer »
#     recouvrait « Leave », le chevron du menu caméra passait dessous, les
#     clics étaient interceptés (l'animateur n'a pu ni choisir sa caméra virtuelle
#     OBS ni partager son écran) ;
#   - barre animateur en surimpression sur le micro (mesuré sur une instance
#     réelle : elementFromPoint au centre de « Microphone » = « Démarrer le
#     direct ») ;
#   - transcripteur `agent-AJ_…` affiché comme un orateur ;
#   - contrôles en anglais.
#
# Retours suivants (test réel avec Basile) : tuiles qui grossissent sans
# borne dès que la vidéo arrive (page qui défile, visages recadrés), sortie
# ffmpeg brute en rouge dans la barre animateur, tuile avatar de l'agent
# sous la ligne de flottaison, barre animateur sur le bouton ⤢ des tuiles.
#
# Critère d'acceptation principal : la scène tient ENTIÈREMENT dans
# la fenêtre, quelle que soit sa taille — aucun défilement, tuiles
# bornées, barres visibles. Ce test le verrouille de 360 px au plein écran
# 2000 px : rien ne défile (page ni scène), chaque contrôle est visible et
# cliquable SANS défilement (elementFromPoint au centre = le bouton), le
# menu caméra s'ouvre dans l'écran, les tuiles restent dans leur zone même
# avec une vidéo portrait 720×1280, la transcription est un panneau
# latéral qui ne chevauche rien et rend la largeur une fois masqué, aucune
# tuile ni aucun compte pour un agent.
#
# Mosaïque automatique, fenêtre
# d'environ 1000×550, trois caméras : la grille vendor les rangeait en
# 2×2, une case vide, des vidéos de ~170 px au milieu de tuiles de 440×95
# (« ici il faudrait 3 colonnes ; soit ça se met automatiquement soit on
# choisit le type de mosaïque »). Verrouillé ici : trois colonnes d'office
# dans une fenêtre large et basse, tuiles 16:9 jamais sous le sélecteur,
# choix manuel appliqué et mémorisé sur l'appareil. Le calcul lui-même est
# testé en unitaire (test/javascript/mosaic_layout_test.rb).
#
# Cas observé en direct :
# fenêtre en tuile Hyprland d'environ 846×1270 : « Masquer » posé sur
# l'onglet « Transcription » (aussi à 1000 et 1280 px : panneau de 16 rem
# trop étroit pour deux onglets et le bouton), vidéo coincée à côté du
# panneau dans ~540 px de large (vignette 16:9 au milieu d'un grand vide),
# champ de saisie à barre de défilement sur un texte indicatif de deux
# lignes. Verrouillé ici, à chaque taille et panneau OUVERT (il est replié
# d'office sous 768 px : le test l'ouvre) : en-tête sans chevauchement ni
# onglet rogné, saisie vide sans défilement, rien ne défile ; panneau SOUS
# la vidéo dans une fenêtre en hauteur jusqu'à 1024 px, à côté au-delà et
# dans les fenêtres basses. L'en-tête avec une pastille de non-lus réelle
# est vérifié dans room_chat_test (flux de discussion simulé).
#
# La CI n'a pas de serveur LiveKit (livekit.invalid, comme les autres
# tests salle) : la connexion échoue, la scène est rendue quand même. Pour
# exercer les vrais composants avec des participants, le test retrouve la
# Room LiveKit de la page (contexte React) une fois la connexion échouée,
# accorde la publication au participant local (sinon les contrôles média
# ne s'affichent pas) et y ajoute des participants distants réels
# (classe Participant de livekit-client) : un agent, un intervenant, un
# spectateur. Le code de production n'expose rien pour le test.
class StageLayoutTest < JsSystemTestCase
  include LivekitRoomRecipe
  include SidePanelGeometry

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  # [largeur, hauteur] de fenêtre : téléphone, tablette, fenêtre de bureau
  # d'animateur, fenêtre basse (captures 1700 px), plein écran.
  VIEWPORTS = [ [ 360, 780 ], [ 768, 1024 ], [ 1220, 1270 ], [ 1700, 900 ], [ 2000, 1100 ] ].freeze

  # Page (zone d'affichage, comme une capture) d'un animateur en direct :
  # fenêtre large et basse. La scène y passe les mêmes vérifications.
  CAFE_IA_7_PAGE = [ 1000, 550 ].freeze
  # Page d'un animateur en direct : fenêtre en hauteur (tuile Hyprland).
  CAFE_IA_8_PAGE = [ 846, 1270 ].freeze
  STAGE_SIZES = VIEWPORTS.map { |width, height| [ width, height, :window ] } +
                [ [ *CAFE_IA_7_PAGE, :page ], [ *CAFE_IA_8_PAGE, :page ] ]

  MOSAIC_MODE_KEY = "undust-live:mosaic-mode".freeze

  CONTROLS = {
    "Micro"            => "[data-lk-source='microphone']",
    "menu micro"       => "[aria-label='Choisir le micro']",
    "Caméra"           => "[data-lk-source='camera']",
    "menu caméra"      => "[aria-label='Choisir la caméra']",
    "Partager l'écran" => "[data-lk-source='screen_share']",
    "Quitter"          => ".lk-disconnect-button"
  }.freeze

  # Publication accordée au local + participants distants : un agent, un
  # intervenant, une spectatrice, et les intervenants supplémentaires
  # (`EXTRA_SPEAKERS`, [identité, nom]). N'agit qu'une fois la connexion
  # échouée : une déconnexion ultérieure viderait les participants ajoutés.
  POPULATE_ROOM_JS = <<~JS.freeze
    #{FIND_ROOM_JS}
    if (!room) return 'room introuvable';
    if (room.state !== 'disconnected') return 'connexion en cours : ' + room.state;
    const grant = (canPublish) => ({ canPublish, canSubscribe: true, canPublishData: true,
                                     canPublishSources: [], hidden: false, agent: false });
    const local = room.localParticipant;
    local.permissions = grant(true);
    local.emit('participantPermissionsChanged', undefined);
    const Participant = Object.getPrototypeOf(Object.getPrototypeOf(local)).constructor;
    const AGENT = 4, STANDARD = 0;
    [['agent-AJ_testAgent001', 'agent-AJ_testAgent001', AGENT, true],
     ['speaker-basile', 'Basile Delmas', STANDARD, true],
     ['viewer-1', 'Spectatrice', STANDARD, false],
     ...EXTRA_SPEAKERS.map(([identity, name]) => [identity, name, STANDARD, true])].forEach(([identity, name, kind, canPublish]) => {
      const participant = new Participant('PA_' + identity, identity, name, '', {}, undefined, kind);
      participant.permissions = grant(canPublish);
      room.remoteParticipants.set(identity, participant);
      room.emit('participantConnected', participant);
    });
    return 'ok';
  JS

  BOX_JS = <<~JS.freeze
    const box = (sel) => { const el = document.querySelector(sel); if (!el) return null;
      const r = el.getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; };
  JS

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(title: "Café IA #7", starts_at: 1.day.from_now, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL", "TRANSCRIPT_ENABLED")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    ENV["TRANSCRIPT_ENABLED"] = "true"
  end

  teardown do
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL TRANSCRIPT_ENABLED].each { |k| ENV[k] = @saved_env[k] }
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
    Capybara.current_session.current_window.resize_to(1400, 900)
  end

  STAGE_SIZES.each do |width, height, measured|
    test "scène animateur à #{width} px : contrôles cliquables, menu caméra lisible, rien ne se chevauche, pas de tuile agent" do
      resize(width, height, measured)
      sign_in_as(@host)
      visit stage_webinar_path(slug: @webinar.slug)
      join_stage
      populate_room
      play_portrait_video_in_speaker_tile

      assert_fits_window(width, "[data-testid='stage']")
      assert_all_controls_clickable(width)
      assert_camera_menu_readable
      assert_no_overlap("[data-testid='side-panel']", "[data-testid='room-controls']")
      assert_no_overlap("[data-testid='side-panel']", "[data-testid='stage-bar']")
      assert_no_overlap("[data-testid='stage-bar']", ".lk-stage__tiles")
      assert_controls_on_one_line(width)
      assert_tiles_bounded(width)
      assert_mosaic_clear_of_picker(width)
      assert_video_dominates

      assert_selector "[data-testid='stage'] .lk-participant-tile", count: 2
      assert_selector ".lk-participant-tile", text: "Basile Delmas"
      assert_no_selector ".lk-participant-tile", text: "agent-AJ"
      assert_no_text "agent-AJ"
      assert_selector "[data-testid='audience-count']", exact_text: "1 spectateur"
      assert_regie_link_clickable(width)
      assert_presentation_p0(width)

      # Panneau ouvert (replié d'office sous 768 px) : en-tête, saisie, et
      # la scène tient toujours dans la fenêtre.
      open_side_panel
      assert_side_panel_header_clear(width)
      assert_discussion_input_without_scrollbar(width)
      assert_fits_window(width, "[data-testid='stage']")
      assert_all_controls_clickable(width)
    end
  end

  # Fenêtre en hauteur (capture d'un direct) : le panneau passe sous la
  # vidéo, qui prend toute la largeur ; une fenêtre de bureau large
  # (1220×1270) ou basse (1000×550) garde les deux colonnes.
  { CAFE_IA_8_PAGE => :below, [ 1220, 1270 ] => :beside, CAFE_IA_7_PAGE => :beside }.each do |(width, height), placement|
    test "panneau latéral #{placement == :below ? 'sous' : 'à côté de'} la vidéo à #{width}×#{height}" do
      resize(width, height, :page)
      sign_in_as(@host)
      visit stage_webinar_path(slug: @webinar.slug)
      join_stage
      populate_room

      panel, tiles, viewport = evaluate_script("(() => { #{BOX_JS} return [box(\"[data-testid='side-panel']\"), box('.lk-stage__tiles'), window.innerWidth]; })()")
      refute_selector "[data-testid='side-panel'].lk-side-panel--collapsed"
      if placement == :below
        assert_operator panel["top"], :>=, tiles["bottom"], "panneau #{panel.inspect} pas sous la vidéo #{tiles.inspect}"
        assert_operator tiles["width"], :>=, viewport * 0.9, "vidéo de #{tiles['width'].round} px de large dans #{viewport} px"
      else
        assert_operator panel["left"], :>=, tiles["right"], "panneau #{panel.inspect} pas à côté de la vidéo #{tiles.inspect}"
      end
      assert_fits_window(width, "[data-testid='stage']")
      assert_side_panel_header_clear(width)
    end
  end

  # Audit UX : sur /join et /stage, l'écran PreJoin affichait
  # « Rejoindre la salle » et le champ nom comme du texte nu (variables
  # --lk-* absentes de l'enveloppe PreJoin → fond et accent transparents).
  # Mesuré sur le rendu : fond opaque, bordure du champ, contraste AA du
  # bouton, bouton cliquable sans défilement.
  PREJOIN_METRICS_JS = <<~JS.freeze
    (() => {
      const lum = (rgb) => { const c = rgb.match(/[\\d.]+/g).slice(0, 3).map(Number).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
      const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
      const button = document.querySelector('.lk-join-button');
      const input = document.querySelector("input[name='username']");
      const bs = getComputedStyle(button), is = getComputedStyle(input);
      const r = button.getBoundingClientRect();
      const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      return { buttonBg: bs.backgroundColor, buttonContrast: ratio(bs.color, bs.backgroundColor),
               inputBg: is.backgroundColor, inputBorder: is.borderTopWidth, inputBorderColor: is.borderTopColor,
               buttonFont: bs.fontFamily, inputFont: is.fontFamily, bodyFont: getComputedStyle(document.body).fontFamily,
               clickable: !!hit && (hit === button || button.contains(hit)),
               inside: r.left >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight };
    })()
  JS

  [ 360, 1220 ].each do |width|
    test "PreJoin à #{width} px : bouton et champ nom visibles (fond, bordure, contraste AA)" do
      speaker = @webinar.speakers.create!(name: "Tristan Lemaire")
      resize(width, 800)
      visit join_webinar_path(slug: @webinar.slug, t: speaker.token)
      assert_selector "[data-testid='prejoin']", wait: 10
      assert_selector ".lk-join-button", wait: 10
      m = evaluate_script(PREJOIN_METRICS_JS)
      refute_equal "rgba(0, 0, 0, 0)", m["buttonBg"], "bouton « Rejoindre la salle » sans fond"
      assert_operator m["buttonContrast"], :>=, 4.5, "contraste du bouton Rejoindre #{m['buttonContrast'].round(2)}:1 (< 4,5)"
      refute_equal "rgba(0, 0, 0, 0)", m["inputBg"], "champ nom sans fond"
      assert_equal "1px", m["inputBorder"], "champ nom sans bordure"
      refute_equal "rgba(0, 0, 0, 0)", m["inputBorderColor"], "bordure du champ nom transparente"
      assert_equal m["bodyFont"], m["buttonFont"], "PreJoin : le bouton perd la police de la charte (#{m['buttonFont']})"
      assert_equal m["bodyFont"], m["inputFont"], "PreJoin : le champ nom perd la police de la charte (#{m['inputFont']})"
      assert m["clickable"], "bouton Rejoindre recouvert à #{width} px"
      assert m["inside"], "bouton Rejoindre hors de l'écran à #{width} px"
      # Page (pas le wrapper) : les menus de périphériques du PreJoin sont
      # des popovers masqués (visibility: hidden) qui dépassent le wrapper de
      # 7 px à 360 px — invisibles, sans effet sur le défilement de la page
      # (question, cause mesurée).
      assert_fits_window(width, "main.lk-page")
    end
  end

  # L'animation voit la salle des
  # participants. Ni état du direct, ni bouton d'état, ni pilotage
  # d'enregistrement, ni file des mains levées, ni modération dans la salle ;
  # le lien « Régie ↗ » ouvre les commandes dans un autre onglet. Un
  # intervenant a la même scène, sans ce lien.
  test "salle animateur = salle intervenant : aucune commande d'animation, lien « Régie ↗ » vers un nouvel onglet" do
    @webinar.update!(state: "draft", started_at: nil)
    resize(1220, 800)
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)
    join_stage
    populate_room

    assert_selector "a[data-testid='regie-link'][target='_blank'][href='#{webinar_regie_path(@webinar)}']", text: "Régie"
    assert_selector "a[data-testid='regie-link'] [aria-hidden='true']", text: "↗"
    assert_selector "a[data-testid='regie-link'] .visually-hidden", text: "(nouvel onglet)", visible: :all
    %w[stage-status state-button recording-control hand-raise-host spotlight-toggle questions-panel].each do |testid|
      assert_no_selector "[data-testid='#{testid}']"
    end
    assert_no_button "Épingler"
    assert_selector "[data-testid='side-panel']"

    # Intervenant sans session animateur (un animateur connecté qui passe
    # par /join garde le lien, cf. webinars_controller_test).
    Capybara.reset_sessions!
    speaker = @webinar.speakers.create!(name: "Tristan Lemaire")
    visit join_webinar_path(slug: @webinar.slug, t: speaker.token)
    join_stage
    populate_room
    assert_selector "[data-testid='audience-count']"
    assert_no_selector "[data-testid='regie-link']"
    %w[stage-status state-button recording-control hand-raise-host spotlight-toggle questions-panel].each do |testid|
      assert_no_selector "[data-testid='#{testid}']"
    end
  end

  test "panneau latéral masqué : onglet étroit, la vidéo reprend la largeur, rien ne se chevauche" do
    resize(1700, 900)
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)
    join_stage
    populate_room
    open_width = evaluate_script("document.querySelector('.lk-stage__tiles').getBoundingClientRect().width")

    click_on "Masquer"
    assert_selector "[data-testid='side-panel'].lk-side-panel--collapsed"
    collapsed_width = evaluate_script("document.querySelector('.lk-stage__tiles').getBoundingClientRect().width")
    panel_width = evaluate_script("document.querySelector('[data-testid=\"side-panel\"]').getBoundingClientRect().width")
    assert_operator collapsed_width, :>, open_width + 200, "la vidéo ne reprend pas la largeur libérée"
    assert_operator panel_width, :<, 64, "panneau replié trop large (#{panel_width.round} px)"
    assert_fits_window(1700, "[data-testid='stage']")
    assert_all_controls_clickable(1700)
    assert_no_overlap("[data-testid='side-panel']", "[data-testid='room-controls']")
    click_on "Afficher"
    assert_no_selector ".lk-side-panel--collapsed"
  end

  test "vue intervenant (/join) : même scène, contrôles cliquables et transcription à part" do
    speaker = @webinar.speakers.create!(name: "Tristan Lemaire")
    # Accord à l'image déjà donné (participant_consent_test couvre la fenêtre).
    ParticipantConsent.grant!(speaker, recording: true, excerpts: false, adult: true)
    resize(1220, 1270)
    visit join_webinar_path(slug: @webinar.slug, t: speaker.token)
    join_stage
    populate_room

    assert_fits_window(1220, "[data-testid='stage']")
    assert_all_controls_clickable(1220)
    assert_no_overlap("[data-testid='side-panel']", "[data-testid='room-controls']")
    assert_no_selector ".lk-participant-tile", text: "agent-AJ"
  end

  test "mosaïque automatique : trois personnes dans une fenêtre large et basse, trois colonnes de tuiles 16:9" do
    open_stage_with_three_speakers

    assert_selector "[data-testid='mosaic'][data-columns='3'][data-rows='1']"
    assert_select "Mosaïque", selected: "Auto"
    zone, tiles = mosaic_geometry
    assert_equal 3, tiles.size
    assert_equal 1, tiles.map { |t| t["top"].round }.uniq.size, "tuiles sur plusieurs rangées : #{tiles.inspect}"
    tiles.each do |tile|
      assert_in_delta 16.0 / 9, tile["width"].to_f / tile["height"], 0.03, "tuile hors 16:9 : #{tile.inspect}"
      # Capture (2×2 vendor) : chaque vidéo faisait moins d'un cinquième de
      # la largeur de la zone (~170 px sur ~890) ; en trois colonnes, chaque
      # tuile 16:9 en occupe près d'un tiers.
      assert_operator tile["width"], :>=, zone["width"] * 0.3, "tuile de #{tile['width'].round} px dans une zone de #{zone['width'].round} px"
    end
    assert_equal [ 1000, 550 ], evaluate_script("[window.innerWidth, window.innerHeight]")
    assert_mosaic_clear_of_picker(1000)
    assert_tiles_bounded(1000)
    assert_fits_window(1000, "[data-testid='stage']")
    assert_all_controls_clickable(1000)
  end

  test "mosaïque au choix : disposition imposée, mémorisée sur l'appareil, retour à l'automatique" do
    open_stage_with_three_speakers

    { "2 colonnes" => [ "2", 2, 2 ], "1 colonne" => [ "column", 1, 3 ], "1 rangée" => [ "row", 3, 1 ] }.each do |label, (id, columns, rows)|
      select label, from: "Mosaïque"
      assert_selector "[data-testid='mosaic'][data-columns='#{columns}'][data-rows='#{rows}']"
      assert_equal id, evaluate_script("localStorage.getItem('#{MOSAIC_MODE_KEY}')")
      assert_mosaic_clear_of_picker(1000)
      assert_tiles_bounded(1000)
      assert_fits_window(1000, "[data-testid='stage']")
    end

    select "2 colonnes", from: "Mosaïque"
    open_stage_with_three_speakers(keep_mosaic_mode: true)
    assert_select "Mosaïque", selected: "2 colonnes"
    assert_selector "[data-testid='mosaic'][data-columns='2'][data-rows='2']"

    select "Auto", from: "Mosaïque"
    assert_selector "[data-testid='mosaic'][data-columns='3'][data-rows='1']"
    assert_equal "auto", evaluate_script("localStorage.getItem('#{MOSAIC_MODE_KEY}')")
  end

  (VIEWPORTS + [ CAFE_IA_8_PAGE ]).each do |width, height|
    test "vue spectateur à #{width}×#{height} : la transcription ne recouvre ni la scène ni la main levée" do
      resize(width, height)
      confirm_viewer_registration(@webinar)
      visit public_webinar_path(slug: @webinar.slug)
      assert_selector ".lk-viewer__stage"
      assert_selector "[data-testid='side-panel']"
      assert_selector "[data-testid='hand-raise-viewer']"

      assert_no_overlap("[data-testid='side-panel']", ".lk-viewer__stage")
      assert_no_overlap("[data-testid='side-panel']", "[data-testid='hand-raise-viewer']")
      assert_fits_window(width, ".lk-viewer")
      add_remote_participants_to_viewer_room
      assert_selector "[data-testid='participant-count']", exact_text: "2 présents"
      stage_height, viewport = evaluate_script("[document.querySelector('.lk-viewer__stage').getBoundingClientRect().height, window.innerHeight]")
      assert_operator stage_height, :>=, viewport * 0.3,
        "scène spectateur de #{stage_height.round} px dans une fenêtre de #{viewport} px"
    end
  end

  private

  # `measured` : :window (taille de la fenêtre) ou :page (zone d'affichage,
  # innerWidth × innerHeight, comme sur une capture d'écran).
  def resize(width, height, measured = :window)
    window = Capybara.current_session.current_window
    window.resize_to(width, height)
    return if measured == :window

    inner_width, inner_height = evaluate_script("[window.innerWidth, window.innerHeight]")
    window.resize_to(2 * width - inner_width, 2 * height - inner_height)
  end

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub, info: { email: user.email }
    )
    visit "/auth/pocket_id/callback"
  end

  def join_stage(keep_mosaic_mode: false)
    assert_selector "[data-testid='prejoin']", wait: 10
    # Préférences du panneau latéral (repli, onglet) et mosaïque d'un test
    # précédent (même navigateur) : lues au montage de la scène, donc
    # effacées avant.
    execute_script("localStorage.removeItem('undust-live:side-panel:collapsed'); localStorage.removeItem('undust-live:side-panel:tab')")
    execute_script("localStorage.removeItem('#{MOSAIC_MODE_KEY}')") unless keep_mosaic_mode
    fill_in "username", with: "Marc"
    find(".lk-join-button:not([disabled])", wait: 10).click
    assert_selector "[data-testid='stage']", wait: 10
  end

  def populate_room(extra_speakers: [])
    result = nil
    25.times do
      result = evaluate_script("(() => { const EXTRA_SPEAKERS = #{extra_speakers.to_json}; #{POPULATE_ROOM_JS} })()")
      break if result == "ok"
      sleep 0.4
    end
    assert_equal "ok", result, "impossible de peupler la Room LiveKit de la page"
    assert_selector "[data-testid='room-controls'] [data-lk-source='camera']", wait: 5
  end

  # Spectateur : la connexion échouée, on ajoute un agent et un autre
  # spectateur à la Room de la page (aucune permission touchée).
  def add_remote_participants_to_viewer_room
    result = nil
    25.times do
      result = evaluate_script(<<~JS)
        (() => {
          #{FIND_ROOM_JS}
          if (!room) return 'room introuvable';
          if (room.state !== 'disconnected') return 'connexion en cours';
          const Participant = Object.getPrototypeOf(Object.getPrototypeOf(room.localParticipant)).constructor;
          [['agent-AJ_testAgent001', 4], ['viewer-2', 0]].forEach(([identity, kind]) => {
            const participant = new Participant('PA_' + identity, identity, identity, '', {}, undefined, kind);
            room.remoteParticipants.set(identity, participant);
            room.emit('participantConnected', participant);
          });
          return 'ok';
        })()
      JS
      break if result == "ok"
      sleep 0.4
    end
    assert_equal "ok", result, "impossible de peupler la Room spectateur"
  end

  # Vraie vidéo portrait (téléphone, 720×1280) dans la tuile de
  # l'intervenant : c'est elle qui faisait grossir les tuiles sans borne
  # (taille intrinsèque de la vidéo dans une grille sans hauteur définie).
  def play_portrait_video_in_speaker_tile
    ready = evaluate_script(<<~JS)
      (async () => {
        const tile = Array.from(document.querySelectorAll('.lk-participant-tile'))
          .find((t) => t.textContent.includes('Basile Delmas'));
        if (!tile) return false;
        const canvas = document.createElement('canvas');
        canvas.width = 720; canvas.height = 1280;
        const ctx = canvas.getContext('2d');
        const paint = () => { ctx.fillStyle = '#808080'; ctx.fillRect(0, 0, 720, 1280); requestAnimationFrame(paint); };
        paint();
        const video = document.createElement('video');
        video.className = 'lk-participant-media-video';
        video.muted = true;
        video.srcObject = canvas.captureStream(15);
        tile.prepend(video);
        await video.play();
        await new Promise((resolve) => { const check = () => (video.videoHeight > 0 ? resolve() : setTimeout(check, 50)); check(); });
        return video.videoHeight;
      })()
    JS
    assert_equal 1280, ready, "vidéo portrait non lue dans la tuile de l'intervenant"
  end

  # Cas observé : animateur, Tristan et Basile sur scène, transcription
  # repliée (la zone vidéo prend toute la largeur), fenêtre large et basse.
  def open_stage_with_three_speakers(keep_mosaic_mode: false)
    resize(*CAFE_IA_7_PAGE, :page)
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)
    join_stage(keep_mosaic_mode: keep_mosaic_mode)
    click_on "Masquer"
    populate_room(extra_speakers: [ [ "speaker-tristan", "Tristan Lemaire" ] ])
    assert_selector "[data-testid='stage'] .lk-participant-tile", count: 3
  end

  # Zone de la mosaïque et tuiles, en px.
  def mosaic_geometry
    evaluate_script(<<~JS)
      (() => {
        const rect = (el) => { const r = el.getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; };
        return [rect(document.querySelector('[data-testid="mosaic"]')),
                Array.from(document.querySelectorAll('[data-testid="mosaic"] .lk-participant-tile')).map(rect)];
      })()
    JS
  end

  # Le sélecteur « Mosaïque » est dans l'écran, cliquable sans défilement
  # (elementFromPoint au centre de la liste = la liste) et ne recouvre
  # jamais une tuile.
  def assert_mosaic_clear_of_picker(width)
    picker = evaluate_script(<<~JS)
      (() => {
        const select = document.querySelector("[data-testid='mosaic-picker'] select");
        if (!select) return null;
        const r = document.querySelector("[data-testid='mosaic-picker']").getBoundingClientRect();
        const s = select.getBoundingClientRect();
        const target = document.elementFromPoint(s.left + s.width / 2, s.top + s.height / 2);
        return { left: r.left, top: r.top, right: r.right, bottom: r.bottom,
                 clickable: target === select,
                 covered_by: target ? (target.getAttribute('data-testid') || target.className || target.tagName) : null,
                 inside: s.left >= 0 && s.top >= 0 && s.right <= window.innerWidth && s.bottom <= window.innerHeight };
      })()
    JS
    assert picker, "sélecteur « Mosaïque » absent de la scène à #{width} px"
    assert picker["clickable"], "sélecteur « Mosaïque » recouvert à #{width} px par « #{picker['covered_by']} »"
    assert picker["inside"], "sélecteur « Mosaïque » hors de l'écran à #{width} px"
    _zone, tiles = mosaic_geometry
    tiles.each do |tile|
      disjoint = picker["right"] <= tile["left"] || tile["right"] <= picker["left"] ||
                 picker["bottom"] <= tile["top"] || tile["bottom"] <= picker["top"]
      assert disjoint, "sélecteur #{picker.inspect} sur une tuile #{tile.inspect} à #{width} px"
    end
  end

  # Critère principal : rien ne défile, ni la page ni le conteneur.
  def assert_fits_window(width, container)
    page_overflow = evaluate_script("[document.documentElement.scrollHeight - window.innerHeight, " \
                                    "document.documentElement.scrollWidth - document.documentElement.clientWidth]")
    assert_equal [ 0, 0 ], page_overflow.map { |v| [ v, 0 ].max },
      "la page défile à #{width} px (vertical, horizontal : #{page_overflow.inspect})"
    inner = evaluate_script("(() => { const el = document.querySelector(#{container.to_json}); " \
                            "return [el.scrollHeight - el.clientHeight, el.scrollWidth - el.clientWidth]; })()")
    assert_equal [ 0, 0 ], inner.map { |v| [ v, 0 ].max }, "#{container} défile à #{width} px (#{inner.inspect})"
  end

  # Chaque tuile reste dans la zone vidéo et dans la fenêtre ; la vidéo
  # est au ratio de la source (contain), jamais recadrée.
  def assert_tiles_bounded(width)
    tiles = evaluate_script(<<~JS)
      (() => {
        const zone = document.querySelector('.lk-stage__tiles').getBoundingClientRect();
        return Array.from(document.querySelectorAll('.lk-stage__tiles .lk-participant-tile')).map((t) => {
          const r = t.getBoundingClientRect();
          const video = t.querySelector('video');
          return { inside: r.top >= zone.top - 1 && r.bottom <= zone.bottom + 1 && r.left >= zone.left - 1 && r.right <= zone.right + 1
                           && r.bottom <= window.innerHeight,
                   height: Math.round(r.height), fit: video ? getComputedStyle(video).objectFit : null };
        });
      })()
    JS
    tiles.each do |tile|
      assert tile["inside"], "tuile de #{tile['height']} px hors de la zone vidéo à #{width} px"
      assert_includes [ nil, "contain" ], tile["fit"], "vidéo recadrée (object-fit: #{tile['fit']}) à #{width} px"
    end
  end

  # elementFromPoint au centre de chaque bouton, SANS défilement : il doit
  # être entièrement dans la fenêtre et renvoyer le bouton (ou son
  # icône/libellé), jamais un élément posé par-dessus.
  def assert_all_controls_clickable(width)
    CONTROLS.each do |label, selector|
      hit = evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector("[data-testid='room-controls'] #{selector}");
          if (!el) return { found: false };
          const r = el.getBoundingClientRect();
          const target = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          return { found: true, clickable: !!target && (target === el || el.contains(target)),
                   covered_by: target ? (target.getAttribute('data-testid') || String(target.className.baseVal ?? target.className) || target.tagName) : null,
                   inside: r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight && r.width > 0 };
        })()
      JS
      assert hit["found"], "#{label} absent de la barre de contrôle à #{width} px"
      assert hit["clickable"], "#{label} recouvert à #{width} px par « #{hit['covered_by']} »"
      assert hit["inside"], "#{label} hors de l'écran à #{width} px"
    end
  end

  def assert_camera_menu_readable
    find("[data-testid='room-controls'] [aria-label='Choisir la caméra']").click
    menu = nil
    10.times do
      menu = evaluate_script(<<~JS)
        (() => {
          const m = Array.from(document.querySelectorAll('[data-testid="room-controls"] [aria-label="Choisir la caméra"] ~ *'))
            .find((el) => getComputedStyle(el).visibility === 'visible');
          if (!m) return null;
          const items = Array.from(m.querySelectorAll('li > button'));
          if (items.length === 0) return null;
          const r = m.getBoundingClientRect();
          const first = items[0].getBoundingClientRect();
          const target = document.elementFromPoint(first.left + first.width / 2, first.top + first.height / 2);
          return { inside: r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight,
                   item_clickable: !!target && (target === items[0] || items[0].contains(target)),
                   labels: items.map((b) => b.textContent.trim()) };
        })()
      JS
      break if menu
      sleep 0.3
    end
    assert menu, "le menu caméra ne s'ouvre pas (ou ne liste aucun périphérique)"
    assert menu["inside"], "menu caméra rogné par le bord de l'écran"
    assert menu["item_clickable"], "premier périphérique du menu caméra recouvert (#{menu['labels'].inspect})"
    find("[data-testid='room-controls'] [aria-label='Choisir la caméra']").click
  end

  # Le lien « Régie ↗ » est visible et cliquable sans défilement : au
  # centre du lien, c'est lui que le navigateur touche.
  def assert_regie_link_clickable(width)
    clickable = evaluate_script(<<~JS)
      (() => {
        const link = document.querySelector("[data-testid='regie-link']");
        if (!link) return false;
        const r = link.getBoundingClientRect();
        const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        return r.width > 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight && !!hit && (hit === link || link.contains(hit));
      })()
    JS
    assert clickable, "lien « Régie ↗ » absent, hors écran ou recouvert à #{width} px"
  end

  def assert_no_overlap(first, second)
    a, b = evaluate_script("(() => { #{BOX_JS} return [box(#{first.to_json}), box(#{second.to_json})]; })()")
    assert a, "#{first} absent"
    assert b, "#{second} absent"
    disjoint = a["right"] <= b["left"] || b["right"] <= a["left"] || a["bottom"] <= b["top"] || b["bottom"] <= a["top"]
    assert disjoint, "#{first} #{a.inspect} chevauche #{second} #{b.inspect}"
  end



  # Les six contrôles sur une seule ligne, même à 360 px : une barre qui
  # passe à la ligne pousse « Quitter » hors de sa zone.
  def assert_controls_on_one_line(width)
    tops = CONTROLS.values.map do |selector|
      evaluate_script("Math.round(document.querySelector(\"[data-testid='room-controls'] #{selector}\").getBoundingClientRect().top)")
    end
    assert_operator tops.max - tops.min, :<=, 8, "barre de contrôle sur plusieurs lignes à #{width} px (sommets : #{tops.inspect})"
  end

  # Mise en forme de la scène sous le thème undust : propriétés
  # VISIBLES de la mise en forme, mesurées sur le rendu — lien « Régie ↗ »
  # lisible sur la barre (le rouge sans aplat de « Terminer le direct » est
  # vérifié dans la régie, regie_test.rb), pastille de nom/micro contenue
  # dans sa tuile et sur une ligne, tuile en carte (rayon 8 px), boutons
  # de la barre à rayon interactif 0, « Quitter » distinct des autres
  # contrôles, barre de scène qui ne défile pas dès 768 px.
  def assert_presentation_p0(width)
    m = evaluate_script(<<~JS)
      (() => {
        const css = (sel) => { const el = document.querySelector(sel); return el ? getComputedStyle(el) : null; };
        const lum = (rgb) => { const c = rgb.match(/[\\d.]+/g).slice(0, 3).map(Number).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
        const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
        const barBg = getComputedStyle(document.querySelector('[data-testid="stage-bar"]')).backgroundColor;
        const tile = document.querySelector('.lk-stage__tiles [data-lk-source]');
        const chip = tile.querySelector('div:last-of-type > div');
        const tr = tile.getBoundingClientRect(), cr = chip.getBoundingClientRect();
        const bar = document.querySelector('[data-testid="stage-bar"]');
        return {
          regieContrast: ratio(css("[data-testid='regie-link']").color, barBg),
          tileRadius: getComputedStyle(tile).borderTopLeftRadius,
          cardRadius: getComputedStyle(document.documentElement).getPropertyValue("--radius-card").trim(),
          interactiveRadius: getComputedStyle(document.documentElement).getPropertyValue("--radius-interactive").trim(),
          chipInside: cr.left >= tr.left && cr.right <= tr.right && cr.bottom <= tr.bottom && cr.height < 40,
          regieRadius: css("[data-testid='regie-link']").borderTopLeftRadius,
          leaveColor: css('.lk-room-controls__leave').color,
          micColor: css("[data-lk-source='microphone']").color,
          micBg: css("[data-testid='room-controls'] [data-lk-source='microphone']").backgroundColor,
          micMenuBg: css("[data-testid='room-controls'] [aria-label='Choisir le micro']").backgroundColor,
          micBorder: css("[data-testid='room-controls'] [data-lk-source='microphone']").borderTopWidth,
          micMutedColor: css("[data-testid='room-controls'] [data-lk-source='microphone'] svg").color,
          criticalColor: (() => {
            const probe = document.body.appendChild(document.createElement("span"));
            probe.style.color = "var(--status-critical-dark)";
            const color = getComputedStyle(probe).color;
            probe.remove();
            return color;
          })(),
          micMutedShadow: css("[data-testid='room-controls'] [data-lk-source='microphone']").boxShadow,
          controlHeights: Array.from(document.querySelectorAll("[data-testid='room-controls'] button"))
            .filter((b) => b.getBoundingClientRect().width > 0 && !b.closest('.lk-device-menu'))
            .map((b) => Math.round(b.getBoundingClientRect().height)),
          barButtonHeights: Array.from(document.querySelectorAll("[data-testid='stage-bar'] button, [data-testid='regie-link'], [data-testid='side-panel-toggle']")).map((b) => Math.round(b.getBoundingClientRect().height)),
          barScroll: bar.scrollHeight - bar.clientHeight
        };
      })()
    JS
    assert_operator m["regieContrast"], :>=, 4.5, "« Régie ↗ » : contraste #{m['regieContrast'].round(2)}:1 (< 4,5)"
    # Thème undust : valeurs de la charte en dur (un changement dans la gem se
    # voit ici) ; autre thème : le jeton du thème.
    assert_equal (Theme.undust? ? "8px" : m["cardRadius"]), m["tileRadius"], "tuile sans rayon carte à #{width} px"
    assert_equal (Theme.undust? ? "0px" : m["interactiveRadius"]), m["regieRadius"], "lien Régie sans le rayon interactif du thème"
    assert m["chipInside"], "pastille nom/micro hors de sa tuile ou sur plusieurs lignes à #{width} px"
    # Les règles de tuile ne doivent pas atteindre les boutons :
    # bouton et chevron du groupe micro au même fond, sans filet de carte.
    assert_equal m["micMenuBg"], m["micBg"], "groupe micro en deux tons : la règle de tuile atteint le bouton"
    assert_equal "0px", m["micBorder"], "le bouton Micro porte un filet de tuile"
    refute_equal m["micColor"], m["leaveColor"], "« Quitter » indiscernable des autres contrôles"
    # Hiérarchie et états lisibles, cibles >= 40 px,
    # hauteurs homogènes. Micro coupé = état FORT (teinte + filet critique).
    assert_equal (Theme.undust? ? "rgb(225, 118, 124)" : m["criticalColor"]), m["micMutedColor"],
                 "micro coupé : icône pas en critique (#{m['micMutedColor']})"
    refute_equal "none", m["micMutedShadow"], "micro coupé : pas de filet d'état"
    assert_operator m["controlHeights"].min, :>=, 40, "bouton de contrôle sous 40 px à #{width} px (#{m['controlHeights'].inspect})"
    assert_operator m["controlHeights"].max - m["controlHeights"].min, :<=, 2, "hauteurs de contrôles hétérogènes (#{m['controlHeights'].inspect})"
    assert_operator m["barButtonHeights"].min, :>=, 40, "bouton de la barre de scène sous 40 px à #{width} px (#{m['barButtonHeights'].inspect})"
    assert_operator m["barButtonHeights"].min, :>=, 44, "cible tactile sous 44 px à #{width} px (#{m['barButtonHeights'].inspect})" if width <= 480
    assert_operator m["barScroll"], :<=, 1, "la barre de scène défile à #{width} px" if width >= 768
  end

  def open_side_panel
    click_on "Afficher" if has_selector?("[data-testid='side-panel'].lk-side-panel--collapsed", wait: 0)
    assert_no_selector "[data-testid='side-panel'].lk-side-panel--collapsed"
  end

  # Saisie vide, panneau ouvert sur la discussion : le texte indicatif
  # tient dans la zone (aucune barre de défilement) — capture d'un direct.
  # Champ absent ou invisible = échec, jamais un contrôle sauté.
  def assert_discussion_input_without_scrollbar(width)
    overflow = evaluate_script(<<~JS)
      (() => {
        const input = document.querySelector('.lk-discussion__input');
        if (!input || input.getBoundingClientRect().height === 0) return null;
        return input.scrollHeight - input.clientHeight;
      })()
    JS
    refute_nil overflow, "champ de saisie absent ou invisible à #{width} px, panneau ouvert"
    assert_operator overflow, :<=, 1, "champ de saisie vide qui défile (#{overflow} px) à #{width} px"
  end

  # La vidéo occupe l'essentiel : au moins 40 % de la hauteur de la
  # fenêtre (contre ~145 px sur 1 270 dans une capture réelle), 30 % sur
  # téléphone où barre de scène et contrôles se partagent 360 px.
  def assert_video_dominates
    tiles, viewport, width = evaluate_script("(() => { #{BOX_JS} return [box('.lk-stage__tiles'), window.innerHeight, window.innerWidth]; })()")
    share = width < 768 ? 0.3 : 0.4
    assert_operator tiles["height"], :>=, viewport * share,
      "zone vidéo de #{tiles['height'].round} px dans une fenêtre de #{viewport} px"
  end
end
