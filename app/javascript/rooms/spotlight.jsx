// Mise en avant d'un intervenant pendant le direct.
//
// L'état vit dans les métadonnées de la salle LiveKit, écrites par Rails
// seul (RoomSpotlight, endpoint réservé à l'animation) :
// `{"spotlight": "<identity>"}`. Tous les clients le lisent par
// useRoomInfo, mis à jour à chaque RoomMetadataChanged et livré à la
// connexion : un arrivant tardif voit l'état courant. Aucun client ne
// décide. L'animation DEMANDE au serveur depuis la régie
// (useSpotlightControl), puis la salle affiche ce qu'elle diffuse, pour
// tout le monde, animation comprise.
//
// Ordre d'affichage, le même sur la scène et chez les spectateurs :
// partage d'écran, puis personne mise en avant, puis grille.

import { useCallback, useState } from "react";
import { useParticipantInfo, useRoomInfo } from "@livekit/components-react";
import { Track } from "livekit-client";
import { csrfToken } from "./state_button";

// Métadonnées absentes, illisibles ou d'une autre forme : pas de mise en
// avant. Une salle aux métadonnées inattendues garde la grille.
export function parseSpotlight(metadata) {
  if (!metadata) return null;
  try {
    const identity = JSON.parse(metadata)?.spotlight;
    return typeof identity === "string" && identity !== "" ? identity : null;
  } catch {
    return null;
  }
}

export function useSpotlightIdentity() {
  const { metadata } = useRoomInfo();
  return parseSpotlight(metadata);
}

// Caméra (ou vignette, caméra coupée) de la personne mise en avant, si
// elle fait partie des pistes affichées, donc si elle est sur scène. Une
// identité partie ou inconnue laisse la mise en page par défaut.
export function spotlightTrack(tracks, identity) {
  if (!identity) return undefined;
  return tracks.find((t) => t.source === Track.Source.Camera && t.participant.identity === identity);
}

const ERROR_MESSAGES = {
  invalid_identity: "participant non reconnu",
  spotlight_update_failed: "la salle LiveKit n'a pas répondu",
};

async function sendSpotlight(url, identity) {
  const res = await fetch(url, {
    method: identity ? "POST" : "DELETE",
    credentials: "same-origin",
    redirect: "manual",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": csrfToken(),
    },
    body: identity ? JSON.stringify({ identity }) : undefined,
  });
  if (res.type === "opaqueredirect") {
    throw new Error("session animateur expirée, reconnectez-vous");
  }
  if (!res.ok) {
    const payload = await res.json().catch(() => null);
    throw new Error(ERROR_MESSAGES[payload?.error] || `serveur ${res.status}`);
  }
}

// Commande de l'animation, depuis la régie (regie.jsx). L'échec est rendu
// visible par l'appelant ; le succès n'affiche rien de plus, la salle
// diffuse le nouvel état à tous.
export function useSpotlightControl(spotlightUrl) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState(null);
  const request = useCallback(async (identity) => {
    setPending(true);
    setError(null);
    try {
      await sendSpotlight(spotlightUrl, identity);
    } catch (err) {
      setError(`Mise en avant non appliquée : ${err.message}.`);
    } finally {
      setPending(false);
    }
  }, [spotlightUrl]);
  return { request, pending, error };
}

// Pastille « En avant » sur la tuile caméra de la personne mise en avant
// (rendue par RoomTile, room_tiles.jsx), pour tous ceux qui sont sur
// scène, animation comprise : la commande est dans la régie.
// `spotlight` = { identity }.
export function SpotlightMarker({ participant, spotlight }) {
  const { identity } = useParticipantInfo({ participant });
  return identity === spotlight.identity
    ? <span className="lk-spotlight-badge" data-testid="spotlight-badge">En avant</span>
    : null;
}
