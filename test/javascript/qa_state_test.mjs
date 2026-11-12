// Frontières de confiance de la file Q&R côté client (qa_state.mjs), sous
// Node, sans navigateur. Lancé par test/integration/qa_state_test.rb.
import assert from "node:assert/strict";
import { LABEL_LIMIT, authorsSummary, readServerQa, validConsoleItem, validDisplayed } from "../../app/javascript/rooms/qa_state.mjs";

const displayed = { id: 3, label: "<b>Où trouver le replay ?</b>", displayed_at: "2026-10-31T10:00:00.123456Z" };
const packet = (envelope) => new TextEncoder().encode(JSON.stringify(envelope));

// Seul un paquet SERVEUR, au topic qa et à la bonne forme, est accepté.
assert.deepEqual(readServerQa(packet({ topic: "qa", displayed }), undefined), { topic: "qa", displayed });
assert.deepEqual(readServerQa(packet({ topic: "qa", displayed: null }), undefined), { topic: "qa", displayed: null });
assert.equal(readServerQa(packet({ topic: "qa", displayed }), { identity: "viewer-2" }), null);
assert.equal(readServerQa(packet({ topic: "chat", displayed }), undefined), null);
assert.equal(readServerQa(packet({ topic: "qa" }), undefined), null);
assert.equal(readServerQa(new TextEncoder().encode("pas du JSON"), undefined), null);
assert.equal(readServerQa(new Uint8Array(4097), undefined), null);
assert.equal(readServerQa(packet(null), undefined), null);

assert.equal(validDisplayed({ ...displayed, label: "é".repeat(LABEL_LIMIT) }), true);
assert.equal(validDisplayed({ ...displayed, label: "x".repeat(LABEL_LIMIT + 1) }), false);
assert.equal(validDisplayed({ ...displayed, label: "" }), false);
assert.equal(validDisplayed({ ...displayed, id: "3" }), false);
assert.equal(validDisplayed({ ...displayed, displayed_at: "hier" }), false);

const item = { id: 1, label: "Q ?", status: "open", displayed_at: null, authors: [], messages: [] };
assert.equal(validConsoleItem(item), true);
assert.equal(validConsoleItem({ ...item, status: "deleted" }), false);
assert.equal(validConsoleItem({ ...item, authors: null }), false);

const people = (...names) => names.map((name) => ({ name }));
assert.equal(authorsSummary(people("Alice")), "Alice");
assert.equal(authorsSummary(people("Alice", "Bob")), "Alice et Bob");
assert.equal(authorsSummary(people("Alice", "Bob", "Chloé")), "Alice, Bob et 1 autre");
assert.equal(authorsSummary(people("Alice", "Bob", "Chloé", "Dan")), "Alice, Bob et 2 autres");
