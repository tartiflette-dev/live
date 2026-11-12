require "application_system_test_case"

# Filtre d'affichage (« les transcriptions ne sont pas
# nettoyées ») : le panneau affichait tel quel le bruit de Whisper, phrases
# fantômes apprises sur des génériques (« Sous-titrage Société
# Radio-Canada » sous le nom d'un participant) et hésitations isolées (« Euh… »).
# Puis (même soir) : des phrases de Basile dites « il y a super
# longtemps » mêlées aux récentes. Le flux ne porte aucune heure de parole
# (heure d'ENVOI seulement) : le panneau garde l'ordre d'arrivée et retire
# les doublons ; écarter un segment en retard revient au transcripteur.
#
# Le filtre est d'AFFICHAGE (transcript_filter.js, transcript_feed.jsx) :
# rien n'est retiré de l'archive. Le test passe par le vrai panneau. La CI
# n'a pas de LiveKit (livekit.invalid, comme les autres tests salle) et
# components-react se désabonne des text streams tant que la Room est
# « disconnected » : une fois la connexion échouée, le test repasse la Room
# à « connected » (setAndEmitConnectionState, interne livekit-client), puis
# appelle le gestionnaire `lk.transcription` que le panneau a enregistré,
# avec des segments finaux tels que les publie le transcripteur.
class TranscriptFilterTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  SHOWN = [
    "Bonjour à tous, bienvenue au Café IA.",
    "Bonjour, euh, tout le monde",
    "Aujourd'hui on va parler d'agents.",
    "Ben oui, c'est ça.",
    "Heureusement, ça marche.",
    "Humain avant tout."
  ].freeze

  HIDDEN = [
    "Sous-titrage Société Radio-Canada",
    "SOUS-TITRAGE ST' 501",
    "Sous-titres réalisés par la communauté d'Amara.org",
    "Merci d'avoir regardé cette vidéo.",
    "merci d’avoir regarde cette video !",
    "Amara.org",
    "Euh…",
    "Hum.",
    "Bah.",
    "Euh, euh... hmmm",
    "Mhm",
    "Euh, sous-titrage Société Radio-Canada",
    "Sous-titres fait par la communauté d'Amara.org",
    "Sous-titres faits par la communauté d'Amara.org",
    "N'oubliez pas de vous abonner à la chaîne",
    "Thanks for watching!"
  ].freeze

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
  end

  test "phrases fantômes et hésitations isolées masquées, hésitation de tête retirée, le reste intact" do
    open_viewer_room
    publish_segments(HIDDEN.first(3) + [ SHOWN[0] ] + HIDDEN.drop(3) + SHOWN.drop(1) +
                     [ "Euh, donc on commence.", "Euh - et voilà.", "Hum, humain", "Mhm, d'accord." ])

    expected = SHOWN + [ "Donc on commence.", "Et voilà.", "Humain", "D'accord." ]
    assert_selector ".lk-transcript__entry", count: expected.size
    assert_equal expected, all(".lk-transcript__text").map(&:text)
    HIDDEN.each { |phrase| assert_no_text phrase }
    assert_no_text "Euh"
  end

  test "si tout est filtré, le panneau reste en attente" do
    open_viewer_room
    publish_segments(HIDDEN)

    assert_selector ".lk-transcript__waiting", text: "En attente d'une prise de parole."
    assert_no_selector ".lk-transcript__entry"
  end

  test "un segment arrivé deux fois à quelques secondes n'est affiché qu'une fois" do
    open_viewer_room
    publish_segments([
      basile("On passe à la démo.", 10_000),
      { text: "D'accord.", sent_at: 11_000 },
      basile("On passe à la démo.", 13_000, publisher: "agent-AJ_second"),
      basile("on passe a la démo !", 15_000),
      { text: "On passe à la démo.", sent_at: 16_000 },
      basile("Et voici le résultat.", 17_000),
      basile("On passe à la démo.", 40_000)
    ])

    assert_equal [
      [ "Basile", "On passe à la démo." ],
      [ "Marc", "D'accord." ],
      [ "Marc", "On passe à la démo." ],
      [ "Basile", "Et voici le résultat." ],
      [ "Basile", "On passe à la démo." ]
    ], displayed_entries(5)
  end

  test "la fenêtre de 10 s se compte depuis le dernier segment affiché, dans les deux sens" do
    open_viewer_room
    publish_segments([
      basile("Oui, tout à fait.", 10_000),
      basile("Oui, tout à fait.", 18_000),
      basile("Oui, tout à fait.", 26_000),
      basile("Oui, tout à fait.", 21_000, publisher: "agent-AJ_second"),
      basile("Oui, tout à fait.", 12_000, publisher: "agent-AJ_second")
    ])

    # 10 s affiché ; 18 s masqué (8 s après) ; 26 s affiché (16 s après le
    # dernier AFFICHÉ, pas 8 s après le dernier reçu) ; 21 s masqué (5 s
    # avant) ; 12 s affiché (14 s avant : l'écart est absolu).
    assert_equal [ [ "Basile", "Oui, tout à fait." ] ] * 3, displayed_entries(3)
  end

  test "sans heure d'envoi, un segment répété reste affiché" do
    open_viewer_room
    publish_segments([ basile("Oui, tout à fait.", nil), basile("Oui, tout à fait.", nil) ])

    assert_equal [ [ "Basile", "Oui, tout à fait." ] ] * 2, displayed_entries(2)
  end

  test "sans heure de parole dans le flux, l'ordre affiché est l'ordre d'arrivée" do
    open_viewer_room
    publish_segments([
      basile("Première phrase arrivée.", 50_000),
      { text: "Deuxième phrase arrivée.", sent_at: 20_000 },
      basile("Troisième phrase arrivée.", 35_000, publisher: "agent-AJ_second")
    ])

    assert_equal [ "Première phrase arrivée.", "Deuxième phrase arrivée.", "Troisième phrase arrivée." ],
                 displayed_entries(3).map(&:last)
  end

  private

  def basile(text, sent_at, publisher: "agent-AJ_test")
    { text: text, identity: "speaker-basile", name: "Basile", sent_at: sent_at, publisher: publisher }
  end

  def displayed_entries(count)
    assert_selector ".lk-transcript__entry", count: count
    all(".lk-transcript__entry").map do |entry|
      [ entry.find(".lk-transcript__speaker").text, entry.find(".lk-transcript__text").text ]
    end
  end

  # Fenêtre large et préférences effacées : un test précédent du même
  # navigateur peut avoir laissé une fenêtre étroite ou le panneau replié
  # (replié, le fil est masqué). La Discussion est l'onglet par défaut.
  def open_viewer_room
    Capybara.current_session.current_window.resize_to(1400, 900)
    confirm_viewer_registration(@webinar)
    execute_script("localStorage.removeItem('undust-live:side-panel:collapsed'); localStorage.removeItem('undust-live:side-panel:tab')")
    visit public_webinar_path(slug: @webinar.slug)
    find("[data-testid='side-panel-tab-transcript']").click
    assert_selector "[data-testid='transcript-feed']"
  end

  # Segments finaux publiés comme le fait transcriber/agent.py : attributs
  # lk.segment_id / lk.transcription_final / lk.participant_identity /
  # lk.participant_name, texte en un morceau. Un segment est un texte (heure d'envoi croissante)
  # ou un Hash text / identity / name / sent_at / publisher.
  def publish_segments(segments)
    payload = segments.each_with_index.map do |segment, index|
      segment = { text: segment } if segment.is_a?(String)
      { text: segment[:text], identity: segment.fetch(:identity, "host-sub-marc"), name: segment.fetch(:name, "Marc"),
        sent_at: segment.fetch(:sent_at, 1000 + index), publisher: segment.fetch(:publisher, "agent-AJ_test") }
    end
    result = nil
    25.times do
      result = evaluate_script(<<~JS)
        (() => {
          const anchor = document.querySelector('.lk-viewer');
          const fiberKey = anchor && Object.keys(anchor).find((k) => k.startsWith('__reactFiber$'));
          let room = null;
          for (let fiber = fiberKey && anchor[fiberKey]; fiber && !room; fiber = fiber.return) {
            const value = fiber.memoizedProps && fiber.memoizedProps.value;
            if (value && value.remoteParticipants instanceof Map && value.localParticipant) room = value;
          }
          if (!room) return 'room introuvable';
          if (room.state === 'connecting') return 'connexion en cours';
          if (room.state === 'disconnected') {
            room.setAndEmitConnectionState('connected');
            return 'Room repassée à connected';
          }
          const handler = room.incomingDataStreamManager.textStreamHandlers.get('lk.transcription');
          if (!handler) return 'gestionnaire lk.transcription absent';
          #{payload.to_json}.forEach((segment, index) => {
            const info = { id: 'TS_' + index, timestamp: segment.sent_at, topic: 'lk.transcription',
                           attributes: { 'lk.segment_id': 'SG_' + index, 'lk.transcription_final': 'true',
                                         'lk.participant_identity': segment.identity,
                                         'lk.participant_name': segment.name } };
            handler({ info, async *[Symbol.asyncIterator]() { yield segment.text; } },
                    { identity: segment.publisher });
          });
          return 'ok';
        })()
      JS
      break if result == "ok"
      sleep 0.4
    end
    assert_equal "ok", result, "segments non publiés dans le panneau"
  end
end
