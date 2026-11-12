// Indicateur passif « Enregistrement en cours » (consentement). Lecture seule, pas de bouton, pas d'arrêt.
// Monté pour tous ceux qui publient ou peuvent publier (room.jsx) :
//   • spectateur dans la salle (à qui l'on peut donner la parole) :
//     /w/:slug/recordings/status.json, autorisé par le cookie
//     `registration_id` confirmé ;
//   • scène (/stage) et intervenant (/join : le pilotage est
//     dans la régie) : /webinars/:slug/recordings/status.json, session
//     animateur ou jeton `t` revalidé par le serveur.
// Les deux réponses portent `participant_recording` et `recording.status`.
//
// Doctrine fail-loud : l'erreur réseau est affichée (role="alert") —
// même règle que RecordingControl. Un spectateur dont la caméra est
// ouverte doit pouvoir voir soit « REC », soit « statut injoignable »,
// jamais le vide.

import { useCallback, useEffect, useRef, useState } from "react";
// Partage des styles « REC » avec RecordingControl (couleur, taille du
// point, variante erreur) — un seul lieu définit la palette.
import { STYLE_WRAPPER, STYLE_DOT, STYLE_ERROR } from "./recording_control_styles";

const POLL_INTERVAL_MS = 5000;

const STYLE_LABEL = { fontSize: "0.9rem" };

async function fetchStatus(url) {
  const res = await fetch(url, {
    method: "GET",
    credentials: "same-origin",
    redirect: "manual",
    headers: { "Accept": "application/json" },
  });
  if (res.type === "opaqueredirect") {
    throw new Error("session expirée");
  }
  if (!res.ok) {
    throw new Error(`serveur ${res.status}`);
  }
  return res.json();
}

export function RecordingIndicator({ statusUrl }) {
  const [recording, setRecording] = useState(false);
  const [netErr, setNetErr]       = useState(null);
  const mountedRef = useRef(true);
  useEffect(() => () => { mountedRef.current = false; }, []);

  const refresh = useCallback(async () => {
    try {
      const payload = await fetchStatus(statusUrl);
      if (!mountedRef.current) return;
      // Priorité au drapeau explicite consentement ; fallback sur le
      // status du Recording si l'ancien contrat est encore servi.
      const active = payload && (
        payload.participant_recording === true ||
        (payload.recording && [ "starting", "recording", "stopping" ].includes(payload.recording.status))
      );
      setRecording(Boolean(active));
      setNetErr(null);
    } catch (err) {
      if (!mountedRef.current) return;
      setNetErr(err.message || "réseau");
    }
  }, [statusUrl]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, POLL_INTERVAL_MS);
    return () => clearInterval(t);
  }, [refresh]);

  if (!recording && !netErr) {
    return null;
  }

  return (
    <span
      className="lk-recording-indicator"
      style={STYLE_WRAPPER}
      role="status"
      data-testid="recording-indicator"
      data-active={recording ? "true" : "false"}
    >
      {recording ? (
        <>
          <span style={STYLE_DOT} aria-hidden="true" data-testid="recording-indicator-dot" />
          <span style={STYLE_LABEL} data-testid="recording-indicator-label">Enregistrement en cours</span>
        </>
      ) : null}
      {netErr ? (
        <span style={STYLE_ERROR} role="alert" data-testid="recording-indicator-error">
          Statut enregistrement injoignable : {netErr}
        </span>
      ) : null}
    </span>
  );
}
