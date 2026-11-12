require "test_helper"

# Fail-loud micro : trois étages
# de panne micro étaient invisibles dans l'UI (bouton inerte, aucun message).
# Doctrine repo (cf. bandeau d'en-tête room.jsx) : "jamais avaler une panne
# silencieusement" (leçon multitrack).
#
# MISE À JOUR : le hint « 5 s après
# montage micro non publié » (garde c originale) est RETIRÉ. Le PreJoin
# @livekit/components-react (monté AVANT LiveKitRoom pour host/speaker)
# rend l'état micro EXPLICITE dès l'entrée en salle : toggle visible,
# aperçu caméra, dropdowns périphériques. « Où est mon micro » implicite
# n'existe plus — donc la garde temporisée non plus. L'assertion PreJoin
# ci-dessous prend le relais : sans PreJoin, l'utilisateur retomberait
# dans le silence originel.
#
# La suite système EXÉCUTE désormais React (test/system/room_react_render_
# test.rb, driver selenium_chrome_headless) — le crash hooks React (fix/
# room-hooks-prejoin) est attrapé bout-en-bout. Cette classe garde une
# vérification MÉCANIQUE DE LA SOURCE : (a) handler onMediaDeviceFailure
# (b) enumerateDevices au montage (c) PreJoin monté pour host/speaker
# DOIT rester présent. Si un futur refactor les retire, ce test rougit —
# garde anti-régression au niveau source.
#
# Le PreJoin vendor est remplacé par
# StagePreJoin (prejoin.jsx), qui porte désormais la garde (b) ; son
# comportement est aussi vérifié en navigateur
# (test/system/device_preferences_test.rb, « aucun micro »).
class MicFailLoudSourceTest < ActiveSupport::TestCase
  ROOMS = Rails.root.join("app/javascript/rooms")
  SOURCE_PATH = ROOMS.join("room.jsx")
  PREJOIN_PATH = ROOMS.join("prejoin.jsx")
  PREFERENCES_PATH = ROOMS.join("device_preferences.js")

  setup do
    @source = SOURCE_PATH.read
    @prejoin = PREJOIN_PATH.read
  end

  test "handler onMediaDeviceFailure câblé sur LiveKitRoom (garde a)" do
    # Le prop existe côté @livekit/components-react ; sans lui, tout
    # échec matériel (perm refusée, NotFound) passe en console.warn.
    assert_match(/onMediaDeviceFailure\s*=\s*\{/, @source,
      "room.jsx doit poser un prop onMediaDeviceFailure sur <LiveKitRoom>")
    assert_match(/mediaFailureMessage/, @source,
      "un mapping français des 4 valeurs MediaDeviceFailure doit exister")
    %w[NotFound PermissionDenied DeviceInUse].each do |failure|
      assert_includes @source, failure,
        "le mapping doit couvrir explicitement #{failure} (enum livekit-client)"
    end
  end

  test "bannière fail-loud accessible (role=alert, dismissible)" do
    assert_match(/role="alert"[^>]*data-testid="media-error-banner"|data-testid="media-error-banner"[^>]*role="alert"/, @source,
      "la bannière doit être role=alert (SR) ET testable via data-testid")
    assert_match(/aria-label="Masquer ce message"/, @source,
      "le bouton dismiss doit porter un aria-label explicite")
  end

  test "enumerateDevices au montage du PreJoin (garde b — Chrome orphelin PipeWire)" do
    # Sans cette garde, quand Chrome perd tout périphérique après restart
    # PipeWire, le toggle micro reste inerte SANS prompt : silence total.
    assert_match(/navigator\.mediaDevices\.enumerateDevices\(\)/, PREFERENCES_PATH.read,
      "listDevices doit appeler navigator.mediaDevices.enumerateDevices()")
    assert_match(/listDevices\(\)/, @prejoin,
      "un appel enumerateDevices (listDevices) au montage du PreJoin est requis")
    assert_match(/onEnumFailure\(NO_MICROPHONE\)/, @prejoin,
      "le garde doit signaler l'absence de tout audioinput")
  end

  test "PreJoin monté pour host/speaker (remplace le hint c)" do
    # StagePreJoin (prejoin.jsx) est monté AVANT LiveKitRoom dès que
    # canPublish (host/speaker). Il rend l'état micro EXPLICITE :
    # toggle on/off visible, sélecteurs micro/caméra dropdowns, bouton
    # rejoindre. Sans PreJoin, on retomberait dans le silence originel
    # (choix persisté invisible, micro coupé sans notification).
    assert_match(/import\s*\{\s*StagePreJoin\s*\}\s*from\s*["']\.\/prejoin["']/, @source,
      "StagePreJoin doit être importé depuis ./prejoin")
    assert_match(/<StagePreJoin\b/, @source,
      "le composant <StagePreJoin /> doit être monté dans le sous-arbre")
    assert_match(/data-testid="prejoin"/, @prejoin,
      "un wrapper data-testid=prejoin doit exister (assertion système test)")
    assert_match(/usePreviewTracks\([^;]*onError,\s*\)/m, @prejoin,
      "les échecs de l'aperçu doivent remonter par onError")
    # onSubmit branche les choix utilisateur → LiveKitRoom audio/video
    # (deviceId ciblés). Sans onSubmit, le PreJoin est un cul-de-sac.
    assert_match(/onSubmit\s*=\s*\{/, @source,
      "PreJoin.onSubmit doit être câblé (sinon aucun passage vers LiveKitRoom)")
    # onError adapte les DOMException MediaDevices vers MediaFailureBanner
    # (couvre DeviceInUse = OBS qui tient la Cam Link, cas réel).
    assert_match(/onError\s*=\s*\{/, @source,
      "PreJoin.onError doit être câblé (sinon les échecs matériels du PreJoin sont muets)")
  end

  test "règle des hooks React (tous avant early-returns conditionnels)" do
    # Régression : deux useCallback étaient DÉCLARÉS APRÈS les
    # early-returns loading/error → « Rendered more hooks than during the
    # previous render » à l'arrivée du token → écran BLANC staging.
    # Verrou mécanique : dans la fonction Room, tout `useCallback`,
    # `useMemo`, `useState`, `useEffect` DOIT apparaître avant le premier
    # `if (connection.state ===` qui return.
    room_body = @source[/function Room\(.*?^\}/m]
    assert room_body, "le composant Room() doit exister dans room.jsx"
    first_return_idx = room_body.index(/if\s*\(connection\.state\s*===/)
    assert first_return_idx, "un early-return sur connection.state doit exister"
    before_returns = room_body[0...first_return_idx]
    after_returns  = room_body[first_return_idx..]
    # Aucun hook après le premier early-return conditionnel.
    refute_match(/\b(useCallback|useMemo|useState|useEffect|useLocalParticipant|useParticipants|useTracks)\s*\(/, after_returns,
      "AUCUN hook React ne doit être appelé après un early-return conditionnel " \
      "(règle des hooks — cf. crash « Rendered more hooks than during the previous render »)")
    # Au moins un hook AVANT (sanity check : on n'a pas juste tout supprimé).
    assert_match(/\buseState\s*\(/, before_returns,
      "les hooks doivent être déclarés avant les early-returns")
  end

  test "aucun console.warn/log/error sur les pannes matériel (fail-loud strict)" do
    # Garde-fou : la doctrine du fichier (bandeau d'en-tête) dit "jamais
    # avaler une panne silencieusement". Un console.* dans la logique
    # d'erreur média est exactement ce qu'on veut éviter — l'utilisateur
    # ne lit pas la console. On tolère les commentaires (`//`).
    [ SOURCE_PATH, PREJOIN_PATH, PREFERENCES_PATH, ROOMS.join("device_menu.jsx") ].each do |path|
      refute_match(/console\.(warn|log|error|debug|info)\s*\(/, path.read,
        "aucun console.* dans #{path.basename} : la doctrine fail-loud exige un message" \
        " utilisateur (bannière, hint) — la console n'est pas lue")
    end
  end

  # Étend la garde « aucun console.* » à countdown.js.
  # Le module gère un polling silencieux (fail-silent au niveau réseau —
  # cf. commentaire de tête du fichier) : côté source, aucun console.*
  # ne doit s'y glisser (la console n'étant pas lue par les spectateurs).
  test "aucun console.* dans countdown.js (fail-silent strict)" do
    countdown_source = Rails.root.join("app/javascript/countdown.js").read
    refute_match(/console\.(warn|log|error|debug|info)\s*\(/, countdown_source,
      "aucun console.* dans countdown.js : le polling est silencieux côté réseau" \
      " et l'état visible côté DOM (label du compte à rebours)")
  end
end
