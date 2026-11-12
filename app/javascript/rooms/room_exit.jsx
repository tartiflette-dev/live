// Écran de sortie de salle — retour d'un animateur :
// « je viens de cliquer sur quitter et je me retrouve un peu
// nulle part », un toast vendor « Disconnected » en anglais pour seule
// explication.
//
// Rendu par room.jsx à la place de la salle dès qu'on l'a quittée
// (« Quitter », expulsion, salle fermée, connexion perdue), pour les trois
// rôles. Il dit pourquoi on est dehors, où en sont le direct et
// l'enregistrement (relus sur le serveur, rafraîchis toutes les
// POLL_INTERVAL_MS : la fin automatique ou un autre animateur peuvent les
// changer), et propose de revenir. L'animation garde « Terminer le direct »
// tant que le direct est en cours.
//
// Fail-loud : un état illisible s'affiche comme tel, jamais deviné.

import { useCallback, useEffect, useState } from "react";
import { DisconnectReason } from "livekit-client";
import { StateButton } from "./state_button";

const POLL_INTERVAL_MS = 5000;
const ACTIVE_RECORDING_STATUSES = ["starting", "recording", "stopping"];
const LIVE_LABELS = { draft: "pas encore commencé", live: "en cours", ended: "terminé" };

function exitTitle(reason) {
  switch (reason) {
    case DisconnectReason.CLIENT_INITIATED:
      return "Vous avez quitté la salle";
    case DisconnectReason.DUPLICATE_IDENTITY:
      return "Vous avez rejoint la salle depuis un autre onglet ou appareil";
    case DisconnectReason.PARTICIPANT_REMOVED:
      return "Vous avez été retiré de la salle";
    case DisconnectReason.ROOM_DELETED:
    case DisconnectReason.ROOM_CLOSED:
      return "La salle a été fermée";
    default:
      return "La connexion à la salle a été perdue";
  }
}

// Payload de /recordings/status.json (animation, intervenant) ou de son
// pendant spectateur : un composite actif ou des pistes en captation.
function recordingRunning(payload) {
  const status = payload && payload.recording && payload.recording.status;
  return ACTIVE_RECORDING_STATUSES.includes(status) || Number(payload && payload.tracks_recording) > 0;
}

async function readJson(url) {
  const res = await fetch(url, { credentials: "same-origin", redirect: "manual", headers: { "Accept": "application/json" } });
  if (!res.ok) throw new Error(`serveur ${res.status || res.type}`);
  return res.json();
}

export function RoomExit({ reason, stateUrl, endUrl, recordingStatusUrl, onRejoin }) {
  const [liveState, setLiveState] = useState(null);
  const [recording, setRecording] = useState(null);
  const [readError, setReadError] = useState(null);
  const [actionError, setActionError] = useState(null);

  const refresh = useCallback(async () => {
    try {
      const [state, rec] = await Promise.all([
        stateUrl ? readJson(stateUrl) : null,
        recordingStatusUrl ? readJson(recordingStatusUrl) : null,
      ]);
      if (state) setLiveState(state.state);
      if (rec) setRecording(recordingRunning(rec) ? "running" : "stopped");
      setReadError(null);
    } catch (err) {
      setReadError(err.message || "réseau");
    }
  }, [stateUrl, recordingStatusUrl]);

  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, POLL_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [refresh]);

  const recordingLabel = recording === "running" ? "en cours" : recording === "stopped" ? "arrêté" : "état inconnu";

  return (
    <section className="lk-exit-screen" data-testid="room-exit" aria-labelledby="room-exit-title">
      <h2 className="lk-exit-screen__title" id="room-exit-title">{exitTitle(reason)}</h2>
      <dl className="lk-exit-screen__facts">
        <dt>Direct</dt>
        <dd data-testid="room-exit-live">{LIVE_LABELS[liveState] || "…"}</dd>
        <dt>Enregistrement</dt>
        <dd data-testid="room-exit-recording">{recordingStatusUrl ? recordingLabel : "état inconnu"}</dd>
      </dl>
      <div className="lk-exit-screen__actions">
        <button type="button" className="lk-exit-screen__button" data-testid="room-exit-rejoin" onClick={onRejoin}>
          Rejoindre à nouveau
        </button>
        {endUrl && liveState === "live" ? (
          <StateButton
            state="live"
            stateUrl={stateUrl}
            endUrl={endUrl}
            onStateChange={(state) => { setLiveState(state); refresh(); }}
            onError={setActionError}
          />
        ) : null}
      </div>
      {readError ? (
        <p className="lk-exit-screen__error" role="alert" data-testid="room-exit-read-error">
          État du direct illisible : {readError}
        </p>
      ) : null}
      {actionError ? (
        <p className="lk-exit-screen__error" role="alert" data-testid="room-exit-action-error">{actionError}</p>
      ) : null}
    </section>
  );
}
