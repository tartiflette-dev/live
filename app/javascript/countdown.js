// Compte à rebours + bascule auto vers la salle.
//
// Contrat DOM : un élément `[data-countdown]` porte
//   • data-starts-at : ISO 8601 (heure planifiée du direct) ;
//   • data-state-url : URL absolue/racine du state.json public.
// L'élément contient un `[data-countdown-time]` (span écrit à chaque tick).
//
// Deux boucles indépendantes :
//   • rafraîchissement 1 s du libellé hh:mm:ss (jj hh:mm:ss > 24 h) ;
//   • sondage 15 s de state.json → si state passe à `live`, on recharge
//     la page (le contrôleur bascule alors sur la salle) ; si `ended`,
//     on stoppe les deux boucles (la page reste sur pre_live avec le
//     libellé « direct terminé » servi au prochain refresh manuel).
//
// Zéro console.* (doctrine fail-loud : la console n'est pas lue par les
// spectateurs ; les erreurs de fetch sont silencieuses, la prochaine
// itération du polling ré-essaiera). No-op si aucun élément trouvé —
// permet de charger ce module inconditionnellement depuis application.js
// sans casser les pages sans compte à rebours.

const POLL_INTERVAL_MS = 15000;
const TICK_INTERVAL_MS = 1000;

const pad2 = (n) => String(n).padStart(2, "0");

const formatRemaining = (millis) => {
  const total = Math.max(0, Math.floor(millis / 1000));
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const hms = `${pad2(hours)}:${pad2(minutes)}:${pad2(seconds)}`;
  return days > 0 ? `${days} j ${hms}` : hms;
};

const bindCountdown = (root) => {
  const startsAtRaw = root.dataset.startsAt;
  const stateUrl = root.dataset.stateUrl;
  const label = root.querySelector("[data-countdown-time]") || root;

  const startsAt = Date.parse(startsAtRaw);
  if (Number.isNaN(startsAt)) {
    return;
  }

  let tickHandle = null;
  let pollHandle = null;

  const stopAll = () => {
    if (tickHandle !== null) {
      window.clearInterval(tickHandle);
      tickHandle = null;
    }
    if (pollHandle !== null) {
      window.clearInterval(pollHandle);
      pollHandle = null;
    }
  };

  const renderTick = () => {
    label.textContent = formatRemaining(startsAt - Date.now());
  };

  const pollState = async () => {
    if (!stateUrl) {
      return;
    }
    try {
      const response = await fetch(stateUrl, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });
      if (!response.ok) {
        return;
      }
      const payload = await response.json();
      if (payload && payload.state === "live") {
        stopAll();
        window.location.reload();
      } else if (payload && payload.state === "ended") {
        stopAll();
      }
    } catch (_error) {
      // Silence délibéré : réessai au prochain tour de polling.
    }
  };

  renderTick();
  tickHandle = window.setInterval(renderTick, TICK_INTERVAL_MS);
  pollHandle = window.setInterval(pollState, POLL_INTERVAL_MS);
};

export function mountCountdown() {
  const roots = document.querySelectorAll("[data-countdown]");
  roots.forEach(bindCountdown);
}
