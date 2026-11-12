"""Traitement d'un segment de parole : Whisper, filtre du bruit, fraîcheur
live, archive horodatée sur l'AUDIO, et pipeline complet (audio -> VAD -> file
-> Whisper) sur des fakes."""
from __future__ import annotations

import asyncio
from types import SimpleNamespace

import pytest

import agent
from agent import Segment
from lifecycle import BoundedSegmentQueue
from whisper_client import WhisperError

AUDIO_END = 1_800_000_000.0  # horloge audio fixe des tests


def _frame(seconds: float):
    samples = int(16000 * seconds)
    return agent.rtc.AudioFrame.create(16000, 1, samples)


def _segment(duration: float = 2.0, end: float = AUDIO_END) -> Segment:
    return Segment(frames=[_frame(duration)], audio_start=end - duration, audio_end=end)


class FakeWhisper:
    def __init__(self, texts=None, error: Exception | None = None) -> None:
        self.texts = list(texts or ["Bonjour tout le monde."])
        self.error = error
        self.calls = 0

    async def transcribe(self, wav: bytes) -> str:
        self.calls += 1
        if self.error:
            raise self.error
        assert wav[:4] == b"RIFF", "WAV envoyé à Whisper"
        return self.texts.pop(0) if len(self.texts) > 1 else self.texts[0]


class FakeArchive:
    def __init__(self) -> None:
        self.payloads: list[dict] = []

    async def send(self, payload: dict) -> None:
        self.payloads.append(payload)


@pytest.fixture
def live(monkeypatch):
    published: list[dict] = []

    async def _publish(room, **kwargs):
        published.append(kwargs)

    monkeypatch.setattr(agent, "publish_segment_live", _publish)
    return published


def _config(**overrides) -> agent.Config:
    base = dict(
        livekit_url="ws://x", livekit_api_key="k", livekit_api_secret="s",
        whisper_base_url="http://w/v1", whisper_api_key="k", whisper_model="m",
        whisper_language="fr", archive_webhook_url="http://a",
    )
    return agent.Config(**{**base, **overrides})


def _deps(whisper, archive, **config_overrides) -> agent.PipelineDeps:
    return agent.PipelineDeps(
        config=_config(**config_overrides),
        vad=None,
        whisper=whisper,
        archive=archive,
        whisper_slots=asyncio.Semaphore(2),
    )


CTX = SimpleNamespace(room=SimpleNamespace(name="test-29-10"))
BASILE = SimpleNamespace(identity="speaker-7", name="Basile")


async def test_segment_frais_diffuse_et_archive_avec_les_horodatages_audio(live):
    archive = FakeArchive()
    deps = _deps(FakeWhisper(), archive)

    await agent.process_segment(CTX, BASILE, _segment(2.0), deps, now=lambda: AUDIO_END + 1.5)

    assert [p["text"] for p in live] == ["Bonjour tout le monde."]
    assert live[0]["identity"] == "speaker-7" and live[0]["final"] is True
    # Heure murale de la parole (epoch ms) pour que le panneau juge la fraîcheur.
    assert live[0]["start_ms"] == int((AUDIO_END - 2.0) * 1000)
    assert live[0]["end_ms"] == int(AUDIO_END * 1000)
    [payload] = archive.payloads
    assert payload["segment_id"] == live[0]["segment_id"]
    assert payload["text"] == "Bonjour tout le monde."
    assert payload["room"] == "test-29-10"
    assert payload["participant"] == {"identity": "speaker-7", "name": "Basile"}
    # Les horodatages sont ceux de l'AUDIO, pas de l'instant de publication.
    assert payload["started_at"] == agent._iso(AUDIO_END - 2.0)
    assert payload["ended_at"] == agent._iso(AUDIO_END)
    assert deps.stats.published == 1


async def test_segment_trop_vieux_est_archive_mais_plus_diffuse(live):
    archive = FakeArchive()
    deps = _deps(FakeWhisper(["Il y a longtemps."]), archive, live_max_age=15.0)

    await agent.process_segment(CTX, BASILE, _segment(), deps, now=lambda: AUDIO_END + 90)

    assert live == []
    [payload] = archive.payloads
    assert payload["text"] == "Il y a longtemps."
    assert payload["ended_at"] == agent._iso(AUDIO_END), "l'archive garde l'heure réelle de la parole"
    assert deps.stats.archived_only_stale == 1
    assert deps.stats.lag_s_max == pytest.approx(90)


async def test_segment_a_la_limite_d_age_est_encore_diffuse(live):
    deps = _deps(FakeWhisper(), FakeArchive(), live_max_age=15.0)

    await agent.process_segment(CTX, BASILE, _segment(), deps, now=lambda: AUDIO_END + 15.0)

    assert len(live) == 1


async def test_hallucination_connue_ni_diffusee_ni_archivee(live):
    archive = FakeArchive()
    deps = _deps(FakeWhisper(["Sous-titrage Société Radio-Canada"]), archive)

    await agent.process_segment(CTX, BASILE, _segment(), deps, now=lambda: AUDIO_END)

    assert live == [] and archive.payloads == []
    assert deps.stats.filtered_noise == 1


async def test_hesitation_de_tete_retiree_avant_diffusion(live):
    archive = FakeArchive()
    deps = _deps(FakeWhisper(["Euh, donc on commence"]), archive)

    await agent.process_segment(CTX, BASILE, _segment(), deps, now=lambda: AUDIO_END)

    assert live[0]["text"] == "Donc on commence"
    assert archive.payloads[0]["text"] == "Donc on commence"


async def test_segment_trop_court_n_appelle_pas_whisper(live):
    whisper = FakeWhisper()
    deps = _deps(whisper, FakeArchive(), min_segment_seconds=0.4)

    await agent.process_segment(CTX, BASILE, _segment(0.2), deps, now=lambda: AUDIO_END)

    assert whisper.calls == 0 and live == []
    assert deps.stats.too_short == 1


async def test_erreur_whisper_perd_le_segment_sans_lever(live):
    archive = FakeArchive()
    deps = _deps(FakeWhisper(error=WhisperError("HTTP 502")), archive)

    await agent.process_segment(CTX, BASILE, _segment(), deps, now=lambda: AUDIO_END)

    assert live == [] and archive.payloads == []
    assert deps.stats.whisper_errors == 1


async def test_le_plafond_de_concurrence_whisper_est_respecte(live):
    in_flight = {"now": 0, "max": 0}

    class SlowWhisper:
        async def transcribe(self, wav: bytes) -> str:
            in_flight["now"] += 1
            in_flight["max"] = max(in_flight["max"], in_flight["now"])
            await asyncio.sleep(0.02)
            in_flight["now"] -= 1
            return "Bonjour."

    deps = agent.PipelineDeps(
        config=_config(), vad=None, whisper=SlowWhisper(), archive=FakeArchive(),
        whisper_slots=asyncio.Semaphore(2),
    )

    await asyncio.gather(*[
        agent.process_segment(CTX, BASILE, _segment(), deps, now=lambda: AUDIO_END)
        for _ in range(6)
    ])

    assert in_flight["max"] == 2


# -- Pipeline complet : audio -> VAD -> file bornée -> Whisper ---------------


class ScriptedAudioStream:
    """Livre N trames puis se termine (fin de piste)."""

    def __init__(self, track, **kwargs) -> None:
        self._frames = [SimpleNamespace(frame=_frame(0.01)) for _ in range(3)]
        self.closed = False

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self._frames:
            raise StopAsyncIteration
        await asyncio.sleep(0)
        return self._frames.pop(0)

    async def aclose(self) -> None:
        self.closed = True


class ScriptedVadStream:
    """Émet des fins de parole à des instants audio donnés, après la fin de l'entrée."""

    def __init__(self, end_times: list[float]) -> None:
        self._end_times = end_times
        self._input_ended = asyncio.Event()
        self.closed = False

    def push_frame(self, frame) -> None:
        pass

    def end_input(self) -> None:
        self._input_ended.set()

    def __aiter__(self):
        return self._events()

    async def _events(self):
        await self._input_ended.wait()
        for end in self._end_times:
            yield SimpleNamespace(
                type=agent.agents_vad.VADEventType.END_OF_SPEECH,
                timestamp=end,
                frames=[_frame(2.0)],
            )
        yield SimpleNamespace(type=agent.agents_vad.VADEventType.INFERENCE_DONE, timestamp=0, frames=[])

    async def aclose(self) -> None:
        self.closed = True


async def test_pipeline_complet_horodate_sur_l_audio_et_se_termine_proprement(monkeypatch, live):
    monkeypatch.setattr(agent.rtc, "AudioStream", ScriptedAudioStream)
    monkeypatch.setattr(agent.time, "time", lambda: 1_000.0)  # origine audio = première trame
    vad_stream = ScriptedVadStream(end_times=[3.0, 8.0])
    archive = FakeArchive()
    deps = agent.PipelineDeps(
        config=_config(live_max_age=15.0),
        vad=SimpleNamespace(stream=lambda: vad_stream),
        whisper=FakeWhisper(["Premier segment.", "Deuxième segment."]),
        archive=archive,
        whisper_slots=asyncio.Semaphore(1),
    )

    await agent.transcribe_track(CTX, object(), BASILE, deps)

    assert [p["text"] for p in archive.payloads] == ["Premier segment.", "Deuxième segment."]
    assert archive.payloads[0]["ended_at"] == agent._iso(1_003.0)
    assert archive.payloads[0]["started_at"] == agent._iso(1_001.0)
    assert archive.payloads[1]["ended_at"] == agent._iso(1_008.0)
    assert vad_stream.closed


async def test_pipeline_file_pleine_abandonne_le_plus_ancien_et_garde_le_recent(monkeypatch, live):
    """Whisper bloqué : la file reste bornée et c'est le plus RÉCENT qui passe."""
    monkeypatch.setattr(agent.rtc, "AudioStream", ScriptedAudioStream)
    monkeypatch.setattr(agent.time, "time", lambda: 1_000.0)
    release = asyncio.Event()

    class GatedWhisper:
        def __init__(self) -> None:
            self.n = 0

        async def transcribe(self, wav: bytes) -> str:
            self.n += 1
            await release.wait()
            return f"segment {self.n}"

    # 6 fins de parole d'un coup, file de 2 : les 4 plus anciennes sont
    # abandonnées, les 2 plus récentes sont transcrites.
    vad_stream = ScriptedVadStream(end_times=[3.0, 6.0, 9.0, 12.0, 15.0, 18.0])
    archive = FakeArchive()
    deps = agent.PipelineDeps(
        config=_config(segment_queue_max=2, live_max_age=1000.0),
        vad=SimpleNamespace(stream=lambda: vad_stream),
        whisper=GatedWhisper(),
        archive=archive,
        whisper_slots=asyncio.Semaphore(1),
    )

    task = asyncio.create_task(agent.transcribe_track(CTX, object(), BASILE, deps))
    await asyncio.sleep(0.05)
    release.set()
    await asyncio.wait_for(task, timeout=2)

    assert deps.stats.dropped_overflow == 4
    assert [p["ended_at"] for p in archive.payloads] == [agent._iso(1_015.0), agent._iso(1_018.0)]


async def test_bounded_queue_est_celle_du_pipeline():
    assert BoundedSegmentQueue(1).put("a") == []


async def test_heartbeat_journalise_pipelines_memoire_et_alerte_au_dessus_du_seuil(caplog):
    from lifecycle import PipelineRegistry

    registry = PipelineRegistry()
    stats = agent.JobStats(published=3)
    ticks = {"n": 0}

    async def sleep(_seconds):
        ticks["n"] += 1
        if ticks["n"] > 1:
            raise asyncio.CancelledError

    with caplog.at_level("INFO", logger="transcriber"):
        with pytest.raises(asyncio.CancelledError):
            await agent.heartbeat(
                registry=registry, stats=stats, config=_config(memory_warn_mb=700.0),
                room_name="test-29-10", read_rss=lambda: 2269.0, sleep=sleep,
            )

    messages = [r.getMessage() for r in caplog.records]
    assert any("stats room=test-29-10 pipelines=0" in m and "rss_mb=2269" in m for m in messages)
    assert any("au-dessus du seuil 700" in m for m in messages)


async def test_attributs_du_flux_texte_portent_l_heure_murale_de_la_parole():
    sent = {}

    class FakeLocal:
        async def send_text(self, *, text, topic, attributes):
            sent.update(text=text, topic=topic, attributes=attributes)

    room = SimpleNamespace(local_participant=FakeLocal())

    await agent.publish_segment_live(
        room, segment_id="s1", identity="speaker-7", display_name="Basile",
        text="Bonjour.", final=True, start_ms=1_800_000_000_000, end_ms=1_800_000_002_000,
    )

    assert sent["topic"] == "lk.transcription"
    assert sent["attributes"] == {
        "lk.segment_id": "s1",
        "lk.transcription_final": "true",
        "lk.participant_identity": "speaker-7",
        "lk.participant_name": "Basile",
        "lk.segment_start_ms": "1800000000000",
        "lk.segment_end_ms": "1800000002000",
    }
