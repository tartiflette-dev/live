// Mosaïque de la salle : combien de colonnes et de rangées pour N tuiles
// dans une zone donnée, et à quelle taille.
//
// Cas observé en direct : trois caméras dans une fenêtre
// large et basse : la grille vendor les rangeait en 2×2 (dispositions
// fixées d'après le seul nombre de pistes, aucune en 3×1), une case vide,
// et chaque vidéo réduite à une vignette au milieu d'une tuile très large
// et très basse — « ici il faudrait 3 colonnes ».
//
// Règle : toutes les tuiles ont la même taille, au format 16:9 des
// caméras ; on retient la disposition qui les affiche le plus grand. À
// taille égale, celle qui laisse le moins de cases vides, puis celle qui a
// le moins de colonnes. Le choix manuel (MOSAIC_MODES) restreint seulement
// les nombres de colonnes candidats ; la taille se calcule de la même façon.
//
// Fonction pure : testée en unitaire (test/javascript/mosaic_layout_test.rb).

export const VIDEO_ASPECT = 16 / 9;

const range = (count) => Array.from({ length: count }, (_, index) => index + 1);

// Dispositions proposées dans le sélecteur de la scène, dans l'ordre
// d'affichage. `columns(count)` : nombres de colonnes candidats pour
// `count` tuiles.
export const MOSAIC_MODES = [
  { id: "auto", label: "Auto", columns: (count) => range(count) },
  { id: "row", label: "1 rangée", columns: (count) => [count] },
  { id: "column", label: "1 colonne", columns: () => [1] },
  { id: "2", label: "2 colonnes", columns: (count) => [Math.min(2, count)] },
  { id: "3", label: "3 colonnes", columns: (count) => [Math.min(3, count)] },
];

export const DEFAULT_MOSAIC_MODE = MOSAIC_MODES[0].id;

export function findMosaicMode(id) {
  return MOSAIC_MODES.find((mode) => mode.id === id) ?? MOSAIC_MODES[0];
}

const NO_CORNER = { width: 0, height: 0 };

// `width` × `height` : la zone, en px. Les tuiles gardent `gap` entre elles
// et avec les bords ; tailles entières (arrondies vers le bas), la rangée
// tient toujours dans la zone. Les tuiles sont centrées dans la zone.
//
// `corner` : encart en haut à droite de la zone (le sélecteur de la scène),
// tenu à `gap` des tuiles. Il se pose dans la marge que laissent les tuiles
// quand elle suffit, au-dessus d'elles ou à côté ; sinon les tuiles se
// rangent sous lui ou à sa gauche, là où elles restent le plus grandes
// (sous lui à égalité). `top` / `right` : bande réservée en haut / colonne
// réservée à droite de la zone (0 ou la taille de l'encart).
export function mosaicLayout({ count, width, height, gap = 0, mode = DEFAULT_MOSAIC_MODE, corner = NO_CORNER }) {
  if (count <= 0) return { columns: 0, rows: 0, tileWidth: 0, tileHeight: 0, top: 0, right: 0 };
  const centred = arrange(count, width, height, gap, mode);
  if (clearsCorner(centred, width, height, gap, corner)) return { ...centred, top: 0, right: 0 };
  const below = { ...arrange(count, width, height - corner.height, gap, mode), top: corner.height, right: 0 };
  const beside = { ...arrange(count, width - corner.width, height, gap, mode), top: 0, right: corner.width };
  return beside.tileWidth > below.tileWidth ? beside : below;
}

function arrange(count, width, height, gap, mode) {
  let best = null;
  for (const columns of findMosaicMode(mode).columns(count)) {
    const candidate = sizeTiles(count, columns, width - 2 * gap, height - 2 * gap, gap);
    if (!best || isBetter(candidate, best)) best = candidate;
  }
  const { emptyCells: _emptyCells, ...layout } = best;
  return layout;
}

function sizeTiles(count, columns, width, height, gap) {
  const rows = Math.ceil(count / columns);
  const cellWidth = (width - gap * (columns - 1)) / columns;
  const cellHeight = (height - gap * (rows - 1)) / rows;
  const tileWidth = Math.max(0, Math.floor(Math.min(cellWidth, cellHeight * VIDEO_ASPECT)));
  return {
    columns,
    rows,
    tileWidth,
    tileHeight: Math.floor(tileWidth / VIDEO_ASPECT),
    emptyCells: columns * rows - count,
  };
}

// Plus grande tuile d'abord, puis moins de cases vides ; à égalité
// complète, la candidate déjà retenue (moins de colonnes) reste.
function isBetter(candidate, best) {
  if (candidate.tileWidth !== best.tileWidth) return candidate.tileWidth > best.tileWidth;
  return candidate.emptyCells < best.emptyCells;
}

function clearsCorner({ columns, rows, tileWidth, tileHeight }, width, height, gap, corner) {
  const blockWidth = columns * tileWidth + (columns - 1) * gap;
  const blockHeight = rows * tileHeight + (rows - 1) * gap;
  return (height - blockHeight) / 2 >= corner.height + gap || (width - blockWidth) / 2 >= corner.width + gap;
}
