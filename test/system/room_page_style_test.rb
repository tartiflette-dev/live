require "application_system_test_case"

# Incident d'affichage (« ça fonctionne,
# cependant pb d'affichage »).
#
# Le pendant POSITIF de room_chrome_isolation_test.rb. Celui-là verrouille
# « chrome.css ne fuit PAS vers la salle » ; personne ne vérifiait « la
# salle reçoit bien SA coquille ». Les deux invariants passaient donc
# simultanément avec ZÉRO style sur la page : body.room échappait à
# chrome.css comme prévu, et room.css n'existait pas.
#
# Symptôme constaté en pré-production : titre en Times New Roman, « Salle :
# test » / « 1 présent » / « En attente du démarrage… » en paragraphes nus,
# cadre blanc autour d'une scène LiveKit noire. La vidéo FONCTIONNAIT —
# @livekit/components-styles style ses composants, tous sous
# `[data-lk-theme] .lk-…`, donc l'INTÉRIEUR du <LiveKitRoom> uniquement.
#
# Pourquoi le style CALCULÉ et pas la présence du <link> : un <link> vers
# une feuille qui ne matche aucun sélecteur de la page se charge en 200 et
# ne style rien. Seul getComputedStyle distingue les deux cas — c'est
# précisément la confusion qui a laissé passer le bug.
class RoomPageStyleTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    # Webinaire EN LIVE : `WebinarsController#viewer`
    # ne rend la coquille salle (body.room, main.lk-page, #livekit-room) QUE
    # si state=live — sinon, layout `:application` sans ces marqueurs.
    # Les invariants CSS testés ici portent tous sur la salle → live requis.
    @webinar = Webinar.create!(
      title: "Kick-off Q4",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published",
      state: "live",
      started_at: Time.current
    )
    @prev_key    = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    @prev_url    = ENV["LIVEKIT_URL"]
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    # Même convention que room_react_render_test : la connexion WebRTC
    # échoue, la coquille est rendue quand même — et c'est elle qu'on teste.
    ENV["LIVEKIT_URL"] = "wss://livekit.invalid"
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
    ENV["LIVEKIT_URL"]        = @prev_url
  end

  test "la coquille salle est stylée (pas de retour au serif par défaut)" do
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "body.room"

    font = evaluate_script("getComputedStyle(document.body).fontFamily")
    refute_match(/times|^serif$/i, font,
      "body.room rend dans la police par défaut du navigateur " \
      "(#{font.inspect}) — room.css n'est pas appliquée. Symptôme exact " \
      "de l'incident d'affichage.")

    # Fond explicite : sans lui, cadre blanc autour d'une scène noire.
    bg = evaluate_script("getComputedStyle(document.body).backgroundColor")
    refute_includes [ "rgba(0, 0, 0, 0)", "transparent", "rgb(255, 255, 255)" ],
      bg,
      "body.room doit poser un fond explicite (obtenu : #{bg.inspect})"
  end

  # Aucune couleur en dur : la bannière fail-loud (room.jsx) et le point REC
  # (recording_control_styles.js) posent leurs couleurs en `var(--…)`
  # inline. Un token absent de la salle rendrait la bannière transparente
  # — exactement ce que le style inline devait empêcher.
  test "les tokens des styles inline de la salle sont résolus sur body.room" do
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "body.room"

    %w[--status-critical-dark --gray-925 --gray-350 --radius-card --font-sans].each do |token|
      value = evaluate_script("getComputedStyle(document.body).getPropertyValue('#{token}').trim()")
      refute_empty value, "#{token} doit être défini sur body.room (tokens charte chargés par layouts/room)"
    end
  end

  test "le titre de salle n'est pas un h1 nu" do
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "h1.lk-page__title"

    weight = evaluate_script(
      "getComputedStyle(document.querySelector('h1.lk-page__title'))" \
      ".fontWeight"
    ).to_i
    assert_operator weight, :>=, 600,
      "le titre doit être stylé par room.css (font-weight obtenu : #{weight})"
  end

  test "le point de montage React occupe la hauteur disponible" do
    # .lk-mount sans hauteur = scène LiveKit écrasée alors que la connexion
    # réussit : « ça marche mais on ne voit rien ».
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "main.lk-page #livekit-room.lk-mount"

    height = evaluate_script(
      "document.getElementById('livekit-room').getBoundingClientRect().height"
    ).to_f
    assert_operator height, :>, 200,
      "#livekit-room fait #{height}px de haut — la scène est écrasée"
  end

  # CETTE assertion-CI est celle qui compte, et elle manquait au premier jet.
  #
  # Le test ci-dessus mesure `#livekit-room` — qui faisait bien 778px en
  # staging APRÈS le premier correctif. Il était donc VERT tandis que la
  # scène réellement visible, `.lk-viewer__stage`, faisait 89px : la page
  # était stylée mais la vidéo tenait dans un bandeau. Mesurer le conteneur
  # extérieur ne dit RIEN de ce que l'utilisateur voit.
  #
  # Cause : <LiveKitRoom> interpose `.lk-room-container` (vendor,
  # display:block) entre .lk-mount et .lk-viewer — donc `flex: 1` sur
  # .lk-viewer n'avait aucun effet, il fallait `height: 100%`.
  test "la scène spectateur remplit la hauteur, pas seulement le conteneur" do
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector ".lk-viewer__stage"

    mount, stage = evaluate_script(
      "[document.getElementById('livekit-room').getBoundingClientRect().height," \
      " document.querySelector('.lk-viewer__stage').getBoundingClientRect().height]"
    ).map(&:to_f)

    # La scène doit occuper l'essentiel du mount, pas un bandeau en haut.
    assert_operator stage, :>, mount * 0.6,
      "scène #{stage.round}px dans un mount de #{mount.round}px — la vidéo " \
      "tient dans un bandeau (symptôme mesuré : 89px dans 778px). Vérifier " \
      "que .lk-viewer a bien height:100% : <LiveKitRoom> interpose un " \
      ".lk-room-container en display:block, où flex:1 est sans effet."
  end

  test "la page salle ne déborde pas horizontalement en mobile" do
    # 390px = iPhone 14. Un débordement horizontal sur le lien PARTAGEABLE
    # de la salle est visible par tous les invités, pas seulement par l'animateur.
    Capybara.current_session.current_window.resize_to(390, 844)
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "body.room"

    overflow = evaluate_script(
      "document.documentElement.scrollWidth - " \
      "document.documentElement.clientWidth"
    ).to_i
    assert_operator overflow, :<=, 0,
      "débordement horizontal de #{overflow}px à 390px de large"
  ensure
    Capybara.current_session.current_window.resize_to(1400, 900)
  end
end
