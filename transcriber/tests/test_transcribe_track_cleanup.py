"""Non-régression : quand le pipeline plante ou est annulé,
``transcribe_track`` ferme le flux audio ET le flux VAD avant de propager —
sinon chaque reprise laisserait un abonnement natif ouvert."""
from __future__ import annotations

import asyncio
from types import SimpleNamespace

import pytest

import agent


class _FakeAudioStream:
    def __init__(self, track, **kwargs):
        self.kwargs = kwargs
        self.closed = False

    def __aiter__(self):
        return self

    async def __anext__(self):
        await asyncio.sleep(3600)  # piste silencieuse : jamais de trame

    async def aclose(self):
        self.closed = True


class _ExplodingVadStream:
    def __init__(self):
        self.closed = False

    def __aiter__(self):
        return self

    async def __anext__(self):
        raise RuntimeError("VAD en panne")

    def push_frame(self, frame):
        pass

    def end_input(self):
        pass

    async def aclose(self):
        self.closed = True


class _IdleVadStream(_ExplodingVadStream):
    async def __anext__(self):
        await asyncio.sleep(3600)


def _deps(vad_stream):
    return agent.PipelineDeps(
        config=agent.Config(
            livekit_url="ws://x", livekit_api_key="k", livekit_api_secret="s",
            whisper_base_url="http://w/v1", whisper_api_key="k", whisper_model="m",
            whisper_language="fr", archive_webhook_url="http://a",
        ),
        vad=SimpleNamespace(stream=lambda: vad_stream),
        whisper=None,
        archive=None,
        whisper_slots=asyncio.Semaphore(1),
    )


@pytest.fixture
def audio_streams(monkeypatch):
    streams = []
    monkeypatch.setattr(
        agent.rtc, "AudioStream",
        lambda track, **kw: streams.append(_FakeAudioStream(track, **kw)) or streams[-1],
    )
    return streams


PARTICIPANT = SimpleNamespace(identity="speaker-1", name="Pauline")
CTX = SimpleNamespace(room=SimpleNamespace(name="room"))


async def test_transcribe_track_ferme_tout_en_cas_d_erreur(audio_streams):
    vad_stream = _ExplodingVadStream()

    with pytest.raises(RuntimeError, match="VAD en panne"):
        await agent.transcribe_track(CTX, object(), PARTICIPANT, _deps(vad_stream))

    assert audio_streams and audio_streams[0].closed, "flux audio fermé"
    assert vad_stream.closed, "flux VAD fermé"


async def test_transcribe_track_annule_ferme_tout_et_laisse_aucune_tache(audio_streams):
    vad_stream = _IdleVadStream()
    before = set(asyncio.all_tasks())

    task = asyncio.create_task(agent.transcribe_track(CTX, object(), PARTICIPANT, _deps(vad_stream)))
    await asyncio.sleep(0.05)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    assert audio_streams[0].closed and vad_stream.closed
    leftovers = [
        t for t in asyncio.all_tasks() - before - {asyncio.current_task()} if not t.done()
    ]
    assert leftovers == [], "aucune tâche audio/VAD/Whisper ne survit à l'annulation"


async def test_flux_audio_demande_en_16khz_mono_borne(audio_streams):
    with pytest.raises(RuntimeError):
        await agent.transcribe_track(CTX, object(), PARTICIPANT, _deps(_ExplodingVadStream()))

    assert audio_streams[0].kwargs == {"sample_rate": 16000, "num_channels": 1, "capacity": 3000}


async def test_une_seconde_annulation_n_interrompt_pas_la_fermeture_des_flux(monkeypatch):
    """Régression staging : deux événements de fin annulaient deux fois le
    pipeline ; la seconde coupait ``aclose`` et laissait les tâches du VAD
    orphelines (« Task was destroyed but it is pending »)."""

    class _SlowAudioStream(_FakeAudioStream):
        async def aclose(self):
            await asyncio.sleep(0.05)
            self.closed = True

    class _SlowVadStream(_IdleVadStream):
        async def aclose(self):
            await asyncio.sleep(0.05)
            self.closed = True

    streams = []
    monkeypatch.setattr(
        agent.rtc, "AudioStream",
        lambda track, **kw: streams.append(_SlowAudioStream(track, **kw)) or streams[-1],
    )
    vad_stream = _SlowVadStream()
    task = asyncio.create_task(agent.transcribe_track(CTX, object(), PARTICIPANT, _deps(vad_stream)))
    await asyncio.sleep(0.05)

    task.cancel()
    await asyncio.sleep(0.01)  # le pipeline est dans son finally
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    await asyncio.sleep(0.2)

    assert streams[0].closed and vad_stream.closed
