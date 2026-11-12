require "application_system_test_case"

# Sondages du direct, de bout en bout : la console de
# la régie (poll_console.jsx) lance une question à la volée, la pop-up
# (poll_overlay.jsx) apparaît chez le spectateur ET dans la salle de
# l'animation, le spectateur répond, la régie voit qui a répondu quoi et
# montre le résultat à la salle.
#
# La console est montée dans la régie (/webinars/:id/regie), qui
# lui fournit le nombre de présents lu dans LiveKit. Comme la discussion
# (room_chat_test.rb), la CI n'a pas de LiveKit : la diffusion serveur est
# captée, puis remise à la Room de la page comme le ferait livekit-server.
class RoomPollsTest < JsSystemTestCase
  include OidcSignIn
  include LivekitRoomRecipe
  include LivekitPacketDelivery

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  # Salle vue par le serveur : deux présents (l'animation et un spectateur),
  # nombre que la régie passe à la console.
  class RoomWithAudience < LivekitPacketDelivery::RoomRecorder
    def list_participants(room:)
      %w[host-marc viewer-1].map { |identity| { identity: identity, kind: "STANDARD", name: identity, permission: { can_publish: false }, tracks: [] } }
    end
  end

  setup do
    @host = User.create!(email: "marc@example.test", oidc_sub: "sub-marc-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #8", starts_at: 1.hour.ago, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: 12.minutes.ago)
    @webinar.polls.create!(position: 1, kind: "scale", label: "Votre confiance ?", planned_minute: 30,
                           note: "après la démo", options: { min: 1, max: 5 })
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    @room = RoomWithAudience.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @room }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @previous_factory
    ENV.update(@saved_env)
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |key| ENV.delete(key) unless @saved_env.key?(key) }
  end

  test "depuis la régie : sondage créé à la volée et lancé, pop-up chez tous, réponse, 1 réponse et %, résultat montré" do
    in_browser(:regie) do
      sign_in_as(@host)
      visit webinar_regie_path(@webinar)
      item = find("[data-testid='poll-console-item']", text: "Votre confiance ?")
      assert_selector "[data-testid='poll-console-clock']", text: /Direct 12:\d\d/
      within(item) do
        assert_text "À 30 min · dans 18 min"
        assert_text "après la démo"
      end

      find("summary", text: "Nouvelle question").click
      # Frappe réelle : cf. RoomChatTest#send_message (remplissage rapide de Capybara).
      fill_in "Question", with: "Vous utilisez déjà un assistant IA ?", fill_options: { rapid: false }
      fill_in "Choix (un par ligne, 2 à 6)", with: "Tous les jours\nParfois\nJamais", fill_options: { rapid: false }
      click_on "Lancer maintenant"
      assert_selector "[data-testid='poll-console-item'][data-state='open']", text: "Vous utilisez déjà un assistant IA ?"
    end

    in_browser(:host) do
      open_stage
      deliver_broadcasts
      within("[data-testid='poll-overlay']") do
        assert_text "Vous utilisez déjà un assistant IA ?"
        assert_text(/sondage en cours/i)
      end
    end

    in_browser(:viewer) do
      confirm_viewer_registration(@webinar)
      visit public_webinar_path(slug: @webinar.slug)
      assert_selector "[data-testid='side-panel']", wait: 10
      deliver_broadcasts
      within("[data-testid='poll-overlay']") do
        assert_selector "h2", text: "Vous utilisez déjà un assistant IA ?"
        assert_selector "[data-testid='poll-consent']", text: "Réponse nominative : l'animation voit votre nom et votre réponse"
        assert_link "confidentialité", href: "/confidentialite"
        choose "Parfois"
        click_on "Répondre"
        assert_text "Réponse enregistrée"
        assert_button "Modifier ma réponse"
      end
      assert_no_selector "[data-testid='poll-results']"
    end

    in_browser(:regie) do
      within("[data-testid='poll-console-item'][data-state='open']") do
        assert_selector "[data-testid='poll-console-count']", text: "1 / 2 présents"
        within("[data-testid='poll-console-results']") do
          assert_selector "li", text: /Parfois\s*100 % \(1\)\s*Spectateur confirmé/
        end
        click_on "Montrer le résultat"
        assert_text "résultat affiché"
        click_on "Fermer"
      end
      assert_selector "[data-testid='poll-console-item'][data-state='closed']"
    end

    in_browser(:viewer) do
      deliver_broadcasts
      within("[data-testid='poll-overlay'][data-open='false']") do
        assert_text(/résultat du sondage/i)
        assert_selector "[data-testid='poll-results'] li", text: /Parfois\s*100 % \(1\)/
        assert_selector "[data-testid='poll-results'] li", text: /Jamais\s*0 % \(0\)/
        assert_no_button "Modifier ma réponse"
      end
      click_on "Réduire"
      assert_selector "[data-testid='poll-reduced']", text: "Résultat du sondage · Afficher"
    end
  end

  test "pop-up accessible au clavier : Échap la réduit, la pastille la rouvre ; sur téléphone, elle tient dans l'écran" do
    poll = @webinar.polls.create!(position: 2, kind: "short_text", label: "Un mot pour décrire ce café ?")
    poll.open!
    Capybara.current_session.current_window.resize_to(360, 780)
    confirm_viewer_registration(@webinar)
    visit public_webinar_path(slug: @webinar.slug)

    overlay = find("[data-testid='poll-overlay']", wait: 10)
    assert_equal "dialog", overlay["role"]
    assert_equal "false", overlay["aria-modal"]
    rect = evaluate_script("(() => { const r = document.querySelector(\"[data-testid='poll-overlay']\").getBoundingClientRect(); " \
                           "return [r.left, r.top, r.right, r.bottom, window.innerWidth, window.innerHeight]; })()")
    assert rect[0] >= 0 && rect[1] >= 0 && rect[2] <= rect[4] && rect[3] <= rect[5], "pop-up hors de l'écran : #{rect.inspect}"
    assert_equal "Nouveau sondage : Un mot pour décrire ce café ?", find("[data-testid='poll-announcement']", visible: :all).text(:all)

    fill_in "Votre réponse (200 caractères au plus)", with: "Concret"
    find_field("Votre réponse (200 caractères au plus)").send_keys(:escape)
    assert_no_selector "[data-testid='poll-overlay']"
    pill = find("[data-testid='poll-reduced']", text: "Sondage en cours · Répondre")
    assert_equal "false", pill["aria-expanded"]
    assert_equal find("[data-testid='poll-overlay']", visible: :hidden)["id"], pill["aria-controls"]
    pill.click
    click_on "Répondre"
    assert_text "Réponse enregistrée"
    assert_equal [ "Concret" ], poll.responses.pluck(:value)
  ensure
    Capybara.current_session.current_window.resize_to(1400, 900)
  end

  private

  def in_browser(name, &block)
    using_session(name, &block)
  end

  def open_stage
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)
    assert_selector "[data-testid='prejoin']", wait: 10
    fill_in "username", with: "Marc"
    find(".lk-join-button:not([disabled])", wait: 10).click
    assert_selector "[data-testid='stage']", wait: 10
  end

  # Tous les paquets diffusés par le serveur jusqu'ici, remis à la Room de
  # la page sans participant émetteur (= envoi serveur).
  def deliver_broadcasts
    @room.packets.each do |data|
      delivered = evaluate_script(<<~JS)
        (() => {
          #{FIND_ROOM_JS}
          if (!room) return false;
          room.emit('dataReceived', new TextEncoder().encode(#{data.to_json}), undefined);
          return true;
        })()
      JS
      assert delivered, "Room LiveKit introuvable"
    end
  end
end
