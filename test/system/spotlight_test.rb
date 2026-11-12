require "application_system_test_case"

# « La mise en avant de l'un ou l'autre en direct ».
#
# Verrouillé ici, dans le navigateur (la commande elle-même, « Mettre en
# avant » depuis la régie, est dans regie_test.rb : la salle
# de l'animation est celle des participants, sans bouton) :
#   - la salle diffuse (le test rejoue ce que fait LiveKit : métadonnées
#     de la Room puis RoomMetadataChanged) : la personne passe en grand,
#     les autres en vignettes, chez l'animateur, l'intervenant et le
#     spectateur ; « Retirer la mise en avant » rend la grille ;
#   - le partage d'écran garde la priorité et remplit la zone, les autres
#     en bande compacte de vignettes, à droite par défaut (bascule
#     gauche/droite mémorisée sur l'appareil), en bas en étroit ; libellé
#     « Écran de <nom> » ;
#   - une nouvelle mise en avant lève le zoom local ⤢ ;
#   - la mise en page tient en focus : rien ne défile,
#     tuiles bornées, contrôles cliquables, transcription à part, pas de
#     tuile agent ;
#   - le sélecteur « Mosaïque » n'existe qu'en grille,
#     sur la scène : ni en focus, ni chez le spectateur, dont la mosaïque
#     reste automatique.
#
# La CI n'a pas de serveur LiveKit (livekit.invalid) : comme dans
# stage_layout_test.rb, la Room de la page est retrouvée par le contexte
# React une fois la connexion échouée, puis peuplée avec la vraie classe
# Participant. Le spectateur ne montre que des pistes souscrites : on lui
# donne de vraies pistes caméra (caméra factice de Chromium, createTracks)
# portées par des publications minimales.
class SpotlightTest < JsSystemTestCase
  include LivekitRoomRecipe

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"
  VIEWPORTS = [ [ 360, 780 ], [ 768, 1024 ], [ 1220, 1270 ], [ 1700, 900 ], [ 2000, 1100 ] ].freeze
  STRIP_SIDE_KEY = "undust-live:focus-strip-side".freeze
  CONTROLS = [ "[data-lk-source='microphone']", "[data-lk-source='camera']", "[data-lk-source='screen_share']",
               ".lk-disconnect-button" ].freeze

  # LiveKit RoomService du test : enregistre les écritures de métadonnées,
  # refuse le reste comme un LiveKit injoignable (la scène démarre quand
  # même, cf. RecordingSession).
  class FakeRoomService
    def initialize
      @mutex = Mutex.new
      @metadata_writes = []
    end

    def metadata_writes
      @mutex.synchronize { @metadata_writes.dup }
    end

    def update_room_metadata(room:, metadata:)
      @mutex.synchronize { @metadata_writes << [ room, metadata ] }
      { metadata: JSON.generate(metadata) }
    end

    def method_missing(name, *_args, **_kwargs)
      raise RoomServiceClient::Error, "LiveKit absent du test (#{name})"
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  ROOM_HELPERS_JS = <<~JS.freeze
    #{FIND_ROOM_JS}
    const Participant = room && Object.getPrototypeOf(Object.getPrototypeOf(room.localParticipant)).constructor;
    const Emitter = Participant && Object.getPrototypeOf(Participant);
    const grant = (canPublish) => ({ canPublish, canSubscribe: true, canPublishData: true,
                                     canPublishSources: [], hidden: false, agent: false });
    // Publication minimale portant une vraie piste vidéo (caméra factice).
    const publish = async (participant, source) => {
      const [track] = await room.localParticipant.createTracks({ video: true, audio: false });
      const pub = Object.assign(new Emitter(), {
        kind: 'video', source, trackSid: 'TR_' + participant.identity + '_' + source, trackName: source, track,
        isSubscribed: true, isMuted: false, isEnabled: true, isEncrypted: false, isDesired: true, simulcasted: false,
        dimensions: { width: 640, height: 480 }, setSubscribed() {}, setEnabled() {}, setVideoQuality() {}, setVideoDimensions() {} });
      participant.trackPublications.set(pub.trackSid, pub);
      participant.videoTrackPublications.set(pub.trackSid, pub);
      room.emit('trackPublished', pub, participant);
      room.emit('trackSubscribed', track, pub, participant);
    };
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
    @room_service = FakeRoomService.new
    @saved_factory = Rails.configuration.x.room_service_client_factory
    room_service = @room_service
    Rails.configuration.x.room_service_client_factory = -> { room_service }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @saved_factory
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL TRANSCRIPT_ENABLED].each { |k| ENV[k] = @saved_env[k] }
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
    Capybara.current_session.current_window.resize_to(1400, 900)
  end

  VIEWPORTS.each do |width, height|
    test "animateur à #{width} px : la scène suit la mise en avant diffusée, sans bouton, le retrait rend la grille" do
      resize(width, height)
      open_stage
      add_participants([ [ "agent-AJ_testAgent001", "agent-AJ_testAgent001", 4, true ],
                         [ "speaker-basile", "Basile Delmas", 0, true ],
                         [ "speaker-tristan", "Tristan Lemaire", 0, true ],
                         [ "viewer-1", "Spectatrice", 0, false ] ], grant_local: true)
      assert_selector "[data-testid='stage'] .lk-participant-tile", count: 3
      assert_no_selector "[data-testid='spotlight-toggle']"
      assert_selector "[data-testid='mosaic-picker']"

      broadcast(spotlight: "speaker-basile")
      assert_focus_on("[data-testid='stage']", "Basile Delmas")
      assert_no_selector "[data-testid='mosaic-picker']"
      within(focus_tile_selector("[data-testid='stage']")) do
        assert_selector "[data-testid='spotlight-badge']", exact_text: "En avant"
      end
      assert_no_selector "[data-testid='spotlight-toggle']"
      assert_fits_window(width, "[data-testid='stage']")
      assert_tiles_inside(width, ".lk-stage__tiles")
      assert_controls_clickable(width)
      assert_no_overlap("[data-testid='side-panel']", "[data-testid='room-controls']")
      assert_no_overlap("[data-testid='stage-bar']", ".lk-stage__tiles")
      assert_no_text "agent-AJ"

      broadcast(spotlight: nil)
      assert_no_selector "[data-testid='stage'] .lk-focus-stage"
      assert_selector "[data-testid='stage'] .lk-participant-tile", count: 3
      assert_no_selector "[data-testid='spotlight-badge']"
      assert_selector "[data-testid='mosaic-picker']"
      assert_empty @room_service.metadata_writes, "la scène n'écrit jamais la mise en avant"
    end
  end

  test "animateur : une nouvelle mise en avant lève le zoom local ⤢ ; le partage d'écran garde la priorité" do
    resize(1700, 900)
    open_stage
    add_participants([ [ "speaker-basile", "Basile Delmas", 0, true ],
                       [ "speaker-tristan", "Tristan Lemaire", 0, true ] ], grant_local: true)

    tile_for("Tristan Lemaire").hover
    tile_for("Tristan Lemaire").find("button.lk-focus-toggle-button").click
    assert_focus_on("[data-testid='stage']", "Tristan Lemaire")

    broadcast(spotlight: "speaker-basile")
    assert_focus_on("[data-testid='stage']", "Basile Delmas")

    publish_track("speaker-tristan", "screen_share")
    assert_selector "#{focus_tile_selector("[data-testid='stage']")}[data-lk-source='screen_share']", wait: 5
    assert_fits_window(1700, "[data-testid='stage']")
    assert_tiles_inside(1700, ".lk-stage__tiles")

    unpublish_track("speaker-tristan", "screen_share")
    assert_focus_on("[data-testid='stage']", "Basile Delmas")
  end

  # Bande dessous quand la ZONE VIDÉO est au plus en 3:2 (ou au plus en
  # 2:1 si elle fait moins de 32 rem de large), sur le côté au-delà
  # (room.css, conteneur lk-video), mesures de
  # la largeur d'un partage 16:9 dans la grande tuile. [largeur, hauteur de
  # fenêtre, panneau, bande attendue] ; panneau :default = replié d'office
  # sous 768 px, ouvert au-delà.
  #   - 846×1270 (tuile Hyprland), panneau ouvert : zone
  #     ~1,5, dessous (686 px contre 644) ;
  #   - 960×1190 (demi-écran 1920×1080), panneau ouvert : zone ~2:1, à
  #     côté (752 px contre 573) ; replié : zone ~1,2, dessous (896 px) ;
  #   - 1220×1270 : zone en portrait, dessous (827 px contre ~680) ;
  #   - 412×915 (téléphone), panneau ouvert : zone plate mais étroite
  #     (moins de 32 rem, au plus 2:1), dessous (275 px contre 228).
  [ [ 360, 780, :default, :bottom ], [ 412, 915, :open, :bottom ], [ 846, 1270, :default, :bottom ],
    [ 960, 1190, :default, :right ], [ 960, 1190, :collapsed, :bottom ], [ 1220, 1270, :default, :bottom ],
    [ 1700, 900, :default, :right ], [ 2000, 1100, :default, :right ] ].each do |width, height, panel, side|
    test "partage d'écran à #{width}×#{height}, panneau #{{ collapsed: 'replié', open: 'ouvert' }.fetch(panel, 'par défaut')} : bande #{side == :bottom ? 'dessous' : 'à droite'}, « Écran de … »" do
      resize(width, height)
      open_stage
      case panel
      when :collapsed
        click_on "Masquer"
        assert_selector "[data-testid='side-panel'].lk-side-panel--collapsed"
      when :open
        click_on "Afficher"
        assert_no_selector "[data-testid='side-panel'].lk-side-panel--collapsed"
      end
      add_participants([ [ "agent-AJ_testAgent001", "agent-AJ_testAgent001", 4, true ],
                         [ "speaker-basile", "Basile Delmas", 0, true ],
                         [ "speaker-tristan", "Tristan Lemaire", 0, true ] ], grant_local: true)
      publish_track("speaker-basile", "screen_share")

      assert_selector "#{focus_tile_selector("[data-testid='stage']")}[data-lk-source='screen_share']",
                      text: "Écran de Basile Delmas", wait: 5
      assert_no_text "'s screen"
      assert_strip_layout(width, side)
      assert_fits_window(width, "[data-testid='stage']")
      assert_tiles_inside(width, ".lk-stage__tiles")
      assert_controls_clickable(width)
      assert_no_overlap("[data-testid='side-panel']", "[data-testid='room-controls']")
      assert_no_text "agent-AJ"
    end
  end

  test "bande de vignettes : à droite par défaut, la bascule la passe à gauche, mémorisée sur l'appareil" do
    resize(1700, 900)
    open_stage
    add_participants([ [ "speaker-basile", "Basile Delmas", 0, true ],
                       [ "speaker-tristan", "Tristan Lemaire", 0, true ] ], grant_local: true)
    broadcast(spotlight: "speaker-basile")
    assert_focus_on("[data-testid='stage']", "Basile Delmas")
    assert_strip_layout(1700, :right)

    find("[data-testid='strip-side-toggle'][aria-label='Placer les vignettes à gauche']").click
    assert_selector ".lk-focus-stage[data-side='left']"
    assert_strip_layout(1700, :left)
    assert_equal "left", evaluate_script("localStorage.getItem('#{STRIP_SIDE_KEY}')")
    assert_fits_window(1700, "[data-testid='stage']")

    open_stage(keep_strip_side: true)
    add_participants([ [ "speaker-basile", "Basile Delmas", 0, true ],
                       [ "speaker-tristan", "Tristan Lemaire", 0, true ] ], grant_local: true)
    broadcast(spotlight: "speaker-basile")
    assert_selector ".lk-focus-stage[data-side='left']", wait: 5
    assert_strip_layout(1700, :left)

    find("[data-testid='strip-side-toggle'][aria-label='Placer les vignettes à droite']").click
    assert_selector ".lk-focus-stage[data-side='right']"
    assert_equal "right", evaluate_script("localStorage.getItem('#{STRIP_SIDE_KEY}')")
  end

  test "intervenant (/join) : voit la mise en avant diffusée, pastille « En avant », aucun bouton" do
    speaker = @webinar.speakers.create!(name: "Tristan Lemaire")
    resize(1220, 1270)
    visit join_webinar_path(slug: @webinar.slug, t: speaker.token)
    join_stage
    add_participants([ [ "agent-AJ_testAgent001", "agent-AJ_testAgent001", 4, true ],
                       [ "host-sub-marc", "Marc", 0, true ],
                       [ "speaker-basile", "Basile Delmas", 0, true ] ], grant_local: true)
    assert_selector "[data-testid='stage'] .lk-participant-tile", count: 3
    assert_no_selector "[data-testid='spotlight-toggle']"
    assert_no_selector "[data-testid='spotlight-badge']"

    broadcast(spotlight: "speaker-basile")
    assert_focus_on("[data-testid='stage']", "Basile Delmas")
    within(focus_tile_selector("[data-testid='stage']")) do
      assert_selector "[data-testid='spotlight-badge']", exact_text: "En avant"
    end
    assert_selector "[data-testid='spotlight-badge']", count: 1
    assert_no_selector "[data-testid='spotlight-toggle']"
    assert_fits_window(1220, "[data-testid='stage']")
    assert_tiles_inside(1220, ".lk-stage__tiles")

    broadcast(spotlight: nil)
    assert_no_selector "[data-testid='stage'] .lk-focus-stage"
    assert_no_selector "[data-testid='spotlight-badge']"
  end

  VIEWPORTS.each do |width, height|
    test "spectateur à #{width} px : la personne mise en avant en grand, les autres en vignettes, sans rien pouvoir changer" do
      resize(width, height)
      open_viewer
      add_participants([ [ "agent-AJ_testAgent001", "agent-AJ_testAgent001", 4, true ],
                         [ "host-sub-marc", "Marc", 0, true ],
                         [ "speaker-basile", "Basile Delmas", 0, true ],
                         [ "speaker-tristan", "Tristan Lemaire", 0, true ] ])
      %w[host-sub-marc speaker-basile speaker-tristan].each { |identity| publish_track(identity, "camera") }
      assert_selector ".lk-viewer__stage [data-testid='mosaic'] .lk-participant-tile", count: 3
      assert_no_selector ".lk-viewer__stage .lk-focus-stage"
      assert_no_selector "[data-testid='mosaic-picker']"

      broadcast(spotlight: "speaker-basile")
      assert_focus_on(".lk-viewer__stage", "Basile Delmas")
      assert_selector ".lk-viewer__stage .lk-participant-tile", count: 3
      assert_fits_window(width, ".lk-viewer")
      assert_tiles_inside(width, ".lk-viewer__stage")
      assert_no_overlap("[data-testid='side-panel']", ".lk-viewer__stage")
      assert_no_overlap("[data-testid='side-panel']", "[data-testid='hand-raise-viewer']")
      assert_no_selector "[data-testid='spotlight-toggle']"
      assert_no_selector "[data-testid='spotlight-badge']"
      assert_no_selector "button.lk-focus-toggle-button"
      assert_no_text "agent-AJ"
    end
  end

  test "spectateur : arrivée de la personne déjà mise en avant, priorité au partage d'écran, retour à la grille" do
    resize(1220, 1270)
    open_viewer
    add_participants([ [ "host-sub-marc", "Marc", 0, true ], [ "speaker-tristan", "Tristan Lemaire", 0, true ] ])
    %w[host-sub-marc speaker-tristan].each { |identity| publish_track(identity, "camera") }
    broadcast(spotlight: "speaker-basile")
    assert_selector ".lk-viewer__stage .lk-participant-tile", count: 2
    assert_no_selector ".lk-viewer__stage .lk-focus-stage"

    add_participants([ [ "speaker-basile", "Basile Delmas", 0, true ] ])
    publish_track("speaker-basile", "camera")
    assert_focus_on(".lk-viewer__stage", "Basile Delmas")

    publish_track("speaker-tristan", "screen_share")
    assert_selector "#{focus_tile_selector('.lk-viewer__stage')}[data-lk-source='screen_share']",
                    text: "Écran de Tristan Lemaire", wait: 5
    # Zone spectateur en portrait à 1220×1270 : bande dessous (conteneur
    # lk-video, room.css — même critère que la scène).
    assert_strip_layout(1220, :bottom)
    assert_no_selector "[data-testid='strip-side-toggle']"
    assert_tiles_inside(1220, ".lk-viewer__stage")
    unpublish_track("speaker-tristan", "screen_share")
    assert_focus_on(".lk-viewer__stage", "Basile Delmas")

    broadcast(spotlight: nil)
    assert_no_selector ".lk-viewer__stage .lk-focus-stage"
    assert_selector ".lk-viewer__stage .lk-participant-tile", count: 3
  end

  test "spectateur, fenêtre large et basse : mosaïque automatique en trois colonnes, sans sélecteur" do
    resize(1000, 550)
    open_viewer
    add_participants([ [ "host-sub-marc", "Marc", 0, true ],
                       [ "speaker-basile", "Basile Delmas", 0, true ],
                       [ "speaker-tristan", "Tristan Lemaire", 0, true ] ])
    %w[host-sub-marc speaker-basile speaker-tristan].each { |identity| publish_track(identity, "camera") }

    assert_selector ".lk-viewer__stage [data-testid='mosaic'][data-columns='3'][data-rows='1']"
    assert_selector ".lk-viewer__stage .lk-participant-tile", count: 3
    assert_no_selector "[data-testid='mosaic-picker']"
    assert_fits_window(1000, ".lk-viewer")
    assert_tiles_inside(1000, ".lk-viewer__stage")
  end

  private

  def resize(width, height)
    Capybara.current_session.current_window.resize_to(width, height)
  end

  def open_stage(keep_strip_side: false)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: @host.oidc_sub, info: { email: @host.email }
    )
    visit "/auth/pocket_id/callback"
    visit stage_webinar_path(slug: @webinar.slug)
    join_stage(keep_strip_side: keep_strip_side)
  end

  def open_viewer
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector ".lk-viewer__stage", wait: 10
  end

  def join_stage(keep_strip_side: false)
    assert_selector "[data-testid='prejoin']", wait: 10
    execute_script("localStorage.removeItem('undust-live:side-panel:collapsed'); localStorage.removeItem('undust-live:side-panel:tab')")
    execute_script("localStorage.removeItem('#{STRIP_SIDE_KEY}')") unless keep_strip_side
    fill_in "username", with: "Marc"
    find(".lk-join-button:not([disabled])", wait: 10).click
    assert_selector "[data-testid='stage']", wait: 10
  end

  # Ajoute des participants distants réels [identity, nom, kind, canPublish]
  # une fois la connexion échouée (une déconnexion ultérieure les viderait).
  def add_participants(participants, grant_local: false)
    result = nil
    25.times do
      result = evaluate_script(<<~JS)
        (() => {
          #{ROOM_HELPERS_JS}
          if (!room) return 'room introuvable';
          if (room.state !== 'disconnected') return 'connexion en cours : ' + room.state;
          if (#{grant_local}) {
            room.localParticipant.permissions = grant(true);
            room.localParticipant.emit('participantPermissionsChanged', undefined);
          }
          #{participants.to_json}.forEach(([identity, name, kind, canPublish]) => {
            const participant = new Participant('PA_' + identity, identity, name, '', {}, undefined, kind);
            participant.permissions = grant(canPublish);
            room.remoteParticipants.set(identity, participant);
            room.emit('participantConnected', participant);
          });
          return 'ok';
        })()
      JS
      break if result == "ok"
      sleep 0.4
    end
    assert_equal "ok", result, "impossible de peupler la Room LiveKit de la page"
    assert_selector "[data-testid='room-controls'] [data-lk-source='camera']", wait: 5 if grant_local
  end

  def publish_track(identity, source)
    result = evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      (async () => {
        #{ROOM_HELPERS_JS}
        await publish(room.remoteParticipants.get(#{identity.to_json}), #{source.to_json});
        return 'ok';
      })().then(done, (error) => done('échec : ' + error.message));
    JS
    assert_equal "ok", result, "piste #{source} de #{identity} non publiée"
  end

  def unpublish_track(identity, source)
    evaluate_script(<<~JS)
      (() => {
        #{FIND_ROOM_JS}
        const participant = room.remoteParticipants.get(#{identity.to_json});
        const pub = Array.from(participant.trackPublications.values()).find((p) => p.source === #{source.to_json});
        participant.trackPublications.delete(pub.trackSid);
        participant.videoTrackPublications.delete(pub.trackSid);
        pub.track.stop();
        room.emit('trackUnsubscribed', pub.track, pub, participant);
        room.emit('trackUnpublished', pub, participant);
      })()
    JS
  end

  # Ce que fait LiveKit après UpdateRoomMetadata : la Room porte les
  # nouvelles métadonnées et émet RoomMetadataChanged.
  def broadcast(spotlight:)
    metadata = JSON.generate(spotlight: spotlight)
    result = evaluate_script(<<~JS)
      (() => {
        #{FIND_ROOM_JS}
        if (!room) return 'room introuvable';
        room.roomInfo = Object.assign({}, room.roomInfo || {}, { metadata: #{metadata.to_json} });
        room.emit('roomMetadataChanged', #{metadata.to_json});
        return 'ok';
      })()
    JS
    assert_equal "ok", result
  end

  def focus_tile_selector(zone)
    "#{zone} .lk-focus-stage__main > .lk-participant-tile"
  end

  def tile_for(name)
    find(".lk-participant-tile", text: name, match: :first)
  end

  # La personne est en grand : tuile focus, plus grande que chaque vignette.
  def assert_focus_on(zone, name)
    assert_selector focus_tile_selector(zone), text: name, wait: 5
    sizes = evaluate_script(<<~JS)
      (() => {
        const area = (el) => { const r = el.getBoundingClientRect(); return Math.round(r.width * r.height); };
        const main = document.querySelector(#{focus_tile_selector(zone).to_json});
        const thumbs = Array.from(document.querySelectorAll(#{"#{zone} .lk-focus-stage__strip > .lk-participant-tile".to_json}));
        return { main: area(main), thumbs: thumbs.map(area) };
      })()
    JS
    assert sizes["thumbs"].any?, "aucune vignette à côté de #{name}"
    sizes["thumbs"].each do |thumb|
      assert_operator sizes["main"], :>, thumb, "#{name} n'est pas en grand (#{sizes.inspect})"
    end
  end

  # Mode focus : la grande tuile remplit la zone hors bande ; la bande est
  # compacte, du côté attendu (:right, :left) ou dessous (:bottom), et ses
  # vignettes y tiennent, plus petites que la grande tuile.
  def assert_strip_layout(width, side)
    m = evaluate_script(<<~JS)
      (() => {
        const box = (el) => { const r = el.getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; };
        const stage = document.querySelector('.lk-focus-stage');
        return { stage: box(stage), main: box(stage.querySelector('.lk-focus-stage__main > .lk-participant-tile')),
                 strip: box(stage.querySelector('.lk-focus-stage__strip')),
                 thumbs: Array.from(stage.querySelectorAll('.lk-focus-stage__strip > .lk-participant-tile')).map(box) };
      })()
    JS
    stage, main, strip, thumbs = m.values_at("stage", "main", "strip", "thumbs")
    context = "à #{width} px : #{m.inspect}"
    case side
    when :right
      assert_operator strip["left"], :>=, main["right"], "bande pas à droite #{context}"
    when :left
      assert_operator strip["right"], :<=, main["left"], "bande pas à gauche #{context}"
    when :bottom
      assert_operator strip["top"], :>=, main["bottom"], "bande pas dessous #{context}"
    end
    if side == :bottom
      assert_operator main["width"], :>=, stage["width"] - 24, "grande tuile qui ne remplit pas la largeur #{context}"
      assert_operator strip["height"], :<=, stage["height"] * 0.3, "bande trop haute #{context}"
    else
      assert_operator main["height"], :>=, stage["height"] - 24, "vide sous la grande tuile #{context}"
      assert_operator main["width"], :>=, stage["width"] - strip["width"] - 32, "vide à côté de la grande tuile #{context}"
      assert_operator strip["width"], :<=, 230, "bande trop large #{context}"
    end
    assert thumbs.any?, "aucune vignette dans la bande #{context}"
    thumbs.each do |thumb|
      inside = thumb["left"] >= strip["left"] - 1 && thumb["right"] <= strip["right"] + 1 &&
               thumb["top"] >= strip["top"] - 1 && thumb["bottom"] <= strip["bottom"] + 1
      assert inside, "vignette hors de la bande #{context}"
      assert_operator thumb["width"] * thumb["height"], :<, main["width"] * main["height"] / 4, "vignette pas compacte #{context}"
    end
  end

  # Rien ne défile : ni la page, ni le conteneur de la vue.
  def assert_fits_window(width, container)
    page_overflow = evaluate_script("[document.documentElement.scrollHeight - window.innerHeight, " \
                                    "document.documentElement.scrollWidth - document.documentElement.clientWidth]")
    assert_equal [ 0, 0 ], page_overflow.map { |v| [ v, 0 ].max }, "la page défile à #{width} px (#{page_overflow.inspect})"
    inner = evaluate_script("(() => { const el = document.querySelector(#{container.to_json}); " \
                            "return [el.scrollHeight - el.clientHeight, el.scrollWidth - el.clientWidth]; })()")
    assert_equal [ 0, 0 ], inner.map { |v| [ v, 0 ].max }, "#{container} défile à #{width} px (#{inner.inspect})"
  end

  # Chaque tuile (grande et vignettes) reste dans sa zone et dans la
  # fenêtre ; la vidéo garde le ratio de la source.
  def assert_tiles_inside(width, zone)
    tiles = evaluate_script(<<~JS)
      (() => {
        const zone = document.querySelector(#{zone.to_json});
        const z = zone.getBoundingClientRect();
        return Array.from(zone.querySelectorAll('.lk-participant-tile')).map((t) => {
          const r = t.getBoundingClientRect();
          const video = t.querySelector('video');
          return { inside: r.top >= z.top - 1 && r.bottom <= z.bottom + 1 && r.left >= z.left - 1 && r.right <= z.right + 1
                           && r.bottom <= window.innerHeight && r.width > 0 && r.height > 0,
                   box: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)],
                   fit: video ? getComputedStyle(video).objectFit : null };
        });
      })()
    JS
    assert tiles.any?, "aucune tuile dans #{zone}"
    tiles.each do |tile|
      assert tile["inside"], "tuile #{tile['box'].inspect} hors de #{zone} à #{width} px"
      assert_includes [ nil, "contain" ], tile["fit"], "vidéo recadrée (object-fit: #{tile['fit']}) à #{width} px"
    end
  end

  def assert_controls_clickable(width)
    CONTROLS.each do |selector|
      hit = evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector("[data-testid='room-controls'] #{selector}");
          if (!el) return { found: false };
          const r = el.getBoundingClientRect();
          const target = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          return { found: true, clickable: !!target && (target === el || el.contains(target)),
                   inside: r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight };
        })()
      JS
      assert hit["found"], "#{selector} absent à #{width} px"
      assert hit["clickable"], "#{selector} recouvert à #{width} px"
      assert hit["inside"], "#{selector} hors de l'écran à #{width} px"
    end
  end

  def assert_no_overlap(first, second)
    a, b = evaluate_script(<<~JS)
      (() => {
        const box = (sel) => { const el = document.querySelector(sel); if (!el) return null;
          const r = el.getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom }; };
        return [box(#{first.to_json}), box(#{second.to_json})];
      })()
    JS
    assert a, "#{first} absent"
    assert b, "#{second} absent"
    disjoint = a["right"] <= b["left"] || b["right"] <= a["left"] || a["bottom"] <= b["top"] || b["bottom"] <= a["top"]
    assert disjoint, "#{first} #{a.inspect} chevauche #{second} #{b.inspect}"
  end
end
