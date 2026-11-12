// File Q&R du direct — frontières de confiance du client.
// Fonctions pures, testées sous Node (test/javascript/qa_state_test.mjs).
//
// Le serveur (QaBroadcast) diffuse `{ topic: "qa", displayed: <item> | null }`
// à chaque changement de la file. Un paquet n'est accepté que s'il vient du
// SERVEUR (aucun participant émetteur) et porte la forme attendue.

// Borne de QaItem::LABEL_LIMIT (app/models/qa_item.rb).
export const LABEL_LIMIT = 500;
export const STATUSES = ["open", "answered", "dismissed"];

const MICROSECOND_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const MAX_PACKET_BYTES = 4096;

const positiveId = (value) => Number.isSafeInteger(value) && value > 0;
const timestamp = (value) => typeof value === "string" && MICROSECOND_UTC.test(value);
const label = (value) => typeof value === "string" && value.length > 0 && Array.from(value).length <= LABEL_LIMIT;

// Question affichée à l'écran : `null` (aucune) ou { id, label, displayed_at }.
export function validDisplayed(displayed) {
  return displayed === null ||
    (!!displayed && positiveId(displayed.id) && label(displayed.label) && timestamp(displayed.displayed_at));
}

// `participant` est renseigné par livekit-client quand un PARTICIPANT a émis
// le paquet ; il est absent pour un envoi serveur. Rend l'enveloppe ou null.
export function readServerQa(payload, participant) {
  if (participant || !(payload instanceof Uint8Array) || payload.byteLength > MAX_PACKET_BYTES) return null;
  let envelope;
  try {
    envelope = JSON.parse(new TextDecoder().decode(payload));
  } catch {
    return null;
  }
  return envelope && envelope.topic === "qa" && validDisplayed(envelope.displayed) ? envelope : null;
}

// Item de la console (QaItem#console_attributes) : le minimum dont l'écran a
// besoin pour ne rien afficher de faux.
export function validConsoleItem(item) {
  return !!item && positiveId(item.id) && label(item.label) && STATUSES.includes(item.status) &&
    (item.displayed_at === null || timestamp(item.displayed_at)) &&
    Array.isArray(item.authors) && Array.isArray(item.messages);
}

// « Alice », « Alice et Bob », « Alice, Bob et 2 autres ».
export function authorsSummary(authors, shown = 2) {
  const names = authors.map((author) => author.name);
  if (names.length <= shown) return names.join(" et ");
  const rest = names.length - shown;
  return `${names.slice(0, shown).join(", ")} et ${rest} autre${rest > 1 ? "s" : ""}`;
}
