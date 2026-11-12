// Lecture des statistiques de l'émetteur caméra (camera_stats.mjs), sous
// Node, sans navigateur. Lancé par test/integration/camera_stats_test.rb.
// Les rapports imitent Chrome : une entrée outbound-rtp par couche (rid).
import assert from "node:assert/strict";
import { FALL_BACK, KEEP, MAX_ENCODER_LENGTH, judgeSimulcast, readLayers, summarize } from "../../app/javascript/rooms/camera_stats.mjs";

const SIMULCAST = [{ rid: "q", active: true }, { rid: "h", active: true }, { rid: "f", active: true }];
const outbound = (rid, width, height, fps, reason = "none") => ({
  type: "outbound-rtp", kind: "video", rid, frameWidth: width, frameHeight: height, framesPerSecond: fps,
  qualityLimitationReason: reason, encoderImplementation: "SimulcastEncoderAdapter (libvpx)",
});
const CAPTURE = { width: 1280, height: 720 };
const measured = (stats, encodings = SIMULCAST) => ({ layers: readLayers(stats, encodings), encodings, capture: CAPTURE });

// Trois couches émises : la couche haute est la 1280x720, aucune pause.
const healthy = measured([
  outbound("q", 320, 180, 30), outbound("h", 640, 360, 30), outbound("f", 1280, 720, 29.5),
  { type: "outbound-rtp", kind: "audio", rid: undefined }, { type: "remote-inbound-rtp", kind: "video" },
]);
assert.equal(healthy.layers.length, 3);
const healthySample = summarize(healthy);
assert.deepEqual(
  [healthySample.top_width, healthySample.top_height, healthySample.frames_per_second, healthySample.paused_layers],
  [1280, 720, 29.5, 0],
);
assert.equal(healthySample.quality_limitation_reason, "none");
assert.equal(healthySample.encoder_implementation, "SimulcastEncoderAdapter (libvpx)");
assert.deepEqual([healthySample.capture_width, healthySample.capture_height], [1280, 720]);
assert.deepEqual(healthySample.layers[2], { rid: "f", active: true, width: 1280, height: 720, fps: 29.5, reason: "none" });
assert.equal(judgeSimulcast(healthy), KEEP);

// Cas observé en direct : seule la couche q émet, h et f n'envoient aucune
// image.
const lowOnly = measured([outbound("q", 320, 180, 20), outbound("h", undefined, undefined, undefined), outbound("f", 0, 0, 0)]);
assert.deepEqual([summarize(lowOnly).top_width, summarize(lowOnly).top_height], [320, 180]);
assert.equal(judgeSimulcast(lowOnly), FALL_BACK);
// Même cas quand le navigateur ne rapporte que la couche q.
assert.equal(judgeSimulcast(measured([outbound("q", 320, 180, 20)])), FALL_BACK);
// Même cas en simulcast 1080p : la couche q est la 640x360, h (960x540) et f muettes.
assert.equal(judgeSimulcast(measured([outbound("q", 640, 360, 20), outbound("h", 0, 0, 0), outbound("f", 0, 0, 0)])), FALL_BACK);

// Débit montant insuffisant : la couche haute est coupée par le réseau, pas par l'encodeur → garder le simulcast.
const starved = measured([outbound("q", 320, 180, 20, "bandwidth"), outbound("h", 640, 360, 0, "bandwidth"), outbound("f", 1280, 720, 0, "bandwidth")]);
assert.equal(judgeSimulcast(starved), KEEP);
assert.equal(summarize(starved).quality_limitation_reason, "bandwidth");

// Raison portée par une couche coupée seulement : elle remonte quand même.
assert.equal(summarize(measured([outbound("q", 320, 180, 20), outbound("f", 1280, 720, 0, "cpu")])).quality_limitation_reason, "cpu");

// Dynacast : h et f en pause (personne ne les regarde) → pas jugeable, rejugé plus tard.
const pausedEncodings = [{ rid: "q", active: true }, { rid: "h", active: false }, { rid: "f", active: false }];
const paused = measured([outbound("q", 320, 180, 20), outbound("h", 640, 360, 0), outbound("f", 1280, 720, 0)], pausedEncodings);
assert.equal(summarize(paused).paused_layers, 2);
assert.equal(paused.layers[2].active, false);
assert.equal(judgeSimulcast(paused), null);

// Publication sans simulcast (après repli) : une seule couche sans rid, gardée telle quelle.
const single = measured([{ ...outbound(undefined, 1280, 720, 30), rid: undefined }], [{ active: true }]);
assert.equal(single.layers[0].rid, null);
assert.equal(summarize(single).top_width, 1280);
assert.equal(judgeSimulcast(measured([{ ...outbound(undefined, 320, 180, 30), rid: undefined }], [{ active: true }])), KEEP);

// Une seule couche émise, mais plus large que la couche basse (640) : pas le cas du repli.
assert.equal(judgeSimulcast(measured([outbound("h", 960, 540, 25), outbound("f", 0, 0, 0)])), KEEP);

// Aucune image émise : couche haute inconnue, pas jugeable.
assert.equal(judgeSimulcast(measured([outbound("q", 320, 180, 0)])), null);
const frozen = summarize(measured([outbound("q", 320, 180, 0)]));
assert.deepEqual([frozen.top_width, frozen.top_height, frozen.frames_per_second], [null, null, null]);
assert.equal(frozen.encoder_implementation, "SimulcastEncoderAdapter (libvpx)");

// Limite `cpu` : le repli s'applique (un seul encodage soulage le processeur).
assert.equal(judgeSimulcast(measured([outbound("q", 320, 180, 15, "cpu")])), FALL_BACK);

// Encodeur au nom concaténé trop long : tronqué à la borne du serveur, jamais refusé.
const verbose = summarize(measured([{ ...outbound("f", 1280, 720, 30), encoderImplementation: "x".repeat(300) }]));
assert.equal(verbose.encoder_implementation.length, MAX_ENCODER_LENGTH);
