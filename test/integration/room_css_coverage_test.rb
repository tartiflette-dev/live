require "test_helper"

# Incident d'affichage de la page salle.
#
# La page salle rendait en Times New Roman sur fond blanc, titre et
# « En attente du démarrage… » nus, cadre blanc autour d'une vidéo noire.
# La vidéo FONCTIONNAIT : seule la coquille était nue.
#
# Mécanique du bug, en trois faits qui se combinent :
#   1. les pages salle posent body.room et échappent VOLONTAIREMENT à
#      chrome.css, scopé body.chrome (invariant verrouillé par
#      test/system/room_chrome_isolation_test.rb — on le garde) ;
#   2. @livekit/components-styles ne style que SES propres composants —
#      donc rien de la coquille autour de la scène ;
#   3. les classes de la coquille (.lk-page*, .lk-viewer*, .lk-status*,
#      .lk-prejoin-wrapper, .lk-mount) n'étaient définies NULLE PART.
#
# Aucun test ne rougissait : room_chrome_isolation_test asserte la
# PRÉSENCE de `main.lk-page`, jamais qu'une règle s'y applique. D'où cette
# garde MÉCANIQUE : toute classe `lk-…` écrite par NOUS (vue ERB ou JSX)
# doit avoir une définition dans room.css. Un futur composant qui ajoute
# une classe de coquille sans la styler fait rougir ce test.
class RoomCssCoverageTest < ActiveSupport::TestCase
  STYLESHEET = Rails.root.join("app/assets/stylesheets/room.css")
  SOURCES = [
    Rails.root.join("app/views/webinars/room.html.erb"),
    Rails.root.join("app/views/webinars/_room_header.html.erb"),
    Rails.root.join("app/views/webinars/ended.html.erb"),
    Rails.root.join("app/javascript/rooms/room.jsx"),
    Rails.root.join("app/javascript/rooms/room_exit.jsx"),
    Rails.root.join("app/javascript/rooms/live_state_control.jsx"),
    Rails.root.join("app/javascript/rooms/room_controls.jsx"),
    Rails.root.join("app/javascript/rooms/prejoin.jsx"),
    Rails.root.join("app/javascript/rooms/device_menu.jsx"),
    Rails.root.join("app/javascript/rooms/spotlight.jsx"),
    Rails.root.join("app/javascript/rooms/room_tiles.jsx"),
    Rails.root.join("app/javascript/rooms/state_button.jsx"),
    Rails.root.join("app/javascript/rooms/side_panel.jsx"),
    Rails.root.join("app/javascript/rooms/chat.jsx"),
    Rails.root.join("app/javascript/rooms/qa_banner.jsx"),
    Rails.root.join("app/javascript/rooms/transcript_feed.jsx"),
    Rails.root.join("app/javascript/rooms/participant_consent.jsx")
  ].freeze

  # Feuille vendor, LUE À L'EXÉCUTION plutôt que recopiée en constante.
  #
  # Une liste de préfixes en dur avait deux défauts. (a) Faux négatifs : un
  # préfixe glouton comme `lk-prejoin-` masquait notre propre
  # `.lk-prejoin-wrapper`, donc une future `.lk-prejoin-footer` non stylée
  # serait passée VERTE. (b) Dérive de version : la liste ne suivait pas les
  # montées de @livekit/components-styles.
  #
  # En lisant les noms réellement définis par vendor, la frontière est exacte
  # et se met à jour toute seule au prochain `npm ci`.
  VENDOR_CSS = Rails.root.join(
    "node_modules/@livekit/components-styles/dist/general/index.css"
  )

  setup do
    # Tolérant à l'absence du fichier : si room.css disparaît, on veut le
    # message des assertions ci-dessous, pas un Errno::ENOENT dans setup
    # qui rougit les 4 tests sans dire lequel est le vrai problème.
    @css = STYLESHEET.exist? ? STYLESHEET.read : ""
  end

  # room.css SANS ses commentaires. Indispensable avant tout scan de noms de
  # classes : les blocs d'explication citent des classes vendor en prose
  # (`.lk-toast`, `.lk-prejoin`, `.lk-room-container`…) et un scan naïf les
  # compterait comme définies ici — la première version de ce test rougissait
  # exactement là-dessus.
  def css_rules
    @css.gsub(%r{/\*.*?\*/}m, "")
  end

  # Noms `lk-…` que vendor définit lui-même. Fail-loud si node_modules manque :
  # sans la feuille vendor, la frontière maison/vendor n'est pas calculable et
  # un `[]` silencieux transformerait chaque classe vendor en « classe maison
  # non stylée » — un rouge trompeur.
  def vendor_class_names
    assert VENDOR_CSS.exist?,
      "#{VENDOR_CSS} absent — lancer `npm ci` avant les tests (le CI le fait " \
      "dans le job test). Sans la feuille vendor, la frontière " \
      "maison/vendor n'est pas calculable."
    VENDOR_CSS.read.scan(/\.(lk-[A-Za-z0-9_-]+)/).flatten.to_set
  end

  test "room.css est servi par Propshaft (pas un fichier orphelin)" do
    assert STYLESHEET.exist?, "app/assets/stylesheets/room.css doit exister"
    layout = Rails.root.join("app/views/layouts/room.html.erb").read
    assert_match(/stylesheet_link_tag\s+"room"/, layout,
      "le layout salle doit inclure la feuille room — sans le <link>, elle ne " \
      "s'applique jamais et la salle repart en Times New Roman")
    # Palette sans couleur en dur : les tokens viennent du bundle tailwind,
    # chargé AVANT le bundle LiveKit et room.css.
    assert_match(/stylesheet_link_tag\s+"tailwind".*stylesheet_link_tag\s+"application".*stylesheet_link_tag\s+"room"/m, layout,
      "ordre des feuilles salle : tailwind (tokens) → application (LiveKit) → room")
  end

  test "room.css ne consomme que des tokens (zéro hex)" do
    hex = css_rules.scan(/#[0-9a-fA-F]{3,8}\b/)
    assert_empty hex, "hex hors tokens dans room.css : #{hex.inspect} — utiliser var(--gray-*, --status-*, --orange-500)"
  end

  test "toutes les règles de room.css sont scopées body.room" do
    # Aucune règle ne doit fuir vers les pages animateur (chrome du
    # thème), sinon on recrée le mélange que l'isolation interdit.
    selectors = css_rules
      .scan(/([^{}]+)\{/)                # préludes de règles
      .flatten
      # Une at-rule SANS bloc (`@import …;`, `@layer a, b;`) colle au
      # prélude suivant : seul ce qui suit le dernier `;` est le prélude.
      .map { |s| s.split(";").last.to_s.strip }
      # At-rules écartées AVANT le découpage sur la virgule : une liste de
      # requêtes (`@media (a), (b) and (c)`) n'est pas une liste de sélecteurs.
      .reject { |s| s.start_with?("@") }
      .flat_map { |s| s.split(",") }
      .map(&:strip)
      .reject(&:empty?)
      .reject { |s| s.match?(/\A(?:from|to|\d+(?:\.\d+)?%)\z/) } # étapes d'un @keyframes

    leaking = selectors.reject { |s| s.start_with?("body.room") }
    assert_empty leaking,
      "règles non scopées body.room dans room.css : #{leaking.inspect}"
  end

  test "toute classe lk- de la coquille a une définition dans room.css" do
    used = SOURCES.flat_map { |path|
      path.read.scan(/class(?:Name)?=["']([^"']+)["']/).flatten
    }.flat_map(&:split).uniq.select { |c| c.start_with?("lk-") }

    assert used.any?, "aucune classe lk- trouvée — scan cassé, pas un succès"

    vendor = vendor_class_names
    ours = used.reject { |c| vendor.include?(c) }
    assert ours.any?,
      "toutes les classes lk- utilisées seraient vendor — frontière cassée"

    undefined = ours.reject { |c| css_rules.include?(".#{c}") }

    assert_empty undefined,
      "classes de coquille utilisées mais jamais définies : " \
      "#{undefined.inspect} — c'est EXACTEMENT le bug d'affichage du 17/08 " \
      "(page salle nue). Les définir dans room.css sous body.room."
  end

  test "aucune classe lk- maison ne collisionne avec un nom vendor" do
    # C'est l'invariant sur lequel repose TOUT le choix de garder le préfixe
    # `lk-` pour nos classes (cf. bloc PRÉFIXE de room.css). Il n'y a pas de
    # mur d'attribut : sur dist/general/index.css, l'écrasante majorité des
    # sélecteurs vendor sont GLOBAUX (`.lk-*` nus) — seuls `[data-lk-theme]`,
    # `.lk-list` et `.lk-form-control` sont scopés. La sûreté vient donc
    # uniquement de la non-collision NOMINALE, et rien ne la garantissait.
    #
    # Sans ce test, ajouter `.lk-toast` ou `.lk-spinner` côté maison partirait
    # en collision silencieuse (vendor pose `position: fixed` sur .lk-toast).
    ours = css_rules.scan(/\.(lk-[A-Za-z0-9_-]+)/).flatten.uniq
    collisions = ours & vendor_class_names.to_a

    assert_empty collisions,
      "classes définies dans room.css qui existent DÉJÀ chez " \
      "@livekit/components-styles : #{collisions.inspect}. Renommer côté " \
      "maison (préfixe non-lk), sinon le gagnant dépend de la spécificité " \
      "et le rendu vendor casse de façon invisible."
  end

  test "vendor pose toujours position:relative sur .lk-room-container" do
    # `body.room .lk-viewer` utilise `position: absolute; inset: 0` pour
    # remplir la hauteur (cf. bloc POSITIONNEMENT ABSOLU de room.css). Cet
    # ancrage suppose que le conteneur de <LiveKitRoom> reste positionné.
    #
    # Si une montée de @livekit/components-styles retirait ce
    # `position: relative`, .lk-viewer s'ancrerait sur le premier ancêtre
    # positionné — aucun jusqu'au viewport — et la scène spectateur
    # recouvrirait la page entière. Panne visuelle franche, mais silencieuse
    # côté CI : aucun autre test ne la verrait. On la rend bruyante ici.
    vendor = VENDOR_CSS.read
    rules = vendor.scan(/\.lk-room-container\s*\{[^}]*\}/)
    assert rules.any?, ".lk-room-container introuvable chez vendor"
    assert rules.any? { |r| r.match?(/position\s*:\s*relative/) },
      "vendor ne pose plus `position: relative` sur .lk-room-container : " \
      "l'ancrage `inset: 0` de body.room .lk-viewer n'a plus de référent. " \
      "Règles trouvées : #{rules.inspect}"
  end

  test "body.room fixe police et fond (garde anti-Times New Roman)" do
    body_rule = css_rules[/body\.room\s*\{[^}]*\}/m]
    assert body_rule, "room.css doit contenir une règle body.room"
    assert_match(/font-family:/, body_rule,
      "sans font-family sur body.room, la salle hérite du serif par défaut " \
      "du navigateur — le symptôme visuel signalé")
    assert_match(/background:/, body_rule,
      "sans background, cadre blanc autour d'une scène LiveKit noire")
  end
end
