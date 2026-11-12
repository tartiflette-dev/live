require "application_system_test_case"

# États du contrôle d'enregistrement. Cas observé en production : chaque egress composite avortait
# en ~15 s (bug infra) pendant que les pistes enregistraient ; la
# scène, elle, mentait :
#   - « Arrêter » ne réagissait pas, un second clic relançait un egress ;
#   - « REC (démarrage) » restait affiché après l'arrêt du direct et après
#     rechargement (c'était le montage ffmpeg d'une piste, pas le direct) ;
#   - la pastille restait rouge sans dire pourquoi.
#
# Ce test exerce le vrai contrôle React contre les vrais endpoints, avec un
# egress scripté : le test décide de ce que livekit répond (STARTING,
# ACTIVE, ABORTED) et peut retenir un arrêt pour observer l'état
# intermédiaire.
#
# Le contrôle vit dans la régie (/webinars/:id/regie),
# plus dans la salle : la scène est visitée d'abord pour son
# auto-démarrage (WebinarsController#stage), puis la régie pilote.
class RegieRecordingControlStatesTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  CONTROL = "[data-testid='recording-control']".freeze

  # Egress composite scripté. Partagé avec le serveur Capybara (même
  # processus, autre thread) : compteurs sous verrou.
  class ScriptedEgress
    attr_accessor :composite_status, :start_error

    def initialize
      @composite_status = :starting
      @start_error = nil
      @starts = 0
      @stops = 0
      @lock = Mutex.new
      @stop_gate = nil
    end

    def starts = @lock.synchronize { @starts }
    def stops  = @lock.synchronize { @stops }

    def start_room_composite(room_name:, filepath:)
      @lock.synchronize { @starts += 1 }
      raise EgressClient::RemoteError, start_error if start_error

      { egress_id: "EG_composite_#{SecureRandom.hex(4)}", status: :starting, raw: nil }
    end

    # Les pistes (créées en base par le test) restent actives ; seul le
    # composite suit le scénario.
    def list_egress(egress_id:)
      status = egress_id.start_with?("EG_composite_") ? composite_status : :active
      { egress_id: egress_id, status: status, ended_at: 0,
        error: (status == :aborted ? "Start signal not received" : nil), raw: nil }
    end

    def stop(egress_id:)
      @lock.synchronize { @stops += 1 }
      @stop_gate&.pop(timeout: 15)
      { egress_id: egress_id, status: :ending, raw: nil }
    end

    def hold_stops!    = @stop_gate = Queue.new
    def release_stops! = @stop_gate&.push(:go)
  end

  class RoomStub
    def create_room(name:) = { name: name }
    def list_participants(room:) = []
    def room_metadata(room:) = ""
  end

  # Retarde le démarrage du composite AVANT l'insertion, comme un create dont
  # la réconciliation traîne : un poll parti au clic lit la base d'avant
  # l'action et revient avant la réponse du POST. Inactif par défaut.
  module SlowCompositeStart
    class << self
      attr_accessor :delay
    end

    def start_composite(...)
      sleep SlowCompositeStart.delay if SlowCompositeStart.delay
      super
    end
  end
  RecordingSession.singleton_class.prepend(SlowCompositeStart)

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(title: "test-29-10", starts_at: 1.day.from_now, host_sub: @host.oidc_sub,
                               visibility: "published")
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    @prev_egress = Rails.configuration.x.egress_client_factory
    @prev_room   = Rails.configuration.x.room_service_client_factory
    @egress = ScriptedEgress.new
    egress = @egress
    room = RoomStub.new
    Rails.configuration.x.egress_client_factory       = -> { egress }
    Rails.configuration.x.room_service_client_factory = -> { room }
  end

  teardown do
    SlowCompositeStart.delay = nil
    @egress.release_stops!
    Rails.configuration.x.egress_client_factory       = @prev_egress
    Rails.configuration.x.room_service_client_factory = @prev_room
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @saved_env[k] }
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "démarrage puis abort : « Démarrage… » sans REC, puis échec visible et « Réessayer »" do
    enter_regie

    assert_control_state "starting"
    assert_selector "[data-testid='recording-start'][disabled]", exact_text: "Démarrage…"
    assert_no_text "REC"

    @egress.composite_status = :aborted

    assert_control_state "failed"
    assert_selector "[data-testid='recording-error']", text: "Enregistrement en échec."
    assert_selector "[data-testid='recording-start']:not([disabled])", exact_text: "Réessayer"
    assert_no_selector "[data-testid='recording-error-details'][open]"
    assert_selector "[data-testid='recording-dot'][data-active='false']"
    assert_no_text "REC"
  end

  test "vue d'ensemble en échec pendant que les pistes enregistrent : échec partiel, pas un échec total" do
    %w[camera microphone].each do |source|
      @webinar.recordings.create!(kind: :track, status: :recording, egress_id: "EG_track_#{source}",
                                  track_sid: "TR_#{source}", participant_identity: "host-#{@host.oidc_sub}",
                                  track_source: source, output_prefix: "#{@webinar.slug}/#{source}",
                                  started_at: 1.minute.ago)
    end
    @egress.composite_status = :aborted
    enter_regie

    assert_control_state "failed"
    assert_selector "#{CONTROL}.is-partial"
    assert_selector "[data-testid='recording-error']", text: "Vue d'ensemble en échec, pistes individuelles en cours."
    assert_selector "[data-testid='recording-dot'][data-active='true']"
    assert_selector "[data-testid='recording-start']", exact_text: "Réessayer"
  end

  test "cycle complet : démarrage, REC une fois l'egress actif, « Arrêt… » clignotant, puis arrêté" do
    enter_regie
    assert_control_state "starting"

    @egress.composite_status = :active
    assert_control_state "recording"
    assert_selector "[data-testid='recording-status']", exact_text: "REC"

    @egress.hold_stops!
    click_button "Arrêter l'enregistrement"

    assert_control_state "stopping"
    assert_selector "#{CONTROL}.is-stopping"
    assert_selector "[data-testid='recording-stop'][disabled]", exact_text: "Arrêt…"
    assert_equal "regie-rec-blink", evaluate_script(
      "getComputedStyle(document.querySelector(\"[data-testid='recording-stop']\")).animationName"
    ), "le bouton doit clignoter pendant l'arrêt"

    @egress.release_stops!

    assert_control_state "idle"
    assert_selector "[data-testid='recording-start']", exact_text: "Enregistrer"
    assert_selector "[data-testid='recording-dot'][data-active='false']"
    assert_equal "done", @webinar.recordings.composite.sole.status
  end

  test "rechargement pendant l'enregistrement : la régie reprend l'état du serveur" do
    enter_regie
    @egress.composite_status = :active
    assert_control_state "recording"

    enter_regie

    assert_control_state "recording"
    assert_selector "[data-testid='recording-stop']:not([disabled])", exact_text: "Arrêter l'enregistrement"
    assert_equal 1, @egress.starts, "le rechargement ne relance pas d'egress"
  end

  test "double clic sur « Arrêter » qui déborde sur « Enregistrer » : un seul arrêt, aucun egress relancé" do
    enter_regie
    @egress.composite_status = :active
    assert_control_state "recording"
    assert_selector "[data-testid='recording-stop']:not([disabled])", wait: 3
    @egress.hold_stops!

    execute_script("const b = document.querySelector(\"[data-testid='recording-stop']\"); b.click(); b.click();")
    assert_control_state "stopping"
    @egress.release_stops!
    late_click_disabled = click_as_soon_as_button_reads("Enregistrer")

    assert_equal true, late_click_disabled, "le bouton fraîchement redevenu « Enregistrer » doit ignorer le clic de la rafale"
    assert_control_state "idle"
    sleep 1.5
    assert_equal 1, @egress.stops, "un seul ordre d'arrêt"
    assert_equal 1, @egress.starts, "aucun egress relancé (seul l'auto-démarrage de la scène)"
    assert_equal 1, @webinar.recordings.composite.count
  end

  test "double clic sur « Réessayer » : un seul nouvel egress" do
    @egress.start_error = "egress injoignable : refused"
    enter_regie
    assert_control_state "failed"
    @egress.start_error = nil

    find("[data-testid='recording-start']", exact_text: "Réessayer").double_click

    assert_control_state "starting"
    sleep 1
    assert_equal 2, @egress.starts, "auto-démarrage + UN seul redémarrage"
  end

  test "réponse du clic jamais écrasée par un poll parti avant elle : l'ancien échec ne réapparaît pas" do
    @egress.start_error = "egress injoignable : refused"
    enter_regie
    assert_control_state "failed"
    @egress.start_error = nil
    record_control_states
    SlowCompositeStart.delay = 0.4

    click_button "Réessayer"

    assert_control_state "starting"
    sleep 1.5
    refute_includes recorded_control_states, "failed", "l'état d'avant le clic est revenu : #{recorded_control_states.inspect}"
  end

  test "démarrage bloqué au-delà de 20 s : signalé, et annulable par « Arrêter »" do
    enter_regie
    assert_control_state "starting"

    assert_selector "[data-testid='recording-status']", exact_text: "Démarrage toujours en attente du serveur", wait: 25
    find("[data-testid='recording-stop']:not([disabled])", exact_text: "Arrêter l'enregistrement", wait: 3).click

    assert_control_state "idle"
    assert_equal 1, @egress.stops
    assert_equal "done", @webinar.recordings.composite.sole.status
  end

  private

  # Toutes les valeurs prises par data-state à partir de maintenant, même
  # celles qui ne durent qu'une frame.
  def record_control_states
    execute_script(<<~JS)
      window.__recordingStates = [];
      const control = document.querySelector("#{CONTROL}");
      new MutationObserver(() => window.__recordingStates.push(control.dataset.state))
        .observe(control, { attributes: true, attributeFilter: ["data-state"] });
    JS
  end

  def recorded_control_states
    evaluate_script("window.__recordingStates")
  end

  # Scène d'abord (auto-démarrage de l'enregistrement, sans entrer dans la
  # salle), puis la régie, où vit le contrôle.
  def enter_regie
    sign_in_as(@host)
    visit stage_webinar_path(slug: @webinar.slug)
    visit webinar_regie_path(@webinar)
    assert_selector CONTROL, wait: 10
  end

  def assert_control_state(state)
    assert_selector "#{CONTROL}[data-state='#{state}']", wait: 10
  end

  # Le clic arrive dès que le bouton change de libellé, comme le dernier
  # clic d'une rafale : renvoie l'état `disabled` vu à cet instant.
  def click_as_soon_as_button_reads(label)
    evaluate_async_script(<<~JS, label)
      const [label, done] = arguments;
      const startedAt = Date.now();
      (function poll() {
        const button = document.querySelector("#{CONTROL} button");
        if (button && button.textContent === label) { button.click(); done(button.disabled); return; }
        if (Date.now() - startedAt > 8000) { done("libellé jamais affiché"); return; }
        setTimeout(poll, 10);
      })();
    JS
  end

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub, info: { email: user.email }
    )
    visit "/auth/pocket_id/callback"
  end
end
