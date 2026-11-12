// Prise de parole côté SPECTATEUR.
//
// Rôle serveur du composant : il est monté UNIQUEMENT quand le viewer a
// réellement accès à la salle live (data-viewer-hand-raises-url posé par
// webinars/room.html.erb seulement si action=viewer ET
// current_registration.confirmée). Un spectateur anonyme ou non payé
// n'obtient pas la URL — l'absence de data-attr suffit à ne pas monter.
// Les endpoints restent gardés serveur (CurrentRegistration +
// HandRaiseControl#ensure_payment!) : un data-attr forgé ne passe pas.
//
// Vérité : la main active du spectateur est RELUE côté serveur après
// chaque mutation ET par poll (5 s, miroir recording_control.jsx). La
// permission de publier est lue depuis `useLocalParticipantPermissions`
// (push LiveKit) — c'est elle qui pilote l'affichage de la barre de contrôle :
// jamais un état optimiste local, jamais confiance au seul polling côté
// serveur (le push LiveKit peut arriver avant le prochain tick).
//
// Accord à l'image : la parole accordée n'ouvre
// la publication qu'avec un accord en cours (PublishPermission). Sans lui,
// la barre s'affiche quand même, Micro et Caméra ouvrant la fenêtre de
// consentement ; l'accord donné, la salle ouvre la publication. Le
// participant du lien public (main pré-déclarée, `wants_video`,
// B) venu pour intervenir en caméra et micro : admis sans accord, la fenêtre
// s'ouvre d'elle-même, une fois par main ; seul son POST fait ouvrir la
// publication par le serveur.
//
// Charte : couleurs/typo passent par les variables CSS (room.css —
// `.lk-hand-raise--viewer`) ; les inline styles ici n'encodent QUE de la
// mise en page (gap, flex), aucune couleur hexadécimale.
//
// Fail-loud : erreurs réseau, 403 payment_required, 409 conflict et 502
// permission_update_failed sont affichés en message visible ; jamais
// console/alert (doctrine room.jsx).

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Track } from "livekit-client";
import { useLocalParticipantPermissions } from "@livekit/components-react";
import { csrfToken } from "./state_button";
import { RoomControls } from "./room_controls";
import { useRestorePreferredDevices } from "./device_preferences";
import { useParticipantConsent } from "./participant_consent";
import { NewTabHint } from "./new_tab_hint";

const POLL_INTERVAL_MS = 5000;

function derive(hand, canPublishLive, consentNeeded, participantWaiting) {
  if (!hand) {
    return { label: "Lever la main", action: "raise", status: null, granted: false, uncertain: false };
  }
  switch (hand.state) {
    case "waiting":
      // Venu·e participer (caméra et micro) : un message neutre, jamais
      // « main levée » ni l'attente d'une admission (choix produit) ;
      // le bouton rend le choix d'observer.
      if (hand.wants_video && participantWaiting) {
        return { label: participantWaiting.cancelLabel, action: "lower", status: participantWaiting.message, granted: false, uncertain: false };
      }
      return { label: "Baisser la main", action: "lower", status: "Main levée — en attente de l'animateur.", granted: false, uncertain: false };
    case "granting":
      return { label: "Baisser la main", action: "lower", status: "Attribution en cours…", granted: false, uncertain: false };
    case "granted":
      if (consentNeeded) {
        return { label: "Rendre la parole", action: "lower", status: "Parole accordée — donnez votre accord à l'image pour allumer caméra ou micro.", granted: false, uncertain: false };
      }
      return { label: "Rendre la parole", action: "lower", status: canPublishLive ? "Vous avez la parole." : "Parole accordée — permission en cours de propagation…", granted: canPublishLive, uncertain: false };
    case "revoking":
      return { label: "Rendre la parole", action: "lower", status: "Retrait en cours…", granted: canPublishLive, uncertain: false };
    case "uncertain":
      return { label: "Baisser la main", action: "lower", status: "État incertain — réessayez (l'animateur peut aussi relancer).", granted: canPublishLive, uncertain: true };
    default:
      return { label: "Lever la main", action: "raise", status: null, granted: false, uncertain: false };
  }
}

async function jsonFetch(url, { method = "GET", body } = {}) {
  const res = await fetch(url, {
    method,
    credentials: "same-origin",
    redirect: "manual",
    headers: {
      "Accept": "application/json",
      "X-CSRF-Token": csrfToken(),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.type === "opaqueredirect") {
    throw new Error("session expirée (redirection sign_in)");
  }
  if (!res.ok && res.status !== 204) {
    let payload = null;
    try { payload = await res.json(); } catch (_) { /* body non-JSON toléré */ }
    const code = payload && payload.error;
    const message = code === "payment_required" ? "Paiement requis pour prendre la parole."
                 : code === "hand_raise_conflict" ? "Prise de parole indisponible (direct non actif)."
                 : code === "permission_update_failed" ? "Permission LiveKit refusée. Réessayez."
                 : code === "registration_required" ? "Inscription confirmée requise."
                 : `serveur ${res.status}`;
    throw new Error(message);
  }
  if (res.status === 204) return null;
  return res.json();
}

export function HandRaiseViewer({ endpointUrl, participantWaiting, recordingNotice }) {
  const [hand, setHand]         = useState(null);
  const [busy, setBusy]         = useState(false);
  const [netError, setNetError] = useState(null);
  const mountedRef = useRef(true);
  useEffect(() => () => { mountedRef.current = false; }, []);

  const perms = useLocalParticipantPermissions();
  const canPublishLive = !!(perms && perms.canPublish);
  const consent = useParticipantConsent();
  const consentNeeded = !!consent?.needed;

  const refresh = useCallback(async () => {
    try {
      const payload = await jsonFetch(endpointUrl);
      if (!mountedRef.current) return;
      setHand(payload && payload.hand_raise);
      setNetError(null);
    } catch (err) {
      if (!mountedRef.current) return;
      setNetError(err.message || "réseau");
    }
  }, [endpointUrl]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, POLL_INTERVAL_MS);
    return () => clearInterval(t);
  }, [refresh]);

  const handleClick = useCallback(async (action) => {
    if (busy) return;
    setBusy(true);
    try {
      const payload = await jsonFetch(endpointUrl, {
        method: action === "raise" ? "POST" : "DELETE",
      });
      if (!mountedRef.current) return;
      // DELETE renvoie 204 (null) ; POST renvoie l'enregistrement.
      setHand(action === "raise" ? payload : null);
      setNetError(null);
    } catch (err) {
      if (!mountedRef.current) return;
      setNetError(err.message || "réseau");
    } finally {
      if (mountedRef.current) setBusy(false);
    }
  }, [busy, endpointUrl]);

  const { label, action, status, granted } = useMemo(
    () => derive(hand, canPublishLive, consentNeeded, participantWaiting),
    [hand, canPublishLive, consentNeeded, participantWaiting],
  );
  useRestorePreferredDevices(granted);
  const promptedHand = useRef(null);
  useEffect(() => {
    if (!consentNeeded || !hand?.wants_video || hand.state !== "granted" || promptedHand.current === hand.id) return;
    promptedHand.current = hand.id;
    consent.request([Track.Source.Microphone, Track.Source.Camera]);
  }, [consent, consentNeeded, hand]);
  const showControls = granted || (consentNeeded && hand?.state === "granted");

  return (
    <aside className="lk-hand-raise lk-hand-raise--viewer" data-testid="hand-raise-viewer">
      <div className="lk-hand-raise__row">
        <button
          type="button"
          className="lk-hand-raise__button"
          onClick={() => handleClick(action)}
          disabled={busy}
          data-testid="hand-raise-toggle"
          data-hand-state={hand ? hand.state : "idle"}
        >
          {busy ? "…" : label}
        </button>
        {status ? (
          <span className="lk-hand-raise__status" role="status" data-testid="hand-raise-status">{status}</span>
        ) : null}
      </div>
      {recordingNotice ? (
        <p className="lk-hand-raise__status" data-testid="hand-raise-notice">
          {recordingNotice} (<a href="/confidentialite" target="_blank" rel="noopener">confidentialité<NewTabHint /></a>).
        </p>
      ) : null}
      {showControls ? (
        <div className="lk-hand-raise__control" data-testid="hand-raise-controls">
          {/* « Son » est déjà dans l'en-tête du spectateur (room.jsx). */}
          <RoomControls controls={{ screenShare: false, leave: false, audioOutput: false }} />
        </div>
      ) : null}
      {netError ? (
        <span className="lk-hand-raise__error" role="alert" data-testid="hand-raise-error">{netError}</span>
      ) : null}
    </aside>
  );
}
