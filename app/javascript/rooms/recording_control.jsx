// Contrôle enregistrement de la régie : états explicites, déplacé de la salle vers la régie.
//
// Monté par regie.jsx avec les URL `recording-status-url` /
// `recording-start-url` posées par webinar_regies/show.html.erb (régie :
// animation du webinaire seulement). La salle n'expose plus que
// l'indicateur en lecture seule (RecordingIndicator). Les endpoints
// gardent leur propre autorisation (RecordingsController).
//
// Le bouton pilote l'enregistrement de la VUE D'ENSEMBLE (egress composite).
// Les pistes individuelles vivent à côté : le serveur en donne le nombre
// (`tracks_recording`) pour qu'un composite en échec ne passe pas pour un
// échec total quand les pistes tournent.
//
// Direct terminé (`webinar_state: "ended"`) : plus de
// bouton pour enregistrer — le serveur refuse, on enregistre de nouveau en
// reprenant le direct. Un arrêt en cours reste visible jusqu'au bout.
//
// L'état affiché vient du serveur (relu par poll, accéléré pendant une
// transition). Seul optimisme local : afficher « Démarrage… » / « Arrêt… »
// entre le clic et la réponse. Le bouton reste inactif jusqu'à ce que le
// serveur confirme ou que CONFIRMATION_TIMEOUT_MS s'écoule ; il ignore les
// clics pendant BUTTON_MORPH_GUARD_MS quand il change d'action (le second
// clic d'un double clic sur « Arrêter » ne relance pas un enregistrement).
//
// Fail-loud : un échec est TOUJOURS affiché, jamais avalé. Pas de console.*,
// pas d'alert — panneau visible role="alert". Le texte serveur peut être une
// sortie brute de plusieurs lignes : statut court et humain, texte brut dans
// un « Détails » replié, de largeur bornée (regie.css `.lk-recording-error`).

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { csrfToken } from "./state_button";
// Palette partagée avec <RecordingIndicator> — un seul lieu définit
// couleurs et dimensions (cf. recording_control_styles.js).
import { STYLE_WRAPPER, STYLE_DOT, STYLE_DOT_OFF, STYLE_BUTTON, STYLE_ERROR } from "./recording_control_styles";

// Poll : 1 s pendant les 20 premières secondes d'une transition, pour que
// l'écran rejoigne vite le serveur ; 5 s sinon (endpoint bon marché, SELECT
// indexé + réconciliation).
const POLL_INTERVAL_MS = 5000;
const TRANSITION_POLL_INTERVAL_MS = 1000;
// Au-delà, une requête sans réponse est abandonnée et une transition qui
// dure est signalée comme telle ; le démarrage devient annulable.
const CONFIRMATION_TIMEOUT_MS = 20000;
const BUTTON_MORPH_GUARD_MS = 1000;

const PHASE_BY_STATUS = { starting: "starting", recording: "recording", stopping: "stopping", failed: "failed" };
const TRANSITIONAL_PHASES = ["starting", "stopping"];

// `loading` tant que le serveur n'a pas répondu une première fois : rien
// n'est affirmé, rien n'est cliquable. `done` comme l'absence = `idle`.
function serverPhase(snapshot) {
  if (!snapshot) return "loading";
  return (snapshot.recording && PHASE_BY_STATUS[snapshot.recording.status]) || "idle";
}

function displayedPhase(snapshot, pendingAction) {
  if (pendingAction === "start") return "starting";
  if (pendingAction === "stop") return "stopping";
  return serverPhase(snapshot);
}

const STOP = { action: "stop", label: "Arrêter l'enregistrement" };

// Libellés et action du bouton pour une phase. `action: null` = bouton
// inactif. Pendant une transition, le bouton (animé) porte seul le libellé ;
// le statut ne parle que si elle s'éternise. `failure` = statut court d'un
// échec (le détail brut est à part).
function present(phase, { tracksRecording, stalled, stoppable, liveEnded }) {
  if (liveEnded && (phase === "idle" || phase === "failed")) {
    return {
      status: "Enregistrement arrêté",
      action: null,
      label: null,
      failure: phase === "failed" ? "Dernier enregistrement en échec." : null,
    };
  }
  switch (phase) {
    case "loading":
      return { status: null, action: null, label: "Enregistrer" };
    case "starting":
      return stalled
        ? { status: "Démarrage toujours en attente du serveur", ...(stoppable ? STOP : { action: null, label: "Démarrage…" }) }
        : { status: null, action: null, label: "Démarrage…" };
    case "recording":
      return { status: "REC", ...STOP };
    case "stopping":
      return { status: stalled ? "Arrêt toujours en attente du serveur" : null, action: null, label: "Arrêt…" };
    case "failed":
      return {
        status: null,
        action: "start",
        label: "Réessayer",
        failure: tracksRecording > 0
          ? "Vue d'ensemble en échec, pistes individuelles en cours."
          : "Enregistrement en échec.",
      };
    default:
      return {
        status: tracksRecording > 0 ? "Pistes individuelles en cours" : null,
        action: "start",
        label: "Enregistrer",
      };
  }
}

// Identité de l'état serveur affiché : un message d'action non confirmée
// n'a plus lieu d'être dès qu'elle change.
function snapshotKey(snapshot) {
  const recording = snapshot && snapshot.recording;
  return recording ? `${recording.id}:${recording.status}` : "none";
}

function toSnapshot(payload) {
  return {
    recording: (payload && payload.recording) || null,
    tracksRecording: Number((payload && payload.tracks_recording) || 0),
    participantRecording: Boolean(payload && payload.participant_recording),
    liveEnded: Boolean(payload && payload.webinar_state === "ended"),
  };
}

async function jsonFetch(url, { method = "GET", body } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), CONFIRMATION_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      method,
      credentials: "same-origin",
      // redirect:"manual" (miroir
      // de state_button.jsx) : un endpoint recording protégé qui
      // renvoie 302 vers /sign_in (session perdue + token absent) ferait
      // suivre le fetch au HTML sign_in par défaut — JSON.parse échouerait
      // sur un message opaque. En manuel, response.type === "opaqueredirect"
      // = signal explicite « auth manquante » qu'on remonte fail-loud.
      redirect: "manual",
      signal: controller.signal,
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
    // 200 OU 409 (conflit — déjà démarré, ou déjà arrêté) portent tous deux
    // l'état réel. Tout autre statut = erreur à faire remonter.
    if (!res.ok && res.status !== 409) {
      // Un corps JSON peut dire quelque chose ; une page d'erreur HTML non.
      const json = (res.headers.get("Content-Type") || "").includes("json");
      const text = json ? await res.text().catch(() => "") : "";
      throw new Error(`serveur ${res.status}${text ? `: ${text.slice(0, 120)}` : ""}`);
    }
    return await res.json();
  } catch (err) {
    if (err.name === "AbortError") {
      throw new Error(`pas de réponse du serveur en ${CONFIRMATION_TIMEOUT_MS / 1000} s`);
    }
    throw err;
  } finally {
    clearTimeout(timer);
  }
}

export function RecordingControl({ statusUrl, startUrl }) {
  const [snapshot, setSnapshot] = useState(null);
  const [pendingAction, setPendingAction] = useState(null);
  const [actionError, setActionError] = useState(null);
  const [pollError, setPollError] = useState(null);
  const [stalledPhase, setStalledPhase] = useState(null);
  const [guarded, setGuarded] = useState(false);
  // Ref pour éviter setState après unmount (le poll peut résoudre après
  // démontage de la scène si l'host quitte la page).
  const mountedRef = useRef(true);
  // Garde synchrone : deux clics dans la même frame voient le même état
  // React, seule une ref les départage.
  const actionInFlightRef = useRef(false);
  const pollInFlightRef = useRef(false);
  // Ordre d'application des réponses. Un poll prend son numéro à l'émission,
  // un POST à sa RÉSOLUTION : un poll parti avant la réponse du POST (donc
  // susceptible d'avoir lu la base avant l'action) et revenu après est
  // ignoré ; revenu avant, il est écrasé par le POST.
  const requestSeqRef = useRef(0);
  const appliedSeqRef = useRef(0);
  const snapshotRef = useRef(null);
  const guardTimerRef = useRef(null);
  useEffect(() => () => {
    mountedRef.current = false;
    clearTimeout(guardTimerRef.current);
  }, []);

  const applyPayload = useCallback((payload, seq) => {
    if (!mountedRef.current || seq < appliedSeqRef.current) return;
    appliedSeqRef.current = seq;
    const next = toSnapshot(payload);
    if (snapshotKey(next) !== snapshotKey(snapshotRef.current)) setActionError(null);
    snapshotRef.current = next;
    setSnapshot(next);
  }, []);

  const refresh = useCallback(async () => {
    if (pollInFlightRef.current) return;
    pollInFlightRef.current = true;
    const seq = ++requestSeqRef.current;
    try {
      applyPayload(await jsonFetch(statusUrl), seq);
      if (mountedRef.current) setPollError(null);
    } catch (err) {
      if (mountedRef.current) setPollError(err.message || "réseau");
    } finally {
      pollInFlightRef.current = false;
    }
  }, [statusUrl, applyPayload]);

  const phase = displayedPhase(snapshot, pendingAction);
  const transitional = TRANSITIONAL_PHASES.includes(phase);
  // Horloge de la transition en cours : repart à chaque nouvelle phase
  // transitoire (le clic compte comme son début). Liée à la phase, elle ne
  // déborde pas sur la suivante.
  const stalled = transitional && stalledPhase === phase;
  // Poll rapide seulement tant que la transition est dans les temps : une
  // transition qui s'éternise ne doit pas charger un livekit déjà lent.
  const fastPoll = transitional && !stalled;

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, fastPoll ? TRANSITION_POLL_INTERVAL_MS : POLL_INTERVAL_MS);
    return () => clearInterval(t);
  }, [refresh, fastPoll]);

  useEffect(() => {
    setStalledPhase(null);
    if (!transitional) return undefined;
    const t = setTimeout(() => setStalledPhase(phase), CONFIRMATION_TIMEOUT_MS);
    return () => clearTimeout(t);
  }, [phase, transitional]);

  const stopUrl = snapshot && snapshot.recording && snapshot.recording.stop_url;
  const view = present(phase, {
    tracksRecording: snapshot ? snapshot.tracksRecording : 0,
    stalled,
    stoppable: Boolean(stopUrl),
    liveEnded: Boolean(snapshot && snapshot.liveEnded),
  });

  // Layout effect : le bouton devient inactif dans la même tâche que le
  // changement de libellé, avant tout clic possible (un effet ordinaire
  // laisserait une frame où le nouveau bouton est cliquable).
  const previousRef = useRef({ phase, action: view.action });
  useLayoutEffect(() => {
    const previous = previousRef.current;
    previousRef.current = { phase, action: view.action };
    if (previous.phase === "loading" || !view.action || previous.action === view.action) return;
    setGuarded(true);
    clearTimeout(guardTimerRef.current);
    guardTimerRef.current = setTimeout(() => {
      if (mountedRef.current) setGuarded(false);
    }, BUTTON_MORPH_GUARD_MS);
  }, [phase, view.action]);

  const runAction = useCallback(async (action, url) => {
    if (actionInFlightRef.current || !url) return;
    actionInFlightRef.current = true;
    setPendingAction(action);
    setActionError(null);
    try {
      const payload = await jsonFetch(url, { method: "POST", body: {} });
      applyPayload(payload, ++requestSeqRef.current);
    } catch (err) {
      if (mountedRef.current) setActionError(err.message || "réseau");
    } finally {
      actionInFlightRef.current = false;
      if (mountedRef.current) setPendingAction(null);
    }
  }, [applyPayload]);

  const handleClick = useCallback(() => {
    if (guarded || !view.action) return;
    runAction(view.action, view.action === "start" ? startUrl : stopUrl);
  }, [guarded, view.action, runAction, startUrl, stopUrl]);

  const recording = snapshot && snapshot.recording;
  const dotOn = phase === "starting" || phase === "recording" || phase === "stopping" ||
    Boolean(snapshot && (snapshot.participantRecording || snapshot.tracksRecording > 0));
  const partial = phase === "failed" && snapshot.tracksRecording > 0;
  const stopSide = view.action === "stop" || phase === "stopping";

  return (
    <span
      className={`lk-recording-control is-${phase}${partial ? " is-partial" : ""}`}
      style={STYLE_WRAPPER}
      data-testid="recording-control"
      data-state={phase}
    >
      <span
        className="lk-recording-dot"
        style={dotOn ? STYLE_DOT : STYLE_DOT_OFF}
        aria-hidden="true"
        data-testid="recording-dot"
        data-active={dotOn ? "true" : "false"}
      />
      {view.status ? (
        <span className="lk-recording-status" role="status" data-testid="recording-status">{view.status}</span>
      ) : null}
      {view.label ? (
        <button
          type="button"
          style={STYLE_BUTTON}
          onClick={handleClick}
          disabled={!view.action || guarded}
          aria-busy={transitional ? "true" : "false"}
          data-testid={stopSide ? "recording-stop" : "recording-start"}
        >
          {view.label}
        </button>
      ) : null}
      {view.failure ? (
        <span className="lk-recording-error" style={STYLE_ERROR} role="alert" data-testid="recording-error">
          {view.failure}
          {recording.error_message ? (
            <details className="lk-recording-error__details" data-testid="recording-error-details">
              <summary>Détails</summary>
              <code>{recording.error_message}</code>
            </details>
          ) : null}
        </span>
      ) : null}
      {actionError ? (
        <span className="lk-recording-error" style={STYLE_ERROR} role="alert" data-testid="recording-action-error">
          Action non confirmée : {actionError}
        </span>
      ) : null}
      {pollError ? (
        <span className="lk-recording-error" style={STYLE_ERROR} role="alert" data-testid="recording-network-error">
          Statut enregistrement injoignable : {pollError}
        </span>
      ) : null}
    </span>
  );
}
