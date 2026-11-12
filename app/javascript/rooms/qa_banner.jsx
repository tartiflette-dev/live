// Bandeau « Question en cours » de la salle — le même
// pour TOUS les rôles : l'animation voit ce que voient les participants.
//
// La question est choisie dans la console de régie (qa_console.jsx) ; le
// serveur la diffuse sur le data channel (QaBroadcast) et la sert aussi en
// HTTP (`GET /w/:slug/qa/current`), relu toutes les 10 s : un paquet perdu
// ou une arrivée en cours de direct se rattrapent. Libellé rendu en texte
// React, jamais en HTML. Rien à afficher = rien dans la page.

import { useEffect, useState } from "react";
import { useRoomContext } from "@livekit/components-react";
import { RoomEvent } from "livekit-client";
import { readServerQa, validDisplayed } from "./qa_state.mjs";

const POLL_INTERVAL_MS = 10000;

export function QaBanner({ url, speakerToken }) {
  const room = useRoomContext();
  const [displayed, setDisplayed] = useState(null);

  useEffect(() => {
    const receive = (payload, participant) => {
      const envelope = readServerQa(payload, participant);
      if (envelope) setDisplayed(envelope.displayed);
    };
    room.on(RoomEvent.DataReceived, receive);
    return () => {
      room.off(RoomEvent.DataReceived, receive);
    };
  }, [room]);

  useEffect(() => {
    const aborter = new AbortController();
    let timer = null;
    const headers = { Accept: "application/json" };
    if (speakerToken) headers["X-Speaker-Token"] = speakerToken;
    const poll = async () => {
      try {
        const response = await fetch(url, { credentials: "same-origin", cache: "no-store", redirect: "manual", signal: aborter.signal, headers });
        const body = response.ok ? await response.json() : null;
        if (body && validDisplayed(body.displayed)) setDisplayed(body.displayed);
      } catch (_error) {
        // Bandeau secondaire : on garde l'état connu, le prochain poll réessaie.
      } finally {
        if (!aborter.signal.aborted) timer = setTimeout(poll, POLL_INTERVAL_MS);
      }
    };
    poll();
    return () => {
      aborter.abort();
      clearTimeout(timer);
    };
  }, [url, speakerToken]);

  if (!displayed) return null;
  return (
    <aside className="lk-qa-banner" role="status" aria-live="polite" data-testid="qa-banner">
      <span className="lk-qa-banner__kicker">Question en cours</span>
      <p className="lk-qa-banner__label">{displayed.label}</p>
    </aside>
  );
}
