// Frontières de confiance du client des sondages (poll_state.mjs), sous Node,
// sans navigateur. Lancé par test/integration/poll_state_test.rb.
import assert from "node:assert/strict";
import { FORMATS, applyHttpSnapshot, applyPacketSnapshot, formatOf, percentages, readServerSnapshot, validPoll, validSnapshot } from "../../app/javascript/rooms/poll_state.mjs";

const choice = {
  id: 3, kind: "choice", multiple: false, label: "<b>A</b>, B ou C ?", options: ["A", "B", "C"],
  open: true, responses_count: 2, results: null,
};
const at = "2026-10-31T11:00:00.000001Z";
const later = "2026-10-31T11:00:01.000000Z";
const packet = (envelope) => new TextEncoder().encode(JSON.stringify(envelope));

// Seul un paquet SERVEUR, au bon topic et au bon schéma, est accepté ; `poll: null` = plus rien à l'écran.
assert.deepEqual(readServerSnapshot(packet({ topic: "poll", at, poll: choice }), undefined), { at, poll: choice });
assert.deepEqual(readServerSnapshot(packet({ topic: "poll", at, poll: null }), undefined), { at, poll: null });
assert.equal(readServerSnapshot(packet({ topic: "poll", at, poll: choice }), { identity: "viewer-2" }), null);
assert.equal(readServerSnapshot(packet({ topic: "chat", at, poll: choice }), undefined), null);
assert.equal(readServerSnapshot(packet({ topic: "poll", at: "hier", poll: choice }), undefined), null);
assert.equal(readServerSnapshot(new TextEncoder().encode("pas du JSON"), undefined), null);
assert.equal(readServerSnapshot(new Uint8Array(16385), undefined), null);
assert.equal(readServerSnapshot(packet(null), undefined), null);

// Schéma : options selon le type, résultats cohérents avec les options.
assert.equal(validPoll(choice), true);
assert.equal(validPoll({ ...choice, kind: "quiz" }), false);
assert.equal(validPoll({ ...choice, options: ["Seul"] }), false);
assert.equal(validPoll({ ...choice, label: "x".repeat(301) }), false);
assert.equal(validPoll({ ...choice, results: { respondents: 2, counts: [1, 1] } }), false);
assert.equal(validPoll({ ...choice, results: { respondents: 2, counts: [1, 0, 1] } }), true);
const scale = { ...choice, kind: "scale", options: { min: 1, max: 5, min_label: null, max_label: null }, results: { respondents: 1, counts: [0, 0, 0, 1, 0], average: 4 } };
assert.equal(validPoll(scale), true);
assert.equal(validPoll({ ...scale, options: { min: 1, max: 40 } }), false);
const text = { ...choice, kind: "short_text", options: null, results: { respondents: 1, answers: ["Clair"] } };
assert.equal(validPoll(text), true);
assert.equal(validPoll({ ...text, results: { respondents: 1, answers: ["x".repeat(201)] } }), false);
assert.equal(validSnapshot({ at, poll: { ...choice, id: "3" } }), false);

const NOW = Date.parse("2026-10-31T11:00:01.500000Z");
const empty = { at: null, poll: null, myResponse: null };

// Réponse HTTP sur un état vide : l'adopte, réponse de la personne comprise.
const answered = applyHttpSnapshot(empty, { at, poll: choice }, [1]);
assert.deepEqual(answered, { at, poll: choice, myResponse: [1] });

// Paquet plus récent du même sondage : compteur et résultat suivent, la réponse reste.
const tallied = applyPacketSnapshot(answered, { at: later, poll: { ...choice, responses_count: 3 } }, NOW);
assert.deepEqual(tallied.myResponse, [1]);
assert.equal(tallied.poll.responses_count, 3);
assert.equal(applyPacketSnapshot(tallied, { at, poll: null }, NOW), tallied, "un paquet en retard ne défait rien");
assert.deepEqual(applyPacketSnapshot(tallied, { at: later, poll: { ...choice, id: 4 } }, NOW).myResponse, null);
const closed = applyPacketSnapshot(tallied, { at: "2026-10-31T11:00:01.200000Z", poll: { ...choice, open: false } }, NOW);
assert.equal(closed.poll.open, false, "un paquet ferme le sondage connu");

// Défense en profondeur : paquet forgé daté de l'an
// 9999, mêmes id, options inversées — rejeté, l'écran ne se fige pas.
const forgedFuture = { at: "9999-12-31T23:59:59.999999Z", poll: { ...choice, options: ["C", "B", "A"] } };
assert.equal(applyPacketSnapshot(tallied, forgedFuture, NOW), tallied, "paquet daté du futur rejeté");
const forgedNow = { at: "2026-10-31T11:00:01.400000Z", poll: { ...choice, options: ["C", "B", "A"] } };
assert.equal(applyPacketSnapshot(tallied, forgedNow, NOW), tallied, "un paquet ne change jamais les options d'un sondage connu");
assert.equal(applyPacketSnapshot(tallied, { ...forgedNow, poll: { ...choice, label: "Autre question ?" } }, NOW), tallied);
const skewed = applyPacketSnapshot(empty, { at: "2026-10-31T11:00:20.000000Z", poll: choice }, NOW);
assert.equal(skewed.poll.id, choice.id, "un écart d'horloge de moins de 30 s reste accepté");

// Réponse HTTP partie avant une diffusion, arrivée après : elle ne défait
// pas l'état plus récent (sondage fermé) ; une réponse plus récente passe.
const closedByPacket = applyPacketSnapshot(answered, { at: later, poll: { ...choice, open: false } }, NOW);
const staleHttp = applyHttpSnapshot(closedByPacket, { at, poll: choice }, [1]);
assert.equal(staleHttp, closedByPacket, "HTTP plus ancien que l'état : ignoré");
const freshHttp = applyHttpSnapshot(closedByPacket, { at: "2026-10-31T11:00:02.000000Z", poll: null }, null);
assert.deepEqual(freshHttp, { at: "2026-10-31T11:00:02.000000Z", poll: null, myResponse: null });
const myAnswer = applyHttpSnapshot(answered, { at: later, poll: { ...choice, responses_count: 3 } }, [2]);
assert.deepEqual(myAnswer.myResponse, [2], "la réponse HTTP porte la réponse de la personne");

// Pourcentages de répondants (choix multiple : la somme peut dépasser 100).
assert.deepEqual(percentages({ respondents: 3, counts: [1, 3, 0] }), [33, 100, 0]);
assert.deepEqual(percentages({ respondents: 0, counts: [0, 0] }), [0, 0]);

// Formats : un descripteur par type.
assert.deepEqual(Object.keys(FORMATS), ["choice", "scale", "short_text"]);
assert.deepEqual(formatOf(scale).resultLabels(scale), ["1", "2", "3", "4", "5"]);
assert.deepEqual(formatOf(choice).resultLabels(choice), ["A", "B", "C"]);
assert.equal(formatOf(choice).ready(formatOf(choice).initialDraft()), false);
assert.equal(formatOf(text).ready("  "), false);
assert.equal(formatOf(text).submitted("  Clair "), "Clair");
assert.equal(validPoll({ ...choice, kind: "toString" }), false, "pas de type hérité d'Object");
