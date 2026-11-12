// File des mains levées côté ANIMATEUR.
//
// Monté par la régie (regie.jsx) avec l'URL posée par
// webinar_regies/show.html.erb. Les endpoints restent réservés à
// l'animation (authenticate_animateur! + where_animated_by) — une URL
// forgée n'obtient rien.
//
// Vérité serveur relue APRÈS CHAQUE mutation ET par POLL (5 s), même
// pattern que RecordingControl. Un grant/revoke concurrent (ex. autre
// onglet, ou revoke automatique par end!) remonte en <10 s.
//
// Charte : couleurs et typo via variables CSS (regie.css —
// `.regie .lk-hand-raise-host`) ; inline styles interdits ici (aucune couleur
// en dur).
//
// Erreurs attendues (fail-loud) :
//   - 409 hand_raise_conflict        → la main n'est plus active (déjà
//     révoquée, ou webinaire plus live) ;
//   - 403 payment_required           → le viewer n'a pas payé ;
//   - 502 permission_update_failed   → LiveKit a refusé l'update
//     (participant déconnecté, SDK error). L'état en base passe
//     uncertain — on relit la liste pour l'afficher.

import { useCallback, useEffect, useRef, useState } from "react";
import { csrfToken } from "./state_button";
import { clockTime } from "./clock_time.mjs";

const POLL_INTERVAL_MS = 5000;

async function jsonFetch(url, { method = "GET" } = {}) {
  const res = await fetch(url, {
    method,
    credentials: "same-origin",
    redirect: "manual",
    headers: {
      "Accept": "application/json",
      "X-CSRF-Token": csrfToken(),
    },
  });
  if (res.type === "opaqueredirect") {
    throw new Error("session expirée (redirection sign_in)");
  }
  if (!res.ok) {
    let payload = null;
    try { payload = await res.json(); } catch (_) { /* body non-JSON toléré */ }
    const code = payload && payload.error;
    const message = code === "payment_required" ? "Spectateur non payé — refusé."
                 : code === "hand_raise_conflict" ? "Main plus active (déjà révoquée ou direct terminé)."
                 : code === "permission_update_failed" ? "LiveKit a refusé la mise à jour (participant déconnecté ?)."
                 : `serveur ${res.status}`;
    throw new Error(message);
  }
  return res.json();
}

function labelFor(state) {
  switch (state) {
    case "waiting":  return "Donner la parole";
    case "granting": return "En cours…";
    case "granted":  return "Retirer la parole";
    case "revoking": return "En cours…";
    case "uncertain": return "Relancer le retrait";
    default: return null;
  }
}

function actionFor(state) {
  // waiting / granting → grant ; granted / revoking / uncertain → revoke
  // (revoke est idempotent, réconcilie l'état flottant).
  if (state === "waiting" || state === "granting") return "grant";
  return "revoke";
}

// Venu·e participer (caméra et micro), pas encore admis·e : la personne
// attend sans le savoir (sa salle lui dit seulement « dans un instant ») —
// la régie le met en évidence pour que l'animation l'admette vite.
export const toAdmit = (hand) => hand.wants_video && hand.state === "waiting";

// `onHandsChange` (facultatif) reçoit la file à chaque relecture : la régie
// en tire le résumé de son repli « Mains levées ».
export function HandRaiseHost({ listUrl, onHandsChange }) {
  const [hands, setHands]       = useState([]);
  const [busyId, setBusyId]     = useState(null);
  const [netError, setNetError] = useState(null);
  const mountedRef = useRef(true);
  useEffect(() => () => { mountedRef.current = false; }, []);

  const refresh = useCallback(async () => {
    try {
      const payload = await jsonFetch(listUrl);
      if (!mountedRef.current) return;
      setHands(Array.isArray(payload) ? payload : []);
      setNetError(null);
    } catch (err) {
      if (!mountedRef.current) return;
      setNetError(err.message || "réseau");
    }
  }, [listUrl]);

  useEffect(() => {
    if (onHandsChange) onHandsChange(hands);
  }, [hands, onHandsChange]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, POLL_INTERVAL_MS);
    return () => clearInterval(t);
  }, [refresh]);

  const handleAction = useCallback(async (hand, verb) => {
    if (busyId) return;
    setBusyId(hand.id);
    try {
      // URL construite à partir de la base host : <listUrl>/<id>/<grant|revoke>.
      // Le serveur garde la décision (scope host_sub) ; un ID forgé → 404.
      const url = `${listUrl}/${hand.id}/${verb}`;
      await jsonFetch(url, { method: "POST" });
      await refresh();
    } catch (err) {
      if (!mountedRef.current) return;
      setNetError(err.message || "réseau");
      await refresh();
    } finally {
      if (mountedRef.current) setBusyId(null);
    }
  }, [busyId, listUrl, refresh]);

  if (hands.length === 0 && !netError) {
    return (
      <div className="lk-hand-raise-host" data-testid="hand-raise-host">
        <span className="lk-hand-raise-host__header" data-testid="hand-raise-host-empty">Aucune main levée.</span>
      </div>
    );
  }

  const toAdmitCount = hands.filter(toAdmit).length;

  return (
    <div className="lk-hand-raise-host" data-testid="hand-raise-host">
      <span className="lk-hand-raise-host__header">File ({hands.length})</span>
      {toAdmitCount > 0 ? (
        <span className="lk-hand-raise-host__a-admettre" role="status" data-testid="hand-raise-to-admit">
          {toAdmitCount === 1 ? "1 participant·e à admettre en caméra et micro" : `${toAdmitCount} participant·es à admettre en caméra et micro`}
        </span>
      ) : null}
      <ul className="lk-hand-raise-host__list">
        {hands.map((hand) => {
          const label = labelFor(hand.state);
          const verb  = actionFor(hand.state);
          return (
            <li
              key={hand.id}
              className={toAdmit(hand) ? "lk-hand-raise-host__item lk-hand-raise-host__item--a-admettre" : "lk-hand-raise-host__item"}
              data-testid="hand-raise-item"
              data-hand-state={hand.state}
            >
              <span className="lk-hand-raise-host__name" data-testid="hand-raise-name">{hand.name}</span>
              {/* Inscrit « participant » (lien public) : sa main s'est levée
                  à son entrée, il attend d'être admis en caméra et micro. */}
              {hand.wants_video ? (
                <span className="lk-hand-raise-host__meta" data-testid="hand-raise-wants-video">veut intervenir en vidéo</span>
              ) : null}
              <span className="lk-hand-raise-host__meta">{clockTime(hand.raised_at, { seconds: true })}</span>
              {hand.error ? (
                <span className="lk-hand-raise-host__alert" role="alert">LiveKit refuse — relancez.</span>
              ) : null}
              {label ? (
                <button
                  type="button"
                  className="lk-hand-raise-host__button"
                  onClick={() => handleAction(hand, verb)}
                  disabled={busyId === hand.id || hand.state === "granting" || hand.state === "revoking"}
                  data-testid={verb === "grant" ? "hand-raise-grant" : "hand-raise-revoke"}
                >
                  {busyId === hand.id ? "…" : label}
                </button>
              ) : null}
            </li>
          );
        })}
      </ul>
      {netError ? (
        <span className="lk-hand-raise-host__alert" role="alert" data-testid="hand-raise-host-error">{netError}</span>
      ) : null}
    </div>
  );
}
