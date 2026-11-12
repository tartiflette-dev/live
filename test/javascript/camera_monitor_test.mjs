// Relevé et repli sans simulcast (camera_monitor.mjs) avec un participant
// LiveKit simulé, sous Node. Lancé par test/integration/camera_stats_test.rb.
import assert from "node:assert/strict";
import { FALLBACK, FALLBACK_FAILED, createCameraMonitor } from "../../app/javascript/rooms/camera_monitor.mjs";

const CAMERA = "camera";
const FALLBACK_OPTIONS = { source: CAMERA, simulcast: false, videoCodec: "h264" };
const FALLBACK_CAPTURE = { resolution: { width: 1280, height: 720 } };
// Capture rouverte en 720p sur la caméra en service, jamais sur celle par défaut.
const RESTART_720 = ["restart", { ...FALLBACK_CAPTURE, deviceId: { exact: "cam-1" } }];
// Réouverture avec les réglages d'origine (restartTrack sans argument).
const REOPEN = ["restart", undefined];
const ORIGINAL_OPTIONS = { simulcast: true, videoCodec: "h264", source: CAMERA };
const SIMULCAST = [{ rid: "q", active: true }, { rid: "h", active: true }, { rid: "f", active: true }];
const PAUSED = [{ rid: "q", active: true }, { rid: "h", active: false }, { rid: "f", active: false }];
const layer = (rid, width, height, fps, reason = "none") => ({ type: "outbound-rtp", kind: "video", rid, frameWidth: width,
  frameHeight: height, framesPerSecond: fps, qualityLimitationReason: reason, encoderImplementation: "ExternalEncoder" });
// Cas observé en direct : seule q émet, h et f actives sans image.
const LOW_ONLY = [layer("q", 320, 180, 20), layer("h", 0, 0, 0), layer("f", 0, 0, 0)];
const HEALTHY = [layer("q", 320, 180, 30), layer("h", 640, 360, 30), layer("f", 1280, 720, 30)];
const STARVED = [layer("q", 320, 180, 20, "bandwidth"), layer("h", 0, 0, 0, "bandwidth"), layer("f", 0, 0, 0, "bandwidth")];

// Participant local simulé : une publication caméra dont l'émetteur rend
// `track.stats` ; publier crée une nouvelle publication (nouveau trackSid),
// comme LiveKit après une dépublication. Comme livekit-client,
// `restartTrack` arrête la capture AVANT de la rouvrir : un échec laisse la
// piste terminée. `failures` : étapes refusées (« unpublish », « restart »,
// « publish »), dans l'ordre des appels.
function fakeParticipant({ failures = [], deviceId = "cam-1" } = {}) {
  let counter = 0;
  const calls = [];
  const track = {
    sender: { getStats: async () => new Map(track.stats.map((entry, index) => [String(index), entry])),
              getParameters: () => ({ encodings: track.encodings }) },
    mediaStreamTrack: { readyState: "live", getSettings: () => ({ width: 1920, height: 1080, deviceId }) },
    stats: LOW_ONLY, encodings: SIMULCAST,
    restartTrack: async (options) => {
      calls.push(["restart", options]);
      track.mediaStreamTrack.readyState = "ended";
      if (failures[0] === "restart") throw new Error(failures.shift());
      track.mediaStreamTrack.readyState = "live";
    },
  };
  const participant = {
    calls, track,
    publication: { trackSid: "TR_1", isMuted: false, videoTrack: track, track, options: { simulcast: true, videoCodec: "h264" } },
    getTrackPublication: (source) => (source === CAMERA ? participant.publication : undefined),
    unpublishTrack: async (unpublished, stop) => {
      calls.push(["unpublish", stop]);
      participant.publication = undefined;
      if (failures[0] === "unpublish") throw new Error(failures.shift());
    },
    publishTrack: async (published, options) => {
      calls.push(["publish", options]);
      if (failures[0] === "publish") throw new Error(failures.shift());
      counter += 1;
      participant.publication = { trackSid: `TR_re${counter}`, isMuted: false, videoTrack: published, track: published, options };
      track.encodings = options.simulcast === false ? [{ active: true }] : SIMULCAST;
    },
  };
  return participant;
}

function setup({ failures, deviceId, refusals = 0 } = {}) {
  let clock = 0;
  let refused = refusals;
  const reports = [];
  const errors = [];
  const participant = fakeParticipant({ failures, deviceId });
  const monitor = createCameraMonitor({
    participant, camera: CAMERA, fallbackCapture: FALLBACK_CAPTURE, fallbackOptions: FALLBACK_OPTIONS, now: () => clock,
    log: { error: (...args) => errors.push(args) },
    report: async (sample) => {
      reports.push(sample);
      if (refused === 0) return true;
      refused -= 1;
      return false;
    },
  });
  const events = () => reports.map((report) => report.event);
  // Un relevé toutes les 10 s, comme camera_health.jsx.
  const tick = async () => {
    clock += 10000;
    await monitor.sample();
  };
  return { participant, monitor, reports, errors, events, tick };
}

// Couche basse seule : jugée à partir de 10 s, confirmée au relevé suivant,
// UN repli sans simulcast de la même piste, capture ramenée en 720p entre la
// dépublication et la republication, journalisé avec la mesure qui l'a déclenché.
{
  const { participant, monitor, reports, events, tick } = setup();
  monitor.published("TR_1");
  await monitor.sample();
  await tick();
  assert.deepEqual(events(), ["sample", "sample"]);
  assert.equal(participant.calls.length, 0, "un seul relevé ne suffit pas");

  await tick();
  assert.equal(reports[2].event, FALLBACK);
  assert.equal(reports[2].publication_sid, "TR_1");
  assert.equal(reports[2].top_width, 320);
  assert.deepEqual(participant.calls, [["unpublish", false], RESTART_720, ["publish", FALLBACK_OPTIONS]]);
  assert.equal(participant.publication.trackSid, "TR_re1");

  // La nouvelle publication, même revenue en simulcast avec la couche basse seule,
  // n'est jamais rejugée : un seul repli par entrée dans la salle.
  monitor.published("TR_re1");
  participant.track.encodings = SIMULCAST;
  for (let i = 0; i < 4; i += 1) await tick();
  assert.deepEqual(events().slice(3), ["sample", "sample", "sample", "sample"]);
  assert.equal(participant.calls.length, 3);
}

// Caméra saine à 10 s : jugement clos (KEEP) ; la couche basse seule plus tard
// (liaison instable) ne déclenche plus rien.
{
  const { participant, monitor, events, tick } = setup();
  participant.track.stats = HEALTHY;
  monitor.published("TR_1");
  await tick();
  participant.track.stats = LOW_ONLY;
  for (let i = 0; i < 3; i += 1) await tick();
  assert.deepEqual(events(), ["sample", "sample", "sample", "sample"]);
  assert.equal(participant.calls.length, 0);
}

// Relevés non concluants (dynacast en coulisses : h et f en pause, aucune
// image) : le jugement n'est pas consommé ; la caméra du cas observé est
// republiée une fois les couches demandées.
{
  const { participant, monitor, events, tick } = setup();
  monitor.published("TR_1");
  participant.track.encodings = PAUSED;
  await tick();
  await tick();
  participant.track.encodings = SIMULCAST;
  await tick();
  await tick();
  assert.deepEqual(events(), ["sample", "sample", "sample", FALLBACK]);
}

// Une pause dynacast entre les deux relevés FALL_BACK ne remet pas la suspicion à zéro.
{
  const { participant, monitor, events, tick } = setup();
  monitor.published("TR_1");
  await tick();
  participant.track.encodings = PAUSED;
  await tick();
  participant.track.encodings = SIMULCAST;
  await tick();
  assert.deepEqual(events(), ["sample", "sample", FALLBACK]);
}

// Liaison limitée par le débit après 10 s : c'est le réseau, jugement clos,
// jamais de repli même si la couche basse reste seule ensuite (cas d'une liaison instable).
{
  const { participant, monitor, tick } = setup();
  monitor.published("TR_1");
  participant.track.stats = STARVED;
  await tick();
  participant.track.stats = LOW_ONLY;
  for (let i = 0; i < 4; i += 1) await tick();
  assert.equal(participant.calls.length, 0);
}

// Relevé tombé une fraction de milliseconde avant les 10 s : jugé quand même.
{
  let clock = 0;
  const participant = fakeParticipant();
  const reports = [];
  const monitor = createCameraMonitor({ participant, camera: CAMERA, fallbackCapture: FALLBACK_CAPTURE,
    fallbackOptions: FALLBACK_OPTIONS, now: () => clock,
    log: { error() {} }, report: async (sample) => reports.push(sample) > 0 });
  monitor.published("TR_1");
  clock = 9999.9;
  await monitor.sample();
  clock = 19999.8;
  await monitor.sample();
  assert.deepEqual(reports.map((report) => report.event), ["sample", FALLBACK]);
}

// Republication refusée : publication d'origine rétablie AVEC ses options,
// échec journalisé, pas de second essai.
{
  const { participant, monitor, errors, events, tick } = setup({ failures: ["publish"] });
  monitor.published("TR_1");
  await tick();
  await tick();
  assert.deepEqual(events(), ["sample", FALLBACK_FAILED]);
  assert.deepEqual(participant.calls,
    [["unpublish", false], RESTART_720, ["publish", FALLBACK_OPTIONS], ["publish", ORIGINAL_OPTIONS]]);
  assert.equal(participant.publication.trackSid, "TR_re1");
  assert.equal(errors.length, 1);

  monitor.published("TR_re1");
  await tick();
  await tick();
  assert.deepEqual(events().slice(2), ["sample", "sample"]);
  assert.equal(participant.calls.length, 4);
}

// Capture 720p refusée (« Could not start video source ») : livekit-client a
// déjà arrêté la capture. Elle est rouverte avec ses réglages d'origine AVANT
// de rétablir la publication d'origine : pas d'image noire.
{
  const { participant, monitor, errors, events, tick } = setup({ failures: ["restart"] });
  monitor.published("TR_1");
  await tick();
  await tick();
  assert.deepEqual(events(), ["sample", FALLBACK_FAILED]);
  assert.deepEqual(participant.calls, [["unpublish", false], RESTART_720, REOPEN, ["publish", ORIGINAL_OPTIONS]]);
  assert.equal(participant.track.mediaStreamTrack.readyState, "live", "capture rouverte avant la republication");
  assert.ok(participant.publication, "la caméra est de nouveau publiée");
  assert.equal(errors.length, 1);
}

// Réouverture refusée elle aussi : la piste terminée n'est pas republiée ;
// la caméra reste dépubliée (coupée à l'écran, rallumable), les deux échecs
// journalisés.
{
  const { participant, monitor, errors, events, tick } = setup({ failures: ["restart", "restart"] });
  monitor.published("TR_1");
  await tick();
  await tick();
  assert.deepEqual(events(), ["sample", FALLBACK_FAILED]);
  assert.deepEqual(participant.calls, [["unpublish", false], RESTART_720, REOPEN]);
  assert.equal(participant.publication, undefined, "aucune piste terminée publiée");
  assert.equal(errors.length, 2);
}

// Caméra d'identifiant inconnu : pas de réouverture (elle pourrait prendre une
// autre caméra), republiée sans simulcast à sa capture actuelle.
{
  const { participant, monitor, events, tick } = setup({ deviceId: "" });
  monitor.published("TR_1");
  await tick();
  await tick();
  assert.deepEqual(events(), ["sample", FALLBACK]);
  assert.deepEqual(participant.calls, [["unpublish", false], ["publish", FALLBACK_OPTIONS]]);
}

// Dépublication rejetée après le retrait de la publication (négociation
// refusée) : la caméra est republiée telle qu'avant, l'échec journalisé.
{
  const { participant, monitor, events, tick } = setup({ failures: ["unpublish"] });
  monitor.published("TR_1");
  await tick();
  await tick();
  assert.deepEqual(events(), ["sample", FALLBACK_FAILED]);
  assert.deepEqual(participant.calls, [["unpublish", false], ["publish", ORIGINAL_OPTIONS]]);
  assert.ok(participant.publication, "la caméra est de nouveau publiée");
}

// Rétablissement refusé lui aussi : les deux échecs sont journalisés, rien ne lève.
{
  const { monitor, errors, events, tick } = setup({ failures: ["publish", "publish"] });
  monitor.published("TR_1");
  await tick();
  await tick();
  assert.deepEqual(events(), ["sample", FALLBACK_FAILED]);
  assert.equal(errors.length, 2);
}

// Repli fait en coulisses, mesures refusées hors direct : l'issue est renvoyée
// AVEC la mesure qui l'a déclenché (publication d'origine, 320x180, encodeur
// d'avant le repli) jusqu'à être enregistrée, puis plus jamais.
{
  const { participant, monitor, reports, events, tick } = setup({ refusals: 3 });
  monitor.published("TR_1");
  await tick();
  await tick();
  participant.track.stats = HEALTHY.map((entry) => ({ ...entry, encoderImplementation: "OpenH264" }));
  await tick();
  await tick();
  await tick();
  assert.deepEqual(events(), ["sample", FALLBACK, FALLBACK, FALLBACK, "sample"]);
  for (const report of reports.slice(1, 4)) {
    assert.deepEqual([report.publication_sid, report.top_width, report.top_height, report.encoder_implementation],
      ["TR_1", 320, 180, "ExternalEncoder"]);
  }
  assert.deepEqual([reports[4].publication_sid, reports[4].top_width, reports[4].encoder_implementation], ["TR_re1", 1280, "OpenH264"]);
  assert.equal(participant.calls.length, 3);
}

// Caméra éteinte puis rallumée : le délai et la confirmation repartent du rallumage.
{
  const { participant, monitor, events, tick } = setup();
  monitor.published("TR_1");
  await tick();
  participant.publication.isMuted = true;
  await tick();
  participant.publication.isMuted = false;
  await monitor.sample();
  assert.deepEqual(events(), ["sample", "sample"]);
  await tick();
  assert.deepEqual(events(), ["sample", "sample", "sample"], "premier verdict après le rallumage, à confirmer");
  await tick();
  assert.deepEqual(events().at(-1), FALLBACK);
}

// Caméra coupée ou absente : rien n'est relevé.
{
  const { participant, monitor, reports, tick } = setup();
  participant.publication.isMuted = true;
  await tick();
  participant.publication = undefined;
  await tick();
  assert.equal(reports.length, 0);
}

// Caméra déjà publiée avant le moniteur : le délai court depuis le premier relevé.
{
  const { participant, monitor, events, tick } = setup();
  await monitor.sample();
  await tick();
  await tick();
  assert.deepEqual(events(), ["sample", "sample", FALLBACK]);
  assert.equal(participant.calls.length, 3);
}
