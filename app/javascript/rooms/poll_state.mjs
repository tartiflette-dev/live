// Sondages du direct — frontières de confiance du client.
// Fonctions pures, testées sous Node (test/javascript/poll_state_test.mjs).
//
// Deux sources disent quel sondage est à l'écran : la réponse HTTP
// (GET /w/:slug/polls/current, POST d'une réponse) et les paquets du data
// channel LiveKit (PollBroadcast). Chacune porte l'état COMPLET et un
// horodatage serveur `at` : la plus récente gagne — une réponse HTTP partie
// avant une diffusion et arrivée après ne la défait pas. Seul le serveur
// publie des données dans la salle (jetons humains canPublishData: false) ;
// par défense en profondeur, un paquet n'est accepté que s'il est
// daté d'au plus PACKET_CLOCK_SKEW_MS dans le futur (un `at` forgé très loin
// figerait l'écran) et ne change jamais la question (type, libellé, options)
// d'un sondage déjà connu : il ne fait que l'ouvrir, le fermer, compter,
// montrer le résultat.
//
// Tout ce qui dépend du type de question passe par FORMATS (un descripteur
// par type, comme Poll::Format côté serveur).

// Bornes de Poll (app/models/poll.rb).
export const LABEL_LIMIT = 300;
export const OPTION_LIMIT = 120;
export const TEXT_LIMIT = 200;
export const PACKET_CLOCK_SKEW_MS = 30000;
const MICROSECOND_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
// Le serveur borne ses paquets sous 16 KiB (Poll::Format::ShortText).
const MAX_PACKET_BYTES = 16384;

const count = (value) => Number.isSafeInteger(value) && value >= 0;
const boundedText = (value, limit) => typeof value === "string" && Array.from(value).length <= limit;
const validCounts = (results, expected) =>
  Array.isArray(results.counts) && results.counts.length === expected && results.counts.every(count);

function scaleRange(options) {
  const values = [];
  for (let value = options.min; value <= options.max; value += 1) values.push(value);
  return values;
}

export const FORMATS = {
  choice: {
    label: "Choix",
    validOptions: (options) => Array.isArray(options) && options.length >= 2 && options.length <= 6 &&
      options.every((option) => boundedText(option, OPTION_LIMIT)),
    validResults: (poll, results) => validCounts(results, poll.options.length),
    resultLabels: (poll) => poll.options,
    initialDraft: () => [],
    ready: (draft) => draft.length > 0,
    submitted: (draft) => draft,
  },
  scale: {
    label: "Échelle",
    validOptions: (options) => !!options && Number.isSafeInteger(options.min) && Number.isSafeInteger(options.max) &&
      options.max > options.min && options.max - options.min <= 10,
    validResults: (poll, results) => validCounts(results, scaleRange(poll.options).length),
    resultLabels: (poll) => scaleRange(poll.options).map(String),
    initialDraft: () => null,
    ready: (draft) => draft !== null,
    submitted: (draft) => draft,
  },
  short_text: {
    label: "Réponse courte",
    validOptions: (options) => options === null,
    validResults: (_poll, results) => Array.isArray(results.answers) && results.answers.every((answer) => boundedText(answer, TEXT_LIMIT)),
    resultLabels: () => [],
    initialDraft: () => "",
    ready: (draft) => draft.trim().length > 0,
    submitted: (draft) => draft.trim(),
  },
};

export function formatOf(poll) {
  return FORMATS[poll.kind];
}

export function scaleValues(poll) {
  return scaleRange(poll.options);
}

export function validPoll(poll) {
  const format = !!poll && Object.hasOwn(FORMATS, poll.kind) ? FORMATS[poll.kind] : null;
  return !!format && Number.isSafeInteger(poll.id) && poll.id > 0 &&
    typeof poll.multiple === "boolean" && typeof poll.open === "boolean" &&
    boundedText(poll.label, LABEL_LIMIT) && count(poll.responses_count) && format.validOptions(poll.options) &&
    (poll.results === null || (!!poll.results && count(poll.results.respondents) && format.validResults(poll, poll.results)));
}

// Enveloppe { at, poll } : `poll` nul = rien à l'écran.
export function validSnapshot(snapshot) {
  return !!snapshot && typeof snapshot.at === "string" && MICROSECOND_UTC.test(snapshot.at) &&
    (snapshot.poll === null || validPoll(snapshot.poll));
}

// Paquet du data channel : sans participant émetteur nommé, au bon topic et au bon schéma.
export function readServerSnapshot(payload, participant) {
  if (participant || !(payload instanceof Uint8Array) || payload.byteLength > MAX_PACKET_BYTES) return null;
  let envelope;
  try {
    envelope = JSON.parse(new TextDecoder().decode(payload));
  } catch {
    return null;
  }
  if (!envelope || envelope.topic !== "poll") return null;
  const snapshot = { at: envelope.at, poll: envelope.poll };
  return validSnapshot(snapshot) ? snapshot : null;
}

// La question elle-même : ce qu'un paquet n'a jamais le droit de changer.
function sameQuestion(a, b) {
  return a.kind === b.kind && a.multiple === b.multiple && a.label === b.label &&
    JSON.stringify(a.options) === JSON.stringify(b.options);
}

// Le plus récent gagne. `myResponse` (la réponse de CETTE personne) ne
// voyage que par HTTP : gardée tant que le sondage reste le même, effacée
// quand il change.
function newest(state, snapshot, myResponse) {
  if (state.at && snapshot.at < state.at) return state;
  const samePoll = !!state.poll && !!snapshot.poll && state.poll.id === snapshot.poll.id;
  const kept = myResponse !== undefined ? myResponse : samePoll ? state.myResponse : null;
  return { at: snapshot.at, poll: snapshot.poll, myResponse: kept };
}

// Réponse HTTP (`my_response` nul ou absent = pas encore répondu).
export function applyHttpSnapshot(state, snapshot, myResponse) {
  return newest(state, snapshot, myResponse ?? null);
}

// Paquet temps réel : plausible seulement (cf. en-tête).
export function applyPacketSnapshot(state, snapshot, nowMs) {
  if (Date.parse(snapshot.at) > nowMs + PACKET_CLOCK_SKEW_MS) return state;
  const samePoll = !!state.poll && !!snapshot.poll && state.poll.id === snapshot.poll.id;
  if (samePoll && !sameQuestion(state.poll, snapshot.poll)) return state;
  return newest(state, snapshot, undefined);
}

// Pourcentage de répondants par option ou valeur, arrondi à l'unité. En
// choix multiple, une personne compte pour chaque option cochée : la somme
// dépasse 100 %, c'est voulu (« 60 % ont choisi A »).
export function percentages(results) {
  if (!results || !Array.isArray(results.counts)) return [];
  return results.counts.map((value) => (results.respondents > 0 ? Math.round((value * 100) / results.respondents) : 0));
}
