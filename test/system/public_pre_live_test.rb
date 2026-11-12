require "application_system_test_case"

# Page publique avant-direct.
#
# Driver : selenium_chrome_headless via JsSystemTestCase (même socle que
# room_react_render_test.rb) — countdown.js s'exécute réellement, on peut
# donc lire le libellé calculé côté client.
#
# Choix de couverture :
#   • rendu ERB + monté du compte à rebours + présence des data-attrs
#     nécessaires au polling → TESTÉ ICI (bout-en-bout Chrome headless) ;
#   • bascule effective vers la salle au passage state=live → TESTÉE
#     MÉCANIQUEMENT au contrôleur (`public_page_live_and_ended`), car
#     stubber state.json côté navigateur avec CDP est fragile et introduit
#     de la flakiness pour un invariant qu'un test contrôleur couvre
#     déterministement. Le test système vérifie ici que le POLLING EST
#     BRANCHÉ (data-state-url + intervalle observable), pas son résultat.
class PublicPreLiveTest < JsSystemTestCase
  # Les clés LiveKit factices restent posées (helper existant, cf.
  # room_react_render_test.rb) au cas où l'application tenterait un
  # montage : sur pre_live, AUCUN #livekit-room ne doit apparaître.
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(
      title: "Café IA — automne",
      description: "Deux heures de démonstration collective.",
      starts_at: 2.hours.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published",
      kind: "cafe_ia"
    )
    @prev_key    = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    @prev_url    = ENV["LIVEKIT_URL"]
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
    ENV["LIVEKIT_URL"]        = @prev_url
  end

  test "pre_live rend le titre, la description et un compte à rebours actif" do
    visit public_webinar_path(slug: @webinar.slug)

    assert_selector "h1", text: "Café IA — automne"
    assert_text "Deux heures de démonstration collective."

    # Marqueur pre_live sans LiveKit.
    assert_selector "[data-role='pre-live']"
    assert_no_selector "#livekit-room"

    # Compte à rebours branché : data-attrs indispensables au polling.
    countdown = find("[data-countdown]")
    assert_equal @webinar.starts_at.iso8601, countdown["data-starts-at"]
    assert_equal "/w/#{@webinar.slug}/state.json", countdown["data-state-url"]

    # Libellé calculé par countdown.js : format hh:mm:ss (ou j hh:mm:ss).
    # Attente courte : le premier tick est synchrone au montage.
    assert_selector "[data-countdown-time]",
                    text: /\A(?:\d+ j )?\d{2}:\d{2}:\d{2}\z/,
                    wait: 5
  end

  test "pre_live ended affiche « café terminé » sans compte à rebours" do
    @webinar.update!(state: "ended", started_at: 3.hours.ago, ended_at: 1.hour.ago)
    visit public_webinar_path(slug: @webinar.slug)

    # Charte : `.etat` applique `text-transform: uppercase` — le texte
    # source « Ce café est terminé. » s'affiche en majuscules côté
    # navigateur. Regex insensible à la casse pour rester tolérant à la
    # présentation sans doublonner le contrat sémantique.
    assert_selector "[data-role='pre-live-ended']", text: /café est termin/i
    assert_no_selector "[data-countdown]"
    assert_no_selector "#livekit-room"
  end

  test "going live without confirmation reloads once into the registration page" do
    previous_privacy_url = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/privacy"
    visit public_webinar_path(@webinar.slug)
    assert_selector "[data-countdown]"
    @webinar.update!(state: "live", started_at: Time.current)
    assert_selector "[data-role='live-registration-required']", wait: 20
    assert_selector "body.chrome-canvas"
    assert_selector "form[action='#{public_webinar_registrations_path(@webinar.slug)}']"
    assert_no_selector "[data-countdown]"
    assert_no_selector "#livekit-room"
    result = page.driver.browser.execute_async_script(<<~JS)
      const done = arguments[0];
      fetch('/api/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '' },
        body: JSON.stringify({ slug: #{JSON.generate(@webinar.slug)} })
      }).then(async response => done({ status: response.status, body: await response.json() }));
    JS
    assert_equal 403, result.fetch("status")
    assert_equal "registration_required", result.fetch("body").fetch("error")
  ensure
    ENV["REGISTRATION_PRIVACY_URL"] = previous_privacy_url
  end
end
