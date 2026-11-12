// Relevé de la caméra publiée et repli sans simulcast, sans React ni
// livekit-client importés : le participant local, la source caméra, la
// capture et les options de republication sont fournis (camera_health.jsx),
// ce qui permet de tester la règle « un seul repli » sous Node
// (camera_monitor_test.mjs).
//
// `sample()` relève l'émetteur de la caméra publiée et non coupée, applique
// la règle du repli (decide) et remet la mesure à `report` avec son `event`
// (contrat CameraSample).
//
// Règle du repli, à partir de FALLBACK_DELAY_MS après la publication ou le
// rallumage :
//   • KEEP (judgeSimulcast : plusieurs couches, ou liaison limitée par le
//     débit) clôt le jugement de la publication ;
//   • FALL_BACK sur deux relevés, sans KEEP entre eux, republie sans
//     simulcast ; un relevé non concluant (couche en pause dynacast, aucune
//     image) entre les deux ne remet rien à zéro. En coulisses, dynacast
//     peut tenir h et f en pause jusqu'à l'abonnement de l'egress : le repli
//     tombe alors 20 à 30 s après le début de l'enregistrement, et le
//     montage, qui ne garde que la caméra la plus récente, perd ces secondes ;
//   • au plus un repli pour toute la vie du moniteur, c'est-à-dire par
//     entrée dans la salle.
//
// `report` rend false quand le serveur refuse la mesure sans erreur (hors
// direct, trop rapprochée) : l'issue d'un repli et la mesure qui l'a
// déclenché sont alors renvoyées telles quelles, jusqu'à être journalisées
// (repli fait en coulisses, avant le début du direct).

import { FALLBACK_DELAY_MS, FALL_BACK, KEEP, judgeSimulcast, readLayers, summarize } from "./camera_stats.mjs";

// Les relevés suivent un setTimeout de 10 s, qui peut tomber une fraction de
// milliseconde avant l'échéance mesurée par l'horloge monotone.
const JUDGE_TOLERANCE_MS = 500;

export const FALLBACK = "simulcast_fallback";
export const FALLBACK_FAILED = "simulcast_fallback_failed";

async function measure(track) {
  const { sender } = track;
  const stats = [...(await sender.getStats()).values()];
  const encodings = sender.getParameters().encodings ?? [];
  return { layers: readLayers(stats, encodings), encodings, capture: track.mediaStreamTrack.getSettings() };
}

// Même piste, republiée. Entre les deux, la capture est rouverte sur la même
// caméra en `fallbackCapture` (720p) : la capture 1080p de la salle, en
// couche unique, chargerait davantage l'encodeur qui a lâché. Caméra
// d'identifiant inconnu : pas de réouverture, qui pourrait prendre une autre
// caméra ; elle est republiée à sa capture actuelle.
//
// Un refus — de la dépublication, de la capture ou de la republication —
// rétablit la publication d'origine, avec ses options, si la caméra n'est
// plus publiée. livekit-client arrête la capture AVANT de la rouvrir : après
// un échec de réouverture (« Could not start video source », fréquent sous
// Windows), la piste est terminée. Elle est d'abord rouverte avec ses réglages
// d'origine ; si cela échoue aussi, elle reste dépubliée : l'intervenant voit
// sa caméra coupée, pas une image noire, et la rallume d'un clic.
// @return issue journalisée (FALLBACK | FALLBACK_FAILED)
async function republishWithoutSimulcast({ participant, publication, camera, fallbackCapture, fallbackOptions, log }) {
  const { track } = publication;
  const originalOptions = { ...publication.options, source: camera };
  try {
    await participant.unpublishTrack(track, false);
    const { deviceId } = track.mediaStreamTrack.getSettings();
    if (deviceId) await track.restartTrack({ ...fallbackCapture, deviceId: { exact: deviceId } });
    await participant.publishTrack(track, fallbackOptions);
    return FALLBACK;
  } catch (err) {
    log.error("[caméra] republication sans simulcast refusée, retour à la publication d'origine", err);
    if (!participant.getTrackPublication(camera)) await restoreOriginal({ participant, track, originalOptions, log });
    return FALLBACK_FAILED;
  }
}

async function restoreOriginal({ participant, track, originalOptions, log }) {
  try {
    if (track.mediaStreamTrack.readyState === "ended") await track.restartTrack();
  } catch (reopenError) {
    log.error("[caméra] capture non rouverte, caméra laissée coupée", reopenError);
    return;
  }
  try {
    await participant.publishTrack(track, originalOptions);
  } catch (restoreError) {
    log.error("[caméra] publication d'origine non rétablie", restoreError);
  }
}

// `now` : horloge monotone (un délai, pas une date).
export function createCameraMonitor({ participant, camera, fallbackCapture, fallbackOptions, report, now = () => performance.now(), log = console }) {
  const publishedAt = new Map();
  const judged = new Set();
  const suspected = new Set();
  let fellBack = false;
  // Repli à journaliser : issue et mesure qui l'a déclenché.
  let pendingFallback = null;

  const due = (sid) => !fellBack && !judged.has(sid)
    && now() - publishedAt.get(sid) >= FALLBACK_DELAY_MS - JUDGE_TOLERANCE_MS;

  // @return mesure du repli à journaliser, null sans repli
  async function decide(sid, publication, measured) {
    if (!due(sid)) return null;
    const verdict = judgeSimulcast(measured);
    if (verdict === KEEP) {
      judged.add(sid);
      suspected.delete(sid);
      return null;
    }
    if (verdict !== FALL_BACK) return null;
    if (!suspected.has(sid)) {
      suspected.add(sid);
      return null;
    }
    judged.add(sid);
    fellBack = true;
    const event = await republishWithoutSimulcast({ participant, publication, camera, fallbackCapture, fallbackOptions, log });
    return { publication_sid: sid, event, ...summarize(measured) };
  }

  return {
    published(sid) {
      publishedAt.set(sid, now());
    },

    async sample() {
      const publication = participant.getTrackPublication(camera);
      const track = publication?.videoTrack;
      if (!track?.sender) return;
      const sid = publication.trackSid;
      // Caméra éteinte : rien à relever, et le jugement repart du rallumage
      // (les couches remontent comme à une publication).
      if (publication.isMuted) {
        publishedAt.delete(sid);
        suspected.delete(sid);
        return;
      }
      if (!publishedAt.has(sid)) publishedAt.set(sid, now());

      const measured = await measure(track);
      pendingFallback = (await decide(sid, publication, measured)) ?? pendingFallback;
      const accepted = await report(pendingFallback ?? { publication_sid: sid, event: "sample", ...summarize(measured) });
      if (accepted) pendingFallback = null;
    },
  };
}
