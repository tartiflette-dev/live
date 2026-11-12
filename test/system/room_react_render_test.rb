require "application_system_test_case"

# La régression que ce test ATTRAPE : le crash React « Rendered more hooks
# than during the previous render » qui
# rendait /w/<slug>/stage ET /w/<slug> BLANCHES en staging après le merge.
# La suite rack_test précédente vérifiait le HTML du container
# (data-attrs) mais N'EXÉCUTAIT PAS React → l'erreur runtime passait.
#
# Assertion cœur : après le montage React, le sous-arbre RENDU ne doit
# pas être vide. Peu importe QUOI est rendu (PreJoin, ViewerLayout ou
# bannière d'erreur si le backend LiveKit n'existe pas), ce doit être
# QUELQUE CHOSE de visible côté DOM. Un `#livekit-room:empty` = crash.
class RoomReactRenderTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    # Webinaire EN LIVE : `WebinarsController#viewer`
    # ne rend `:room` (montage LiveKit) QUE si state=live — sinon, page
    # avant-direct sans #livekit-room. Les assertions React (PreJoin,
    # #livekit-room non vide) exigent donc l'état live.
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
    # URL bidon : la connexion WebRTC échouera, mais le composant React
    # rendra QUELQUE CHOSE (PreJoin d'abord côté stage, waiting/error côté
    # viewer) — c'est l'invariant testé.
    ENV["LIVEKIT_URL"] = "wss://livekit.invalid"
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
    ENV["LIVEKIT_URL"]        = @prev_url
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  # STAGE — l'invariant (« ça doit me dire quel périphérique tu veux
  # prendre, pas un écran vide ») : PreJoin monté, dropdowns visibles,
  # bouton rejoindre présent. Attrape aussi le crash hooks (sans PreJoin
  # dans le DOM, on tomberait sur l'assert_no_selector empty).
  test "stage rend le PreJoin (sélecteurs périphériques + bouton rejoindre)" do
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)

    # Le container React doit être NON-VIDE (le crash hooks se manifeste
    # ici par un container qui reste à son innerHTML initial de <noscript>).
    assert_selector "#livekit-room", visible: :all
    assert_no_selector "#livekit-room:empty"

    # PreJoin monté : wrapper explicite + classe LiveKit standard.
    assert_selector "[data-testid='prejoin']", wait: 5
    assert_selector ".lk-prejoin", wait: 5

    # Sélecteurs de périphériques : deux menus device (mic + cam) exposés
    # par PreJoin (classe .lk-button-group-menu enveloppe .lk-device-menu).
    # `visible: :all` car le menu déroulant lui-même est masqué tant que
    # l'utilisateur ne l'ouvre pas — seul le bouton du groupe est visible.
    # L'invariant testé : les DEUX menus device sont dans le DOM.
    assert_selector ".lk-button-group-menu", minimum: 2

    # Bouton rejoindre présent avec le label FR configuré.
    assert_selector ".lk-join-button", text: "Rejoindre la salle"
  end

  # VIEWER — la salle spectateur monte LiveKitRoom directement (pas de
  # PreJoin, subscribe-only). Le backend LiveKit n'existant pas en test,
  # la connexion échoue → soit "Impossible de rejoindre" (fetchToken KO,
  # peu probable ici car /api/token répond 200), soit le ViewerLayout
  # avec "En attente du démarrage…" (aucune track subscribed).
  # L'important : QUELQUE CHOSE est rendu.
  test "viewer rend un contenu non-vide (waiting ou erreur)" do
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)

    assert_selector "#livekit-room", visible: :all
    assert_no_selector "#livekit-room:empty"

    # Un des deux états attendus doit apparaître dans un délai raisonnable.
    # Attente longue (10 s) car LiveKit tente la connexion WebRTC vers
    # livekit.invalid — peut prendre quelques secondes avant l'échec.
    Capybara.using_wait_time(10) do
      has_waiting = has_selector?(".lk-viewer__waiting", text: "En attente du démarrage")
      has_error   = has_selector?(".lk-status--error", text: "Impossible de rejoindre")
      has_viewer  = has_selector?(".lk-viewer")
      assert(has_waiting || has_error || has_viewer,
             "Aucun rendu attendu (waiting/error/viewer) dans #livekit-room — " \
             "possible crash React (regarder la console navigateur).")
    end
  end

  test "named invitation prepopulates PreJoin instead of a previously remembered name" do
    # Avant la bascule nominative (ou pour simuler un invité en cours),
    # on crée un Speaker anonyme à nommer plus tard. Le chemin legacy
    # signed_id a été supprimé : seuls les tokens
    # Speaker nominatifs résolvent.
    initial_speaker = @webinar.speakers.create!(name: "Visiteur sans nom")
    visit join_webinar_path(slug: @webinar.slug, t: initial_speaker.token)
    assert_selector "[data-testid='prejoin']", wait: 5
    fill_in "username", with: "Ancien nom"
    assert_field "username", with: "Ancien nom"

    speaker = @webinar.speakers.create!(name: "Basile")
    visit join_webinar_path(slug: @webinar.slug, t: speaker.token)
    assert_selector "[data-testid='prejoin']", wait: 5
    assert_field "username", with: "Basile"

    speaker.revoke!
    visit join_webinar_path(slug: @webinar.slug, t: speaker.token)
    assert_no_selector "#livekit-room"
    assert_no_selector "[data-testid='prejoin']"
  end

  # Sans invitation nominative (scène animateur), le nom saisi au PreJoin
  # est mémorisé d'une visite à l'autre (PreJoin maison, même mémoire du nom que le prefab vendor).
  test "le nom saisi par l'animateur revient à la visite suivante" do
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)
    fill_in "username", with: "Marc au micro"

    visit stage_webinar_path(slug: @webinar.slug)

    assert_field "username", with: "Marc au micro", wait: 5
  ensure
    execute_script("localStorage.removeItem('lk-user-choices')")
  end

  private

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: { email: user.email }
    )
    visit "/auth/pocket_id/callback"
  end
end
