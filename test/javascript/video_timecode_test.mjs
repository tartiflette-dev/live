// Instant d'une vidéo côté client (video_timecode.mjs), sous Node. Lancé par
// test/integration/video_timecode_test.rb ; mêmes formes que
// ReplaysHelper#replay_timecode.
import assert from "node:assert/strict";
import { videoTimecode } from "../../app/javascript/rooms/video_timecode.mjs";

assert.equal(videoTimecode(0), "0:00");
assert.equal(videoTimecode(7.9), "0:07");
assert.equal(videoTimecode(245), "4:05");
assert.equal(videoTimecode(3729), "1:02:09");
assert.equal(videoTimecode(-3), "0:00");
assert.equal(videoTimecode(null), "0:00");
assert.equal(videoTimecode(undefined), "0:00");
