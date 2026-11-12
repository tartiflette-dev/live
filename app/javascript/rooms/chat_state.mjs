// Discussion du direct — frontières de confiance du client.
// Fonctions pures, testées sous Node (test/javascript/chat_state_test.mjs).
//
// Deux sources alimentent le fil : les pages HTTP de Rails (la vérité,
// curseur serveur) et les paquets temps réel du data channel LiveKit. Un
// paquet n'est accepté que s'il vient du SERVEUR (aucun participant
// émetteur : RoomServiceClient#send_data) et porte un message au schéma
// attendu ; tout le reste est ignoré.

export const PAGE_SIZE = 50;
// Bornes de Message (app/models/message.rb, Registration/Speaker pour le nom).
export const BODY_LIMIT = 1000;
export const NAME_LIMIT = 120;
export const INITIAL_CURSOR = Object.freeze({ updated_since: null, updated_since_id: null });

const MICROSECOND_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const KINDS = ["chat", "question"];
const AUTHOR_ROLES = ["host", "speaker", "viewer"];
const MAX_PACKET_BYTES = 16384;

const optionalTimestamp = (value) => value === null || (typeof value === "string" && MICROSECOND_UTC.test(value));
const boundedText = (value, limit) => typeof value === "string" && Array.from(value).length <= limit;

export function validMessage(message) {
  return !!message && Number.isSafeInteger(message.id) && message.id > 0 &&
    KINDS.includes(message.kind) && AUTHOR_ROLES.includes(message.author_role) &&
    boundedText(message.name, NAME_LIMIT) && boundedText(message.body, BODY_LIMIT) &&
    [message.created_at, message.updated_at].every((value) => typeof value === "string" && MICROSECOND_UTC.test(value)) &&
    optionalTimestamp(message.answered_at) && optionalTimestamp(message.pinned_at);
}

// `participant` est renseigné par livekit-client quand un PARTICIPANT a
// émis le paquet ; il est absent pour un envoi serveur.
export function readServerMessage(payload, participant) {
  if (participant || !(payload instanceof Uint8Array) || payload.byteLength > MAX_PACKET_BYTES) return null;
  let envelope;
  try {
    envelope = JSON.parse(new TextDecoder().decode(payload));
  } catch {
    return null;
  }
  return envelope && envelope.topic === "chat" && validMessage(envelope.message) ? envelope.message : null;
}

// Fusion par id ; une version plus ancienne (updated_at) n'écrase jamais
// une plus récente — un paquet temps réel en retard ne défait pas un
// drapeau rattrapé par le poll. Fil trié par id (ordre d'envoi).
export function mergeMessages(previous, incoming) {
  const byId = new Map(previous.map((message) => [message.id, message]));
  for (const message of incoming) {
    if (!validMessage(message)) continue;
    const existing = byId.get(message.id);
    if (!existing || message.updated_at >= existing.updated_at) byId.set(message.id, message);
  }
  return [...byId.values()].sort((a, b) => a.id - b.id);
}

// Le curseur n'avance QUE sur une page Rails (triée updated_at, id) : il
// reprend après son dernier élément. Une page qui ne l'avance pas est une
// anomalie serveur — on s'arrête plutôt que de boucler.
export function nextCursor(cursor, page) {
  if (page.length === 0) return cursor;
  const last = page[page.length - 1];
  const stalled = cursor.updated_since !== null &&
    (last.updated_at < cursor.updated_since ||
      (last.updated_at === cursor.updated_since && last.id <= Number(cursor.updated_since_id)));
  if (stalled) throw new Error("La synchronisation de la discussion n'avance plus.");
  return { updated_since: last.updated_at, updated_since_id: String(last.id) };
}

// Non lus : messages des autres, plus récents que le dernier vu.
export function unreadCount(messages, lastSeenId, ownIds) {
  return messages.filter((message) => message.id > lastSeenId && !ownIds.has(message.id)).length;
}

export function newestId(messages) {
  return messages.length > 0 ? messages[messages.length - 1].id : 0;
}
