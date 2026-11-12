require "application_system_test_case"

# File Q&R extraite du chat — bout en bout, deux navigateurs :
# un spectateur inscrit écrit dans LA discussion de la salle ; le job
# d'extraction (LLM local SIMULÉ : aucun appel réseau ni GPU) range la
# question ; l'animation la voit dans la console de la régie
# (/webinars/:id/regie), l'affiche à l'écran (bandeau chez le spectateur),
# puis la marque répondue. Depuis le fil de la régie, « Ajouter à la file »
# range à la main un message que l'analyse n'a pas retenu.
class QaRoomTest < JsSystemTestCase
  include OidcSignIn
  include ActiveJob::TestHelper
  include QaLlmStubbing
  include LivekitPacketDelivery

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "marc@example.test", oidc_sub: "sub-marc-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #8 — veille et agents", starts_at: 1.hour.ago, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    @room = RoomRecorder.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @room }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @previous_factory
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @saved_env[k] }
  end

  test "une question du chat arrive reformulée dans la console, s'affiche chez le spectateur, puis est répondue" do
    using_session(:viewer) do
      confirm_viewer_registration(@webinar)
      visit public_webinar_path(slug: @webinar.slug)
      assert_selector "[data-testid='side-panel']", wait: 10
      execute_script("localStorage.setItem('undust-live:side-panel:collapsed', '0')")
      assert_selector "[data-testid='discussion-privacy'] a[href='/confidentialite']",
                      text: "confidentialité", visible: :all
      assert_selector "[data-testid='discussion-privacy']", text: "hébergé chez Studio Exemple pour regrouper", visible: :all
      # Frappe réelle : cf. RoomChatTest#send_message (remplissage rapide de Capybara).
      fill_in "Votre message", with: "du coup on peut faire tourner tout ça chez soi sans payer openai ?",
                               fill_options: { rapid: false }
      click_on "Envoyer"
      assert_selector "[data-message-id]", text: "sans payer openai"
      assert_no_selector "[data-testid='qa-banner']"
    end

    llm = FakeLlmClient.new(FakeLlmClient.verdict(is_question: true, reformulation: "Peut-on auto-héberger la veille sans OpenAI ?"))
    with_llm(llm) { perform_enqueued_jobs(only: QaExtractionJob) }
    assert_equal 1, llm.prompts.size

    using_session(:host) do
      sign_in_as(@host)
      visit webinar_regie_path(@webinar)
      within("[data-testid='qa-console']") do
        assert_text(/questions \(1\)/i)
        item = find("[data-qa-item-id]", text: "Peut-on auto-héberger la veille sans OpenAI ?")
        within(item) do
          assert_text "1 personne · Spectateur confirmé"
          find("summary", text: "Messages d'origine (1)").click
          assert_text "du coup on peut faire tourner tout ça chez soi sans payer openai ?"
          click_on "Afficher à l'écran"
          assert_button "Retirer de l'écran"
        end
      end
    end

    using_session(:viewer) do
      assert deliver_packet(@room.packets.last), "Room LiveKit introuvable"
      assert_selector "[data-testid='qa-banner']", text: "Peut-on auto-héberger la veille sans OpenAI ?"
    end

    using_session(:host) do
      within("[data-testid='qa-console']") do
        click_on "Répondue"
        assert_text(/questions \(0\)/i)
        assert_text "Aucune question en attente."
        find("summary", text: "Traitées (1)").click
        assert_selector "[data-qa-item-id][data-status='answered']", text: /répondue/i
      end
    end
    assert_predicate @webinar.qa_items.sole, :answered?

    using_session(:viewer) do
      assert deliver_packet(@room.packets.last)
      assert_no_selector "[data-testid='qa-banner']"
    end
  end

  test "une question @animateur entre dans la file de la régie ; affichée, le bandeau apparaît chez le spectateur" do
    using_session(:viewer) do
      confirm_viewer_registration(@webinar)
      visit public_webinar_path(slug: @webinar.slug)
      assert_selector "[data-testid='side-panel']", wait: 10
      execute_script("localStorage.setItem('undust-live:side-panel:collapsed', '0')")
      fill_in "Votre message", with: "@animateur Quel modèle tourne derrière la démo ?", fill_options: { rapid: false }
      click_on "Envoyer"
      assert_selector "[data-message-id]", text: "Quel modèle tourne derrière la démo ?"
    end
    # Analyse coupée (repli) : la mention entre telle quelle, sans LLM.
    perform_enqueued_jobs(only: QaExtractionJob)

    using_session(:host) do
      sign_in_as(@host)
      visit webinar_regie_path(@webinar)
      within("[data-testid='regie-qa'] [data-testid='qa-console']") do
        within(find("[data-qa-item-id]", text: "Quel modèle tourne derrière la démo ?", wait: 10)) do
          click_on "Afficher à l'écran"
          assert_button "Retirer de l'écran"
        end
      end
    end

    using_session(:viewer) do
      assert deliver_packet(@room.packets.last), "Room LiveKit introuvable"
      assert_selector "[data-testid='qa-banner']", text: "Quel modèle tourne derrière la démo ?"
    end
  end

  test "« Ajouter à la file » depuis le fil de la régie : la question entre aussitôt, sans doublon" do
    message = @webinar.messages.create!(author_identity: "viewer-7", name: "Bob", body: "Et pour les PME, ça coûte combien ?")
    sign_in_as(@host)
    visit webinar_regie_path(@webinar)
    within("[data-testid='regie-qa']") { assert_text "Aucune question en attente.", wait: 10 }
    assert_selector "[data-testid='regie-discussion'] [data-testid='discussion-privacy']",
                    text: "hébergé chez Studio Exemple pour regrouper", visible: :all

    within("[data-testid='regie-discussion'] [data-message-id='#{message.id}']") { click_on "Ajouter à la file" }
    within("[data-testid='regie-discussion']") { assert_text "Ajouté à la file des questions." }
    within("[data-testid='regie-qa']") do
      item = find("[data-qa-item-id]", text: "Et pour les PME, ça coûte combien ?", wait: 3)
      within(item) { assert_text "1 personne · Bob" }
    end

    # La file a grandi au-dessus du fil : le bouton a pu passer sous la bande
    # basse fixe du chrome, on le ramène au centre comme le ferait un humain.
    again = find("[data-testid='regie-discussion'] [data-message-id='#{message.id}'] [data-testid='discussion-enqueue']")
    scroll_to(again, align: :center)
    again.click
    within("[data-testid='regie-discussion']") { assert_text "Ce message est déjà dans la file des questions." }
    assert_equal 1, @webinar.qa_items.count
    assert_equal "manual", @webinar.qa_items.sole.source
  end
end
