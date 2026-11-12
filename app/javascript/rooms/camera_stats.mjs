// Lecture des statistiques de l'émetteur caméra (RTCRtpSender) : fonctions
// pures, sans navigateur, testées sous Node (test/javascript/camera_stats_test.mjs).
// Consommé par camera_monitor.mjs, qui relève, remonte (CameraSample) et
// applique le verdict du repli sans simulcast (judgeSimulcast).
//
// Une couche (rid q / h / f en simulcast, sans rid sinon) ÉMET quand elle
// est active, a une largeur et produit des images. Une couche inactive a été
// mise en pause par dynacast (personne ne la regarde, `encodings[].active`) :
// ce n'est pas une dégradation.

export const SAMPLE_INTERVAL_MS = 10000;
// Délai avant de juger la publication : les autres caméras d'un direct mesuré
// ont émis leur couche haute entre 0,13 et 5,5 s après la publication.
export const FALLBACK_DELAY_MS = 10000;
// Couche basse seule émise : en direct, un encodeur H.264 qui ne tenait
// pas le simulcast n'a sorti que la couche q (320x180 en simulcast 720p).
// Depuis la 1080p, la couche q est la 360p (VideoPresets.h360, room.jsx) :
// 640x360 pour une capture 1080p ou 720p, moins en 4:3 ou en portrait.
export const FALLBACK_MAX_WIDTH = 640;

// Chrome concatène les sous-encodeurs du SimulcastEncoderAdapter : tronqué
// à la borne du serveur (CameraSample::MAX_ENCODER_LENGTH) plutôt que de
// faire refuser la mesure.
export const MAX_ENCODER_LENGTH = 128;

// Verdicts de judgeSimulcast ; null = pas encore jugeable.
export const FALL_BACK = "fall_back";
export const KEEP = "keep";

const NO_LIMIT = "none";

function dimension(value) {
  return Number.isFinite(value) && value > 0 ? Math.round(value) : null;
}

function isEmitting(layer) {
  return layer.active && layer.width > 0 && layer.fps > 0;
}

function pausedCount(encodings) {
  return encodings.filter((encoding) => encoding.active === false).length;
}

// @param stats valeurs d'un RTCStatsReport (sender.getStats())
// @param encodings sender.getParameters().encodings
// @return couches vidéo émises : { rid, active, width, height, fps, reason, encoder }
export function readLayers(stats, encodings) {
  const activeByRid = new Map(encodings.map((encoding) => [encoding.rid ?? null, encoding.active !== false]));
  return stats
    .filter((entry) => entry.type === "outbound-rtp" && (entry.kind ?? entry.mediaType) === "video")
    .map((entry) => ({
      rid: entry.rid ?? null,
      active: activeByRid.get(entry.rid ?? null) ?? entry.active !== false,
      width: dimension(entry.frameWidth),
      height: dimension(entry.frameHeight),
      fps: Number.isFinite(entry.framesPerSecond) ? entry.framesPerSecond : null,
      reason: entry.qualityLimitationReason ?? null,
      encoder: entry.encoderImplementation ?? null,
    }));
}

// Mesure au contrat CameraSample (sans publication_sid ni event).
// Raison : la première limite signalée par une couche, sinon celle de la
// couche haute — une couche coupée faute de débit porte la raison.
export function summarize({ layers, encodings, capture }) {
  const top = layers.filter(isEmitting)
    .reduce((best, layer) => (!best || layer.width * layer.height > best.width * best.height ? layer : best), null);
  const limit = layers.map((layer) => layer.reason).find((reason) => reason && reason !== NO_LIMIT);
  return {
    top_width: top?.width ?? null,
    top_height: top?.height ?? null,
    frames_per_second: top?.fps ?? null,
    quality_limitation_reason: limit ?? top?.reason ?? null,
    encoder_implementation: (top?.encoder ?? layers.find((layer) => layer.encoder)?.encoder)?.slice(0, MAX_ENCODER_LENGTH) ?? null,
    capture_width: dimension(capture.width),
    capture_height: dimension(capture.height),
    paused_layers: pausedCount(encodings),
    layers: layers.map(({ rid, active, width, height, fps, reason }) => ({ rid, active, width, height, fps, reason })),
  };
}

// Verdict sur une publication simulcast :
//   • FALL_BACK — cas observé en direct : seule la couche basse émet alors que
//     toutes sont demandées et que le débit ne l'explique pas ; l'encodeur
//     ne tient pas le simulcast, il faut republier sans. Une limite `cpu`
//     y mène aussi, sciemment : un seul encodage 720p soulage le processeur,
//     au prix des couches basses pour les spectateurs.
//   • KEEP — publication sans simulcast, plusieurs couches émises, une seule
//     mais plus large que la couche basse, ou liaison limitée par le débit
//     (`bandwidth` : le réseau, pas l'encodeur ; une couche unique en 720p
//     passerait encore moins, cas d'une liaison instable). Jugé à partir de
//     10 s après la publication, la montée en débit du départ est passée.
//   • null — pas jugeable maintenant, à rejuger au relevé suivant : couche
//     en pause (dynacast : on ne sait pas ce que l'encodeur ferait d'une
//     couche demandée), aucune image émise.
export function judgeSimulcast({ layers, encodings }) {
  if (encodings.length < 2 || layers.some((layer) => layer.reason === "bandwidth")) return KEEP;
  if (pausedCount(encodings) > 0) return null;
  const emitting = layers.filter(isEmitting);
  if (emitting.length === 0) return null;
  return emitting.length === 1 && emitting[0].width <= FALLBACK_MAX_WIDTH ? FALL_BACK : KEEP;
}
