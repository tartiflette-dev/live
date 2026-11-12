// Santé de la caméra publiée, chez qui la publie (monté dans <LiveKitRoom>).
//
// Cas observé en direct : une caméra n'a émis que la couche simulcast basse
// (320x180) tout le direct, enregistrement compris ; une autre chutait par
// moments. Ni la cause (encodeur, débit, processeur) ni la couche réellement
// émise ne sont visibles côté serveur : seul le navigateur qui publie les
// connaît.
//
//   1. Mesure : toutes les SAMPLE_INTERVAL_MS, getStats sur l'émetteur de la
//      caméra (couches, raison de la limite, encodeur, capture), POST
//      /api/camera_samples, enregistrée pendant le direct seulement. La régie
//      alerte sous 720p (CameraSample).
//   2. Repli : à partir de FALLBACK_DELAY_MS après la publication, si
//      l'encodeur n'émet que la couche basse sur deux relevés (règle
//      complète dans camera_monitor.mjs), la caméra est republiée SANS
//      simulcast en 720p H.264, capture ramenée de 1080p à 720p : une seule
//      fois par entrée dans la salle, issue journalisée (CameraSample `event`).
//
// Le repli change la piste publiée : l'enregistrement par piste en ouvre une
// nouvelle, et le montage retient la plus récente non vide (ParticipantMux).
//
// Une panne de la mesure ne touche pas la salle et ne s'affiche pas à
// l'intervenant (il n'y peut rien) : un avertissement en console, une fois ;
// la régie signale la caméra publiée mais non mesurée.

import { useEffect } from "react";
import { useRoomContext } from "@livekit/components-react";
import { RoomEvent, Track, VideoPresets } from "livekit-client";
import { csrfToken } from "./state_button";
import { FALLBACK_DELAY_MS, SAMPLE_INTERVAL_MS } from "./camera_stats.mjs";
import { createCameraMonitor } from "./camera_monitor.mjs";

const REPORT_URL = "/api/camera_samples";
const FALLBACK_CAPTURE_OPTIONS = { resolution: VideoPresets.h720.resolution };
const FALLBACK_PUBLISH_OPTIONS = {
  source: Track.Source.Camera,
  simulcast: false,
  videoCodec: "h264",
  videoEncoding: VideoPresets.h720.encoding,
};

// Refus attendus, sans erreur : 403 hors direct (coulisses), 429 mesure trop
// rapprochée de la précédente (republication).
const EXPECTED_REFUSALS = new Set([403, 429]);

// @return true si la mesure est enregistrée, false si refusée sans erreur
async function postSample({ slug, speakerToken, sample }) {
  const response = await fetch(REPORT_URL, {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrfToken() },
    body: JSON.stringify({ slug, speaker_token: speakerToken || null, sample }),
  });
  if (response.ok) return true;
  if (EXPECTED_REFUSALS.has(response.status)) return false;
  throw new Error(`serveur ${response.status}`);
}

export function CameraHealth({ slug, speakerToken }) {
  const room = useRoomContext();

  useEffect(() => {
    const monitor = createCameraMonitor({
      participant: room.localParticipant,
      camera: Track.Source.Camera,
      fallbackCapture: FALLBACK_CAPTURE_OPTIONS,
      fallbackOptions: FALLBACK_PUBLISH_OPTIONS,
      report: (sample) => postSample({ slug, speakerToken, sample }),
    });
    let warned = false;
    let timer = null;
    let disposed = false;
    // Un seul relevé à la fois : une republication déclenche onPublished
    // pendant le relevé qui l'a faite.
    let running = false;

    const schedule = (delay) => {
      clearTimeout(timer);
      if (!disposed) timer = setTimeout(run, delay);
    };
    function run() {
      if (running) return;
      running = true;
      monitor.sample()
        .catch((err) => {
          if (warned) return;
          warned = true;
          console.warn("[caméra] mesure de l'émetteur non remontée", err);
        })
        .finally(() => {
          running = false;
          schedule(SAMPLE_INTERVAL_MS);
        });
    }

    // Une caméra (re)publiée est jugée FALLBACK_DELAY_MS plus tard, puis
    // mesurée au rythme normal.
    const onPublished = (publication) => {
      if (publication.source !== Track.Source.Camera) return;
      monitor.published(publication.trackSid);
      schedule(FALLBACK_DELAY_MS);
    };

    room.on(RoomEvent.LocalTrackPublished, onPublished);
    schedule(SAMPLE_INTERVAL_MS);
    return () => {
      disposed = true;
      clearTimeout(timer);
      room.off(RoomEvent.LocalTrackPublished, onPublished);
    };
  }, [room, slug, speakerToken]);

  return null;
}
