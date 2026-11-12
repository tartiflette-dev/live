// Mise en page de la régie selon le moment du direct (avant, pendant, après) :
// « une partie à gauche, une partie à droite » ; en priorité ce qui n'est PAS
// déjà dans la scène ; après la fin, un bilan sans commandes de direct au
// premier plan. Aucun bloc ne disparaît : un bloc secondaire est replié, pas
// retiré (« je veux pas perdre de lien ou de fonction »).
//
// Colonne de gauche : le pilotage (enregistrement, caméras, sondages,
// participants, inscrits, puis ce que la scène montre déjà : mise en avant,
// mains levées). Les caméras ne sont mesurées que pendant le direct : leur
// bloc est ouvert pendant, juste après l'enregistrement dont elles font la
// qualité, et replié avant comme après.
// Colonne de droite : le public (questions, discussion).
// Sur une seule colonne (demi-écran de portable, tablette), les blocs se
// rangent par `rank` : la priorité du moment, toutes colonnes confondues.

export const BLOCKS = Object.freeze([
  "recording", "cameras", "polls", "participants", "attendance", "spotlight", "hands", "questions", "discussion",
]);

const RIGHT_BLOCKS = new Set(["questions", "discussion"]);

// Par moment : les blocs du plus au moins prioritaire ; `folded` = replié.
const PRIORITIES = {
  // Avant : préparer le plan des sondages, voir qui arrive.
  draft: [
    ["polls"], ["questions"], ["recording"], ["participants"], ["attendance"], ["discussion"],
    ["cameras", "folded"], ["spotlight", "folded"], ["hands", "folded"],
  ],
  // Pendant : questions d'abord, puis l'enregistrement (une ligne, mais son
  // échec ne doit jamais passer sous une longue liste), les caméras (qualité
  // de ce qui s'enregistre) et les sondages ; mise en avant et mains levées
  // sont déjà visibles dans la scène.
  live: [
    ["questions"], ["recording"], ["cameras"], ["polls"], ["participants"], ["discussion"], ["attendance"],
    ["hands", "folded"], ["spotlight", "folded"],
  ],
  // Après : le bilan (résultats, questions, présence) ; les commandes du
  // direct restent atteignables, repliées.
  ended: [
    ["polls"], ["questions"], ["attendance"], ["recording"], ["discussion"],
    ["participants", "folded"], ["cameras", "folded"], ["spotlight", "folded"], ["hands", "folded"],
  ],
};

export const MOMENTS = Object.freeze({ draft: "avant", live: "pendant", ended: "apres" });

// Avant ou pendant le direct, une main levée attend un geste que seule la
// régie peut faire (donner la parole) : le bloc remonte juste après les
// questions, toujours replié (il s'ouvre de lui-même, regie.jsx).
function raiseHands(priorities) {
  const hands = priorities.find(([block]) => block === "hands");
  const rest = priorities.filter((entry) => entry !== hands);
  const afterQuestions = rest.findIndex(([block]) => block === "questions") + 1;
  return [...rest.slice(0, afterQuestions), hands, ...rest.slice(afterQuestions)];
}

// @param handsRaised au moins une main levée en attente de parole (`waiting`)
// @return {{ moment: string, left: Array<{block, folded, rank}>, right: Array<{block, folded, rank}> }}
//   état inconnu : rangé comme « avant » (rien n'est caché).
export function regieLayout(state, { handsRaised = false } = {}) {
  const known = Object.hasOwn(PRIORITIES, state) ? state : "draft";
  const priorities = handsRaised && known !== "ended" ? raiseHands(PRIORITIES[known]) : PRIORITIES[known];
  const placed = priorities.map(([block, folded], index) => ({ block, folded: folded === "folded", rank: index + 1 }));
  return {
    moment: MOMENTS[known],
    left: placed.filter(({ block }) => !RIGHT_BLOCKS.has(block)),
    right: placed.filter(({ block }) => RIGHT_BLOCKS.has(block)),
  };
}
