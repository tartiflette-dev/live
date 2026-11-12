require "test_helper"
require "open3"

# Calcul de la mosaïque (app/javascript/rooms/
# mosaic_layout.js), exécuté par Node tel que le navigateur le charge.
#
# Cas observé en direct : trois caméras dans une fenêtre
# large et basse rangées en 2×2 par la grille vendor, une case vide, des
# vidéos de ~170 px au milieu de tuiles de 440×95 — « ici il faudrait 3
# colonnes ». Règle : tuiles 16:9 de même taille, la disposition qui les
# affiche le plus grand ; à taille égale, le moins de cases vides.
#
# Les valeurs attendues sont calculées à la main dans chaque test :
# surface utile = zone − 2 × gap, cellule = (surface − gap entre cellules)
# / nombre, largeur de tuile = min(cellule, hauteur de cellule × 16/9),
# arrondie vers le bas, hauteur = largeur × 9/16 arrondie vers le bas.
#
# Exécution : le module est chargé tel quel par Node. package.json ne
# déclare pas `"type": "module"` (esbuild n'en a pas besoin) : Node le
# reconnaît comme module ES à sa syntaxe (Node ≥ 22.7 ; la CI installe
# Node 22) et l'écrit sur stderr, qui n'est lu qu'en cas d'échec. Le
# chemin passe en argument et devient une URL par pathToFileURL (espaces,
# « # » et « % » échappés).
class MosaicLayoutTest < ActiveSupport::TestCase
  MODULE_PATH = Rails.root.join("app/javascript/rooms/mosaic_layout.js").to_s.freeze

  def layout(**args)
    script = <<~JS
      import { pathToFileURL } from "node:url";
      const { mosaicLayout } = await import(pathToFileURL(process.argv[2]).href);
      process.stdout.write(JSON.stringify(mosaicLayout(#{args.to_json})));
    JS
    out, err, status = Open3.capture3("node", "--input-type=module", "-", MODULE_PATH, stdin_data: script)
    assert status.success?, "node a échoué : #{err}"
    JSON.parse(out, symbolize_names: true)
  end

  test "cas observé : 3 tuiles en zone large et basse → 3 colonnes, pas de 2×2" do
    # Surface 880×200. 3×1 : cellule 288×200 → 288 (288 < 355). 2×2 :
    # cellule 436×96 → 170. 1×3 : cellule 880×61 → 109.
    assert_equal({ columns: 3, rows: 1, tileWidth: 288, tileHeight: 162, top: 0, right: 0 },
                 layout(count: 3, width: 896, height: 216, gap: 8))
  end

  test "3 tuiles en zone haute et étroite → 1 colonne" do
    # Surface 400×900. 1×3 : cellule 400×294 → 400. 2×2 : cellule 196 de
    # large → 196. 3×1 : 128.
    assert_equal({ columns: 1, rows: 3, tileWidth: 400, tileHeight: 225, top: 0, right: 0 },
                 layout(count: 3, width: 416, height: 916, gap: 8))
  end

  test "3 tuiles en zone presque carrée → 2×2, la case vide coûte moins que des tuiles plus petites" do
    # Surface 800×600. 2×2 : cellule 396×296 → 396. 1×3 : cellule 800×194
    # → 346. 3×1 : cellule 261 de large → 261.
    assert_equal({ columns: 2, rows: 2, tileWidth: 396, tileHeight: 222, top: 0, right: 0 },
                 layout(count: 3, width: 816, height: 616, gap: 8))
  end

  test "4 tuiles en plein écran 16:9 → 2×2" do
    # Surface 1600×900. 2×2 : cellule 796×446 → 792. 3×2 : 528. 4×1 : 394.
    assert_equal({ columns: 2, rows: 2, tileWidth: 792, tileHeight: 445, top: 0, right: 0 },
                 layout(count: 4, width: 1616, height: 916, gap: 8))
  end

  test "une seule tuile : bornée par la hauteur, au 16:9" do
    # Surface 1000×300 → min(1000, 300 × 16/9 = 533) = 533, hauteur 299.
    assert_equal({ columns: 1, rows: 1, tileWidth: 533, tileHeight: 299, top: 0, right: 0 },
                 layout(count: 1, width: 1016, height: 316, gap: 8))
  end

  test "à taille égale, la disposition sans case vide l'emporte" do
    # Sans espacement, 960×360. 2×2 : cellule 480×180 → 320. 3×1 : cellule
    # 320×360 → 320. Égalité : 3×1 n'a aucune case vide.
    assert_equal({ columns: 3, rows: 1, tileWidth: 320, tileHeight: 180, top: 0, right: 0 },
                 layout(count: 3, width: 960, height: 360, gap: 0))
  end

  test "choix « 1 rangée » : toutes les tuiles côte à côte, même en zone haute" do
    # Surface 400×900, 3 colonnes imposées : cellule 128 de large → 128×72.
    assert_equal({ columns: 3, rows: 1, tileWidth: 128, tileHeight: 72, top: 0, right: 0 },
                 layout(count: 3, width: 416, height: 916, gap: 8, mode: "row"))
  end

  test "choix « 1 colonne » : tuiles empilées, même en zone large" do
    # Surface 880×200, 1 colonne imposée : cellule 880×61 → 109×61.
    assert_equal({ columns: 1, rows: 3, tileWidth: 109, tileHeight: 61, top: 0, right: 0 },
                 layout(count: 3, width: 896, height: 216, gap: 8, mode: "column"))
  end

  test "choix « 2 colonnes » : respecté même quand il donne des tuiles plus petites" do
    # Surface 880×200 : cellule 436×96 → 170×95 (la mosaïque de la capture).
    assert_equal({ columns: 2, rows: 2, tileWidth: 170, tileHeight: 95, top: 0, right: 0 },
                 layout(count: 3, width: 896, height: 216, gap: 8, mode: "2"))
  end

  test "choix « 3 colonnes » avec 2 tuiles : jamais plus de colonnes que de tuiles" do
    # Surface 880×200, 2 colonnes : cellule 436×200 → min(436, 355) = 355.
    assert_equal({ columns: 2, rows: 1, tileWidth: 355, tileHeight: 199, top: 0, right: 0 },
                 layout(count: 2, width: 896, height: 216, gap: 8, mode: "3"))
  end

  test "choix inconnu (stockage ancien ou altéré) : disposition automatique" do
    assert_equal layout(count: 3, width: 896, height: 216, gap: 8),
                 layout(count: 3, width: 896, height: 216, gap: 8, mode: "4x4")
  end

  test "aucune tuile : mosaïque vide" do
    assert_equal({ columns: 0, rows: 0, tileWidth: 0, tileHeight: 0, top: 0, right: 0 },
                 layout(count: 0, width: 896, height: 216, gap: 8))
  end

  # Sélecteur de 190×40, tenu à 8 px des tuiles : il lui faut une marge
  # de 48 px au-dessus des tuiles ou de 198 px à côté.
  PICKER = { width: 190, height: 40 }.freeze

  test "sélecteur : posé dans la marge au-dessus des tuiles quand elle suffit" do
    # 1×3 de 400×225 : bloc de 691 px de haut dans 916, marge haute 112 ≥ 48.
    assert_equal({ columns: 1, rows: 3, tileWidth: 400, tileHeight: 225, top: 0, right: 0 },
                 layout(count: 3, width: 416, height: 916, gap: 8, corner: PICKER))
  end

  test "sélecteur : posé dans la marge à côté des tuiles quand elle suffit" do
    # 1 tuile de 682×383 dans 1200×400 : marge haute 8, marge latérale 259 ≥ 198.
    assert_equal({ columns: 1, rows: 1, tileWidth: 682, tileHeight: 383, top: 0, right: 0 },
                 layout(count: 1, width: 1200, height: 400, gap: 8, corner: PICKER))
  end

  test "sélecteur : sans marge suffisante, les tuiles se rangent sous lui" do
    # 3×1 de 288×162 dans 896×216 : marges 27 (haut) et 8 (côté), trop
    # petites. Sous lui, zone 896×176, surface 880×160 → cellule 288×160 →
    # min(288, 284) = 284. À sa gauche, zone 706×216, surface 690×200 →
    # cellule 224 de large : moins bien.
    assert_equal({ columns: 3, rows: 1, tileWidth: 284, tileHeight: 159, top: 40, right: 0 },
                 layout(count: 3, width: 896, height: 216, gap: 8, corner: PICKER))
  end

  test "sélecteur : en zone très basse, les tuiles se rangent à sa gauche si elles y restent plus grandes" do
    # 3×1 de 273×153 dans 896×170 : marges 8 et 30, trop petites. Sous lui,
    # surface 880×114 → 202. À sa gauche, surface 690×154 → cellule 224×154
    # → min(224, 273) = 224, hauteur 126.
    assert_equal({ columns: 3, rows: 1, tileWidth: 224, tileHeight: 126, top: 0, right: 190 },
                 layout(count: 3, width: 896, height: 170, gap: 8, corner: PICKER))
  end
end
