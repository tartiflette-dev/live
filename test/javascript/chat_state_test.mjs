// Frontières de confiance du client de discussion (chat_state.mjs), sous
// Node, sans navigateur. Lancé par test/integration/chat_state_test.rb.
import assert from "node:assert/strict";
import { BODY_LIMIT, INITIAL_CURSOR, mergeMessages, newestId, nextCursor, readServerMessage, unreadCount, validMessage } from "../../app/javascript/rooms/chat_state.mjs";

const message = {
  id: 1, kind: "question", author_role: "viewer", name: "Alice", body: "<script>unsafe()</script>",
  created_at: "2026-10-30T09:00:00.123456Z", updated_at: "2026-10-30T09:00:00.123456Z", answered_at: null, pinned_at: null,
};
const packet = (envelope) => new TextEncoder().encode(JSON.stringify(envelope));

// Seul un paquet SERVEUR (aucun participant émetteur), au bon topic et au bon schéma, est accepté.
assert.deepEqual(readServerMessage(packet({ topic: "chat", message }), undefined), message);
assert.equal(readServerMessage(packet({ topic: "chat", message }), { identity: "viewer-2" }), null);
assert.equal(readServerMessage(packet({ topic: "lk.transcription", message }), undefined), null);
assert.equal(readServerMessage(new TextEncoder().encode("pas du JSON"), undefined), null);
assert.equal(readServerMessage(new Uint8Array(16385), undefined), null);
assert.equal(readServerMessage(packet({ topic: "chat", message: { ...message, id: "1" } }), undefined), null);
assert.equal(readServerMessage(packet({ topic: "chat", message: { ...message, author_role: "admin" } }), undefined), null);
assert.equal(readServerMessage(packet(null), undefined), null);

assert.equal(validMessage({ ...message, body: "é".repeat(BODY_LIMIT) }), true);
assert.equal(validMessage({ ...message, body: "x".repeat(BODY_LIMIT + 1) }), false);
assert.equal(validMessage({ ...message, updated_at: "2026-10-30T09:00:00Z" }), false);
assert.equal(validMessage({ ...message, pinned_at: "hier" }), false);

// Fusion : une version plus ancienne n'écrase jamais une plus récente ; fil trié par id.
const newer = { ...message, updated_at: "2026-10-30T09:00:00.123457Z", pinned_at: "2026-10-30T09:00:00.123457Z" };
assert.deepEqual(mergeMessages([newer], [message]), [newer]);
assert.deepEqual(mergeMessages([message], [newer, newer]), [newer]);
assert.deepEqual(mergeMessages([{ ...message, id: 3 }], [message]).map(({ id }) => id), [1, 3]);
assert.deepEqual(mergeMessages([], [{ id: 99 }]), []);

// Curseur : avance sur la dernière ligne d'une page, jamais en arrière.
const cursor = nextCursor(INITIAL_CURSOR, [message, newer]);
assert.deepEqual(cursor, { updated_since: newer.updated_at, updated_since_id: "1" });
assert.equal(nextCursor(cursor, []), cursor);
assert.throws(() => nextCursor(cursor, [message]), /n'avance plus/);
assert.deepEqual(nextCursor(cursor, [{ ...newer, id: 2 }]), { updated_since: newer.updated_at, updated_since_id: "2" });

// Non-lus : les messages des autres après le dernier vu.
const thread = [1, 2, 3, 4].map((id) => ({ ...message, id }));
assert.equal(unreadCount(thread, 0, new Set()), 4);
assert.equal(unreadCount(thread, 2, new Set([4])), 1);
assert.equal(newestId(thread), 4);
assert.equal(newestId([]), 0);

process.stdout.write("chat_state : frontières de confiance, fusion, curseur et non-lus vérifiés\n");
