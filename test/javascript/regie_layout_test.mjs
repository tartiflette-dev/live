// Mise en page de la régie par moment (regie_layout.mjs) et format des
// heures (clock_time.mjs), sous Node. Lancé par test/integration/regie_layout_test.rb.
import assert from "node:assert/strict";
import { BLOCKS, MOMENTS, regieLayout } from "../../app/javascript/rooms/regie_layout.mjs";
import { clockTime } from "../../app/javascript/rooms/clock_time.mjs";

const blocksOf = (layout) => [...layout.left, ...layout.right].map(({ block }) => block);
const entry = (layout, block) => [...layout.left, ...layout.right].find((item) => item.block === block);

// Aucune fonction ne disparaît : à chaque moment, chaque bloc est rangé une fois, et une seule.
const layouts = ["draft", "live", "ended"].flatMap((state) => [
  [state, regieLayout(state)], [state, regieLayout(state, { handsRaised: true })],
]);
for (const [state, layout] of layouts) {
  assert.deepEqual([...blocksOf(layout)].sort(), [...BLOCKS].sort(), `blocs de la régie (${state})`);
  assert.equal(layout.moment, MOMENTS[state]);
  // Deux colonnes : le public à droite, le pilotage à gauche.
  assert.deepEqual(layout.right.map(({ block }) => block).sort(), ["discussion", "questions"]);
  // Rangs uniques et croissants dans chaque colonne (ordre sur une seule colonne).
  const ranks = [...layout.left, ...layout.right].map(({ rank }) => rank).sort((a, b) => a - b);
  assert.deepEqual(ranks, BLOCKS.map((_, index) => index + 1));
  for (const column of [layout.left, layout.right]) {
    assert.deepEqual(column.map(({ rank }) => rank), [...column.map(({ rank }) => rank)].sort((a, b) => a - b));
  }
  // Ce que la scène montre déjà (mise en avant, mains levées) est replié.
  assert.equal(entry(layout, "spotlight").folded, true);
  assert.equal(entry(layout, "hands").folded, true);
}

// Pendant : les questions passent en tête, avant ce que la scène montre déjà.
const live = regieLayout("live");
assert.equal(entry(live, "questions").rank, 1);
assert.equal(live.left[0].block, "recording", "l'enregistrement en tête du pilotage, jamais sous une longue liste");
assert.ok(entry(live, "polls").rank < entry(live, "spotlight").rank);
assert.equal(entry(live, "participants").folded, false);

// Caméras : mesurées pendant le direct seulement — ouvertes juste après
// l'enregistrement pendant, repliées avant comme après.
assert.equal(entry(live, "cameras").rank, entry(live, "recording").rank + 1);
assert.equal(entry(live, "cameras").folded, false);
assert.equal(entry(regieLayout("draft"), "cameras").folded, true);
assert.equal(entry(regieLayout("ended"), "cameras").folded, true);

// Après : bilan d'abord (sondages, questions, inscrits), commandes du direct repliées.
const ended = regieLayout("ended");
assert.deepEqual(blocksOf(ended).length, BLOCKS.length);
assert.equal(entry(ended, "polls").rank, 1);
assert.ok(entry(ended, "attendance").rank < entry(ended, "participants").rank);
assert.equal(entry(ended, "participants").folded, true);

// Une main levée remonte le bloc juste après les questions, avant ou pendant
// le direct ; après la fin, rien ne bouge.
const raised = regieLayout("live", { handsRaised: true });
assert.equal(entry(raised, "hands").rank, entry(raised, "questions").rank + 1);
assert.equal(raised.left[0].block, "hands");
assert.equal(entry(regieLayout("draft", { handsRaised: true }), "hands").rank, entry(regieLayout("draft"), "questions").rank + 1);
assert.deepEqual(regieLayout("ended", { handsRaised: true }), regieLayout("ended"));

// État inconnu : rien n'est caché, rangé comme « avant ».
assert.deepEqual(regieLayout("autre"), regieLayout("draft"));

// Heures : 9:05, jamais 09:05 ; secondes sur demande ; rien d'inventé.
const morning = new Date(2026, 10, 10, 9, 5, 7).toISOString();
assert.equal(clockTime(morning), "9:05");
assert.equal(clockTime(morning, { seconds: true }), "9:05:07");
assert.equal(clockTime(new Date(2026, 10, 10, 14, 0).toISOString()), "14:00");
assert.equal(clockTime(null), "");
assert.equal(clockTime("hier"), "");
