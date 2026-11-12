// Lecteur de replay (replays/show) — contrat DOM :
//   • `[data-replay-player]` porte data-beats-url (POST JSON des battements) ;
//   • il contient la `<video>` et, s'il y a des sous-titres, le bouton
//     `[data-replay-subtitles]` (data-label-show / data-label-hide).
//
// Battements (ReplayViewsController) : { session, from, to, playing }, le
// passage lu depuis le battement précédent, en secondes de la vidéo :
// toutes les 15 s pendant la lecture, à la pause, avant un saut, à la fin,
// et quand la page est quittée (fetch keepalive, qui garde l'en-tête CSRF).
// `session` = un identifiant tiré à l'ouverture de la page : une séance par
// onglet. Échecs silencieux (le battement suivant reprend où celui-ci
// s'arrêtait seulement s'il est parti : le serveur ne crédite que ce que
// l'horloge permet).
//
// Sous-titres : le bouton les affiche ou les masque, le choix est gardé
// pour les replays suivants ; les commandes natives du lecteur restent
// utilisables, le bouton suit leur état.
//
// No-op sans `[data-replay-player]`.

const BEAT_INTERVAL_MS = 15000;
const SUBTITLES_KEY = "replay-subtitles";

const newSessionKey = () => {
  if (crypto.randomUUID) return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
};

const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content || "";

const bindBeats = (root, video) => {
  const url = root.dataset.beatsUrl;
  const session = newSessionKey();
  let segmentStart = null;
  let lastPosition = 0;
  let timer = null;

  const send = (from, to, playing) => {
    fetch(url, {
      method: "POST",
      keepalive: true,
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
      body: JSON.stringify({ session, from, to, playing })
    }).catch(() => {});
  };

  // Clôt le passage en cours à `to` ; le suivant repart de là si la
  // lecture continue.
  const flush = (to, playing) => {
    if (segmentStart === null) return;
    send(segmentStart, to, playing);
    segmentStart = playing ? to : null;
  };

  const stopTimer = () => {
    clearInterval(timer);
    timer = null;
  };

  video.addEventListener("playing", () => {
    if (segmentStart === null) segmentStart = video.currentTime;
    if (!timer) timer = setInterval(() => flush(video.currentTime, true), BEAT_INTERVAL_MS);
  });
  video.addEventListener("timeupdate", () => {
    if (!video.seeking) lastPosition = video.currentTime;
  });
  video.addEventListener("pause", () => {
    stopTimer();
    flush(video.seeking ? lastPosition : video.currentTime, false);
  });
  // `seeking` arrive quand currentTime a déjà sauté : le passage lu
  // s'arrête à la dernière position connue avant le saut.
  video.addEventListener("seeking", () => {
    if (segmentStart === null) return;
    send(segmentStart, lastPosition, !video.paused);
    segmentStart = null;
  });
  video.addEventListener("seeked", () => {
    lastPosition = video.currentTime;
    if (!video.paused) segmentStart = video.currentTime;
  });
  video.addEventListener("ended", () => {
    stopTimer();
    flush(video.duration, false);
  });
  window.addEventListener("pagehide", () => flush(video.currentTime, false));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") flush(video.currentTime, !video.paused);
  });
};

const bindSubtitles = (root, video) => {
  const button = root.querySelector("[data-replay-subtitles]");
  const track = video.textTracks && video.textTracks[0];
  if (!button || !track) return;

  const render = () => {
    const shown = track.mode === "showing";
    button.setAttribute("aria-pressed", String(shown));
    button.textContent = shown ? button.dataset.labelHide : button.dataset.labelShow;
  };
  const show = (shown) => {
    track.mode = shown ? "showing" : "hidden";
    try {
      localStorage.setItem(SUBTITLES_KEY, shown ? "1" : "0");
    } catch (_error) {
      // Stockage refusé (navigation privée) : le choix vaut pour cette page.
    }
    render();
  };

  let remembered = false;
  try {
    remembered = localStorage.getItem(SUBTITLES_KEY) === "1";
  } catch (_error) {
    remembered = false;
  }
  track.mode = remembered ? "showing" : "hidden";
  render();
  button.addEventListener("click", () => show(track.mode !== "showing"));
  video.textTracks.addEventListener("change", render);
};

export const mountReplayPlayer = () => {
  document.querySelectorAll("[data-replay-player]").forEach((root) => {
    const video = root.querySelector("video");
    if (!video) return;
    bindBeats(root, video);
    bindSubtitles(root, video);
  });
};
