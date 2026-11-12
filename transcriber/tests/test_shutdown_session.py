"""Arrêt propre du job transcripteur.

livekit-agents 0.12 n'annule pas l'entrypoint : sans ``shutdown_session``,
les pistes FFI restent ouvertes et le worker tue le process après 60 s
(« process is unresponsive, killing process », 07/10 11:48Z).
"""
from __future__ import annotations

import asyncio

import agent
from lifecycle import PipelineRegistry


class FakeCloser:
    def __init__(self) -> None:
        self.closed = 0

    async def aclose(self) -> None:
        self.closed += 1


async def _lingering_pipeline(registry: PipelineRegistry, identity: str = "speaker-1") -> asyncio.Task:
    started = asyncio.Event()

    async def lingering() -> None:
        started.set()
        await asyncio.sleep(3600)

    task = registry.start(identity, track_sid="pub", participant_sid="PA_1", run=lingering)
    await started.wait()
    return task


async def test_shutdown_annule_les_pipelines_et_ferme_les_clients():
    registry = PipelineRegistry()
    task = await _lingering_pipeline(registry)
    archive, whisper = FakeCloser(), FakeCloser()
    done = asyncio.Event()

    await agent.shutdown_session(
        registry=registry, archive=archive, whisper=whisper, done=done, reason="room disconnected"
    )

    assert task.done()
    assert len(registry) == 0
    assert (archive.closed, whisper.closed) == (1, 1)
    assert done.is_set()


async def test_shutdown_arrete_aussi_les_taches_de_fond():
    registry = PipelineRegistry()
    background = asyncio.create_task(asyncio.sleep(3600))
    done = asyncio.Event()

    await agent.shutdown_session(
        registry=registry, archive=FakeCloser(), done=done, background=(background,)
    )
    await asyncio.sleep(0)

    assert background.cancelled()


async def test_shutdown_idempotent_si_deja_fait():
    registry = PipelineRegistry()
    task = await _lingering_pipeline(registry)
    archive = FakeCloser()
    done = asyncio.Event()
    done.set()

    await agent.shutdown_session(registry=registry, archive=archive, done=done, reason="again")

    assert archive.closed == 0
    assert not task.done()
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)


async def test_shutdown_sans_pipeline_ferme_quand_meme_l_archive():
    archive = FakeCloser()
    done = asyncio.Event()

    await agent.shutdown_session(registry=PipelineRegistry(), archive=archive, done=done, reason="")

    assert archive.closed == 1
    assert done.is_set()


async def test_archive_aclose_est_idempotent():
    cfg = agent.Config(
        livekit_url="ws://example.test",
        livekit_api_key="k",
        livekit_api_secret="s",
        whisper_base_url="http://whisper.test/v1",
        whisper_api_key="sk-x",
        whisper_model="whisper-1",
        whisper_language="fr",
        archive_webhook_url="https://example.test/webhooks/transcripts",
    )
    archive = agent.ArchiveClient(cfg)
    await archive.aclose()
    await archive.aclose()


async def test_shutdown_survit_a_un_aclose_qui_explose():
    class BoomArchive:
        async def aclose(self) -> None:
            raise RuntimeError("httpx down")

    done = asyncio.Event()
    await agent.shutdown_session(
        registry=PipelineRegistry(), archive=BoomArchive(), done=done, reason="boom"
    )
    assert done.is_set()
