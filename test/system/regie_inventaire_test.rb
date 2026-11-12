require "application_system_test_case"

# Régie rangée par moment (avant, pendant, après le direct) : « je veux pas perdre de
# lien ou de fonction, même si tu ranges différemment ». Inventaire de TOUTES
# les actions de la régie, et preuve que chacune reste atteignable à chaque
# moment où elle a un sens — directement, ou en ouvrant UN repli.
#
# Le vrai composant, les vrais endpoints ; la salle LiveKit est simulée
# (LivekitPacketDelivery::RoomRecorder) : elle coupe le micro et fait sortir
# la personne retirée comme le ferait livekit-server.
class RegieInventaireTest < JsSystemTestCase
  include OidcSignIn
  include LivekitPacketDelivery

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "x" * 32 # LiveKit simulé : aucun secret réel

  # Inventaire : action → moments où elle doit rester atteignable.
  ACTIONS = {
    "Démarrer le direct" => %w[draft],
    "Terminer le direct" => %w[live],
    "Reprendre le direct" => %w[ended],
    "Enregistrement" => %w[draft live ended],
    "Mettre en avant / revenir à la mosaïque" => %w[draft live ended],
    "Couper le micro / retirer" => %w[draft live ended],
    "Régénérer le lien intervenants (après un retrait)" => %w[draft live ended],
    "Mains levées" => %w[draft live ended],
    "Sondages : lancer, lire les résultats" => %w[draft live ended],
    "Questions : ajouter un message à la file" => %w[draft live ended],
    "Discussion : épingler, répondu" => %w[draft live],
    "Questions : file lisible" => %w[draft live ended],
    "Discussion et envoi" => %w[draft live],
    "Discussion lisible" => %w[draft live ended],
    "Envoyer un message aux inscrits" => %w[draft live ended],
    "Ouvrir la salle" => %w[draft live ended],
    "Inscrits" => %w[draft live ended],
    "Présence en salle (page détaillée)" => %w[draft live ended]
  }.freeze

  setup do
    @host = User.create!(email: "luc@example.test", oidc_sub: "sub-luc-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: 20.minutes.ago)
    @webinar.generate_share_token!
    @speaker = @webinar.speakers.create!(name: "Nicolas")
    @pierre = @webinar.registrations.create!(name: "Pierre", email: "pierre@example.test", confirmed_at: 1.day.ago)
    @alice = @webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: 1.day.ago)
    closed = @webinar.polls.create!(position: 1, kind: "choice", label: "Déjà un assistant IA ?", options: %w[Oui Non])
    closed.open!
    closed.respond!(identity: "viewer-#{@pierre.id}", name: "Pierre", value: [ 0 ], registration: @pierre)
    closed.close!
    @webinar.polls.create!(position: 2, kind: "choice", label: "On continue ?", options: %w[Oui Non])
    @webinar.messages.create!(author_identity: "viewer-#{@pierre.id}", name: "Pierre", body: "salut")
    @question = @webinar.messages.create!(author_identity: "viewer-#{@pierre.id}", name: "Pierre",
                                          body: "@animateur Le replay sera disponible ?")
    HandRaise.create!(webinar: @webinar, registration: @alice, state: "waiting", raised_at: Time.current)

    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    @room = RoomRecorder.new
    @room.participants = [
      person("speaker-#{@speaker.id}", "Nicolas", can_publish: true, tracks: [ microphone("TR_nicolas"), camera("TR_cam") ]),
      person("viewer-#{@pierre.id}", "Pierre")
    ]
    @previous_factories = Rails.configuration.x.room_service_client_factory, Rails.configuration.x.egress_client_factory
    egress = egress_stub
    Rails.configuration.x.room_service_client_factory = -> { @room }
    Rails.configuration.x.egress_client_factory = -> { egress }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory, Rails.configuration.x.egress_client_factory = @previous_factories
    @saved_env.each_key { |key| ENV[key] = @saved_env[key] }
    Capybara.current_session.current_window.resize_to(1400, 900)
  end

  { "draft" => "avant", "live" => "pendant", "ended" => "apres" }.each do |state, moment|
    test "inventaire #{moment} le direct : chaque action de la régie reste atteignable" do
      enter(state)
      assert_selector "[data-testid='regie-grille'][data-moment='#{moment}']"
      reached = ACTIONS.select { |_, states| states.include?(state) }.keys.index_with { |action| reach_action(action, state) }
      assert_equal ACTIONS.count { |_, states| states.include?(state) }, reached.size
      assert reached.values.all?, "actions inatteignables (#{moment}) : #{reached.reject { |_, ok| ok }.keys.inspect}"
    end
  end

  test "une seule zone Questions et une seule zone Discussion ; plus de filtre « Questions » dans le fil" do
    enter("live")
    assert_selector "[data-testid='qa-console']", count: 1
    assert_selector "[data-testid='discussion']", count: 1
    assert_no_selector "[data-testid='questions-panel']", visible: :all
    assert_equal 1, all("h2", text: /questions/i).size, "titres « Questions » : #{all('h2').map(&:text).inspect}"
    assert_equal 1, all("h2", text: /\Asondages\z/i).size, "titres « Sondages » : #{all('h2').map(&:text).inspect}"

    # La question adressée à @animateur se marque « Répondu » depuis le fil.
    within("[data-testid='discussion-messages'] [data-message-id='#{@question.id}']") { click_on "Répondu" }
    within("[data-testid='discussion-messages'] [data-message-id='#{@question.id}']") do
      assert_text(/question répondue/i, wait: 10)
      assert_no_button "Répondu"
    end
    assert @question.reload.answered_at
  end

  test "pendant : ce que la scène montre déjà est replié, une main levée ouvre son repli d'elle-même" do
    enter("live")
    assert_no_selector "[data-testid='regie-spotlight-section'][open]"
    assert_no_selector "[data-testid='regie-spotlight-toggle']"
    within("[data-testid='regie-spotlight-section'] summary") { assert_text(/mise en avant/i) }

    assert_selector "[data-testid='regie-hands'][open]", wait: 10
    within("[data-testid='regie-hands'] summary") { assert_text "1 main levée" }
    assert_selector "[data-testid='hand-raise-grant']", text: "Donner la parole"
  end

  test "« Régénérer le lien intervenants » n'est plus permanent : il est proposé après un retrait" do
    enter("live")
    within("[data-testid='regie-participants']") do
      assert_selector "[data-testid='regie-participant']", count: 2, wait: 10
      assert_no_selector "[data-testid='regie-share-link-regenerate']"
    end
    remove("viewer-#{@pierre.id}")
    within("[data-testid='regie-participants']") do
      assert_selector "[data-testid='regie-removal-notice']", text: "Retrait de Pierre confirmé.", wait: 10
      assert_selector "[data-testid='regie-share-link-regenerate']", text: "Régénérer le lien intervenants"
    end
  end

  test "aide de la modération repliée sous « En savoir plus », jamais supprimée" do
    enter("live")
    help = "navigation privée"
    assert_no_text help
    within("[data-testid='regie-participants']") { find("summary", text: "En savoir plus").click }
    assert_text help
    assert_text "mêmes cookies"
  end

  test "après : bilan, plus de « Direct non démarré », reprise discrète, discussion en lecture seule" do
    @webinar.update!(state: "ended", ended_at: @webinar.started_at + 61.minutes)
    enter("ended")
    within("[data-testid='regie-header']") do
      assert_selector "[data-testid='regie-bilan']", text: /\ADirect de \d{1,2}:\d\d à \d{1,2}:\d\d · 1:01:00\z/
      assert_selector "[data-testid='state-button']", exact_text: "Reprendre le direct"
    end
    assert_no_text "Direct non démarré"
    assert_selector "[data-testid='poll-console-clock']", exact_text: "Direct terminé"
    assert_no_selector "[data-testid='regie-participants-section'][open]"
    assert_no_selector "#lk-discussion-draft"
    assert_selector "[data-testid='discussion-closed']", text: "Le direct est terminé : la discussion est close."
    assert_no_button "Épingler"
    # Après la fin, une main restée levée n'ouvre plus son repli.
    within("[data-testid='regie-hands'] summary") { assert_text "1 main levée", wait: 10 }
    assert_no_selector "[data-testid='regie-hands'][open]"

    # La file reste : un message s'y ajoute encore, rien ne s'affiche plus à l'écran.
    within("[data-testid='discussion-messages'] [data-message-id='#{@question.id}']") { click_on "Ajouter à la file" }
    within("[data-testid='qa-console']") do
      assert_text "Le replay sera disponible ?", wait: 10
      assert_button "Répondue"
      assert_no_button "Afficher à l'écran"
    end

    # « Reprendre » : visible, mais sans le poids d'une commande de direct.
    m = evaluate_script(<<~JS)
      (() => {
        const resume = getComputedStyle(document.querySelector("[data-testid='state-button']"));
        return { weight: Number(resume.fontWeight), bg: resume.backgroundColor, height: document.querySelector("[data-testid='state-button']").getBoundingClientRect().height };
      })()
    JS
    assert_operator m["weight"], :<, 700, "« Reprendre le direct » garde le poids d'une commande"
    assert_equal "rgba(0, 0, 0, 0)", m["bg"]
    assert_operator m["height"], :>=, 44
  end

  private

  def enter(state, width: 1400, height: 900)
    case state
    when "draft" then @webinar.update!(state: "draft", started_at: nil)
    when "ended" then @webinar.update!(state: "ended", ended_at: @webinar.ended_at || Time.current)
    end
    Capybara.current_session.current_window.resize_to(width, height)
    sign_in_as(@host)
    visit webinar_regie_path(@webinar)
    assert_selector "[data-testid='regie-state'][data-state='#{state}']", wait: 10
    assert_selector "[data-testid='regie-present']", text: /présent/, wait: 10
  end

  # Rend l'élément visible, en ouvrant au plus UN repli (summary cliqué).
  # @return true si l'élément est visible ensuite
  def reach(selector, **options)
    element = find(selector, visible: :all, match: :first, wait: 10, **options)
    unless element.visible?
      summary = element.find(:xpath, "ancestor::details[not(@open)][last()]/summary", visible: :all)
      scroll_to(summary, align: :center) # jamais sous la bande basse fixe du chrome
      summary.click
    end
    element.visible?
  end

  def reach_action(action, state)
    case action
    when /\A(Démarrer|Terminer|Reprendre) le direct\z/
      reach("[data-testid='state-button']", exact_text: action)
    when "Enregistrement" then reach("[data-testid='recording-control']")
    when "Mettre en avant / revenir à la mosaïque"
      reach("[data-testid='regie-spotlight-toggle']", text: "Mettre en avant") && reach("[data-testid='regie-spotlight-clear']")
    when "Couper le micro / retirer"
      reach("[data-testid='regie-participant-mute']") && reach("[data-testid='regie-participant-remove']")
    when "Régénérer le lien intervenants (après un retrait)"
      reach("[data-testid='regie-participant-remove']")
      remove("speaker-#{@speaker.id}")
      reach("[data-testid='regie-share-link-regenerate']", text: "Régénérer le lien intervenants")
    when "Mains levées" then reach("[data-testid='hand-raise-grant']", text: "Donner la parole")
    when "Sondages : lancer, lire les résultats"
      launch = find("[data-poll-id] button", text: /\ALancer\z/, visible: :all, wait: 10)
      reach("[data-testid='poll-console']") && launch.visible? && (state == "live") == !launch.disabled? &&
        reach("button", text: "Qui a répondu ?") && reach(".poll-console__new summary")
    when "Questions : ajouter un message à la file"
      within("[data-testid='discussion-messages'] [data-message-id='#{@question.id}']") do
        reach("[data-testid='discussion-enqueue']")
      end
    when "Discussion : épingler, répondu"
      within("[data-testid='discussion-messages'] [data-message-id='#{@question.id}']") do
        reach("button", text: "Épingler") && reach("button", text: "Répondu")
      end
    when "Questions : file lisible" then reach("[data-testid='qa-console']")
    when "Discussion et envoi" then reach("#lk-discussion-draft") && reach("button", text: "Envoyer")
    when "Discussion lisible" then reach("[data-testid='discussion-messages']", text: "salut")
    when "Envoyer un message aux inscrits" then reach("a[data-role='announcement-new']")
    when "Ouvrir la salle" then reach("a[data-testid='regie-open-room']")
    when "Inscrits" then reach("[data-testid='regie-registrations']", text: "Alice")
    when "Présence en salle (page détaillée)" then reach("a[data-testid='regie-room-presence-link']")
    else flunk "action sans preuve : #{action}"
    end
  end

  def remove(identity)
    row = find("[data-testid='regie-participant'][data-identity='#{identity}']", wait: 10)
    scroll_to(row, align: :center) # jamais sous la bande basse fixe du chrome
    within(row) do
      click_on "Retirer"
      sleep 0.6 # au-delà de la garde anti double-clic (500 ms)
      click_on "Confirmer le retrait ?"
    end
  end

  def person(identity, name, can_publish: false, tracks: [])
    { identity: identity, kind: "STANDARD", name: name, permission: { can_publish: can_publish }, tracks: tracks }
  end

  def microphone(sid) = { sid: sid, type: "AUDIO", source: "MICROPHONE", muted: false }
  def camera(sid) = { sid: sid, type: "VIDEO", source: "CAMERA", muted: false }

  def egress_stub
    stub = Object.new
    def stub.start_room_composite(**) = { egress_id: "EG_#{SecureRandom.hex(3)}", status: :active, raw: nil }
    def stub.stop(egress_id:) = { egress_id: egress_id, status: :ending, raw: nil }
    def stub.list_egress(egress_id:) = { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    stub
  end
end
