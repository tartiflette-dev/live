"""Cycle de vie des pipelines : des pistes qui vont et viennent.

Régression observée lors d'un essai réel : 11 pipelines démarrés pour 2
participants, 10 encore vivants à la fin du job. Ici : UN pipeline par
identité, remplacé à la reconnexion, libéré à la dépublication et au départ.
"""
from __future__ import annotations

import asyncio
from types import SimpleNamespace

import pytest

import agent
from lifecycle import BoundedSegmentQueue, PipelineRegistry, QueueClosed


class Probe:
    """Pipeline factice : consigne démarrages et libérations par piste."""

    def __init__(self) -> None:
        self.started: list[str] = []
        self.released: list[str] = []
        self.running: set[str] = set()

    def run(self, label: str):
        async def _run() -> None:
            self.started.append(label)
            self.running.add(label)
            try:
                await asyncio.sleep(3600)
            finally:
                self.running.discard(label)
                self.released.append(label)

        return _run


@pytest.fixture(autouse=True)
async def _stop_leaked_pipelines(monkeypatch):
    """Aucun pipeline factice ne survit à son test."""
    created: list[PipelineRegistry] = []
    original_init = PipelineRegistry.__init__

    def tracking_init(self) -> None:
        original_init(self)
        created.append(self)

    monkeypatch.setattr(PipelineRegistry, "__init__", tracking_init)
    yield
    for registry in created:
        await registry.stop_all(timeout=1)


async def _settle() -> None:
    for _ in range(5):
        await asyncio.sleep(0)


# -- PipelineRegistry --------------------------------------------------------


async def test_un_nouveau_pipeline_remplace_l_ancien_de_la_meme_identite():
    registry, probe = PipelineRegistry(), Probe()

    registry.start("speaker-7", track_sid="TR_1", participant_sid="PA_1", run=probe.run("TR_1"))
    await _settle()
    registry.start("speaker-7", track_sid="TR_2", participant_sid="PA_1", run=probe.run("TR_2"))
    await _settle()

    assert probe.running == {"TR_2"}
    assert probe.released == ["TR_1"]
    assert len(registry) == 1


async def test_le_nouveau_pipeline_ne_demarre_qu_apres_la_liberation_de_l_ancien():
    registry, order = PipelineRegistry(), []

    async def old() -> None:
        try:
            await asyncio.sleep(3600)
        finally:
            await asyncio.sleep(0.01)  # fermeture lente du flux audio
            order.append("ancien libéré")

    async def new() -> None:
        order.append("nouveau démarré")
        await asyncio.sleep(3600)

    registry.start("host-1", track_sid="TR_1", participant_sid="PA_1", run=old)
    await _settle()
    registry.start("host-1", track_sid="TR_2", participant_sid="PA_1", run=new)
    await asyncio.sleep(0.1)

    assert order == ["ancien libéré", "nouveau démarré"]
    await registry.stop_all(timeout=1)


async def test_cinq_reconnexions_laissent_un_seul_pipeline_vivant():
    registry, probe = PipelineRegistry(), Probe()

    for n in range(5):
        registry.start("speaker-7", track_sid=f"TR_{n}", participant_sid=f"PA_{n}", run=probe.run(f"TR_{n}"))
        await _settle()

    assert probe.running == {"TR_4"}
    assert len(registry) == 1
    assert sorted(probe.released) == ["TR_0", "TR_1", "TR_2", "TR_3"]


async def test_des_identites_differentes_cohabitent():
    registry, probe = PipelineRegistry(), Probe()

    registry.start("host-1", track_sid="TR_H", participant_sid="PA_H", run=probe.run("TR_H"))
    registry.start("speaker-7", track_sid="TR_S", participant_sid="PA_S", run=probe.run("TR_S"))
    await _settle()

    assert probe.running == {"TR_H", "TR_S"}
    assert sorted(registry.identities()) == ["host-1", "speaker-7"]


async def test_piste_depubliee_arrete_son_pipeline_et_le_registre_se_vide():
    registry, probe = PipelineRegistry(), Probe()
    registry.start("speaker-7", track_sid="TR_1", participant_sid="PA_1", run=probe.run("TR_1"))
    await _settle()

    assert registry.stop_track("speaker-7", "TR_1") is True
    await _settle()

    assert probe.running == set()
    assert len(registry) == 0


async def test_deux_evenements_de_fin_n_annulent_le_pipeline_qu_une_fois():
    """track_unsubscribed ET track_unpublished arrivent pour la même piste :
    une seconde annulation interromprait la fermeture des flux en cours."""
    registry, closed = PipelineRegistry(), []
    started = asyncio.Event()

    async def slow_to_close() -> None:
        started.set()
        try:
            await asyncio.sleep(3600)
        finally:
            await asyncio.sleep(0.05)  # fermeture des flux
            closed.append("flux fermés")

    registry.start("speaker-7", track_sid="TR_1", participant_sid="PA_1", run=slow_to_close)
    await started.wait()

    assert registry.stop_track("speaker-7", "TR_1") is True
    await asyncio.sleep(0.01)
    assert registry.stop_track("speaker-7", "TR_1") is False
    assert registry.stop_participant("speaker-7", "PA_1") is False
    await asyncio.sleep(0.2)

    assert closed == ["flux fermés"]


async def test_la_depublication_d_une_ancienne_piste_ne_coupe_pas_la_nouvelle():
    registry, probe = PipelineRegistry(), Probe()
    registry.start("speaker-7", track_sid="TR_1", participant_sid="PA_1", run=probe.run("TR_1"))
    await _settle()
    registry.start("speaker-7", track_sid="TR_2", participant_sid="PA_1", run=probe.run("TR_2"))
    await _settle()

    assert registry.stop_track("speaker-7", "TR_1") is False
    await _settle()

    assert probe.running == {"TR_2"}


async def test_le_depart_de_l_ancienne_session_ne_coupe_pas_la_session_reconnectee():
    registry, probe = PipelineRegistry(), Probe()
    registry.start("speaker-7", track_sid="TR_1", participant_sid="PA_old", run=probe.run("TR_1"))
    await _settle()
    registry.start("speaker-7", track_sid="TR_2", participant_sid="PA_new", run=probe.run("TR_2"))
    await _settle()

    assert registry.stop_participant("speaker-7", "PA_old") is False
    await _settle()
    assert probe.running == {"TR_2"}

    assert registry.stop_participant("speaker-7", "PA_new") is True
    await _settle()
    assert probe.running == set()
    assert len(registry) == 0


async def test_is_running_reconnait_une_piste_deja_suivie():
    registry, probe = PipelineRegistry(), Probe()
    registry.start("host-1", track_sid="TR_1", participant_sid="PA_1", run=probe.run("TR_1"))
    await _settle()

    assert registry.is_running("host-1", "TR_1") is True
    assert registry.is_running("host-1", "TR_2") is False
    assert registry.is_running("autre", "TR_1") is False


async def test_pipeline_termine_de_lui_meme_est_oublie():
    registry = PipelineRegistry()

    async def short() -> None:
        return None

    task = registry.start("host-1", track_sid="TR_1", participant_sid="PA_1", run=short)
    await task

    assert len(registry) == 0


async def test_un_pipeline_en_erreur_est_oublie_sans_toucher_son_successeur():
    registry, probe = PipelineRegistry(), Probe()

    async def boom() -> None:
        raise RuntimeError("VAD en panne")

    failing = registry.start("host-1", track_sid="TR_1", participant_sid="PA_1", run=boom)
    await asyncio.gather(failing, return_exceptions=True)
    assert len(registry) == 0

    registry.start("host-1", track_sid="TR_2", participant_sid="PA_1", run=probe.run("TR_2"))
    await _settle()
    assert probe.running == {"TR_2"}


async def test_stop_all_annule_tout_et_vide_le_registre():
    registry, probe = PipelineRegistry(), Probe()
    registry.start("host-1", track_sid="TR_H", participant_sid="PA_H", run=probe.run("TR_H"))
    registry.start("speaker-7", track_sid="TR_S", participant_sid="PA_S", run=probe.run("TR_S"))
    await _settle()

    leftover = await registry.stop_all(timeout=1)

    assert leftover == 0
    assert probe.running == set()
    assert len(registry) == 0


async def test_stop_all_signale_les_pipelines_qui_ne_repondent_pas():
    registry = PipelineRegistry()
    started, give_up = asyncio.Event(), asyncio.Event()

    async def stubborn() -> None:
        started.set()
        while not give_up.is_set():
            try:
                await asyncio.sleep(0.01)
            except asyncio.CancelledError:
                continue  # refuse de mourir

    task = registry.start("host-1", track_sid="TR_1", participant_sid="PA_1", run=stubborn)
    await started.wait()

    leftover = await registry.stop_all(timeout=0.05)

    assert leftover == 1
    assert len(registry) == 0
    give_up.set()
    await task


# -- BoundedSegmentQueue -----------------------------------------------------


async def test_file_fifo_dans_la_limite_de_capacite():
    queue: BoundedSegmentQueue[int] = BoundedSegmentQueue(3)

    assert queue.put(1) == [] and queue.put(2) == []

    assert [await queue.get(), await queue.get()] == [1, 2]


async def test_file_pleine_abandonne_le_plus_ancien():
    queue: BoundedSegmentQueue[int] = BoundedSegmentQueue(2)
    queue.put(1)
    queue.put(2)

    dropped = queue.put(3)

    assert dropped == [1]
    assert len(queue) == 2
    assert [await queue.get(), await queue.get()] == [2, 3]


async def test_get_attend_un_element():
    queue: BoundedSegmentQueue[str] = BoundedSegmentQueue(2)
    getter = asyncio.create_task(queue.get())
    await asyncio.sleep(0.01)
    assert not getter.done()

    queue.put("segment")

    assert await asyncio.wait_for(getter, timeout=1) == "segment"


async def test_file_fermee_se_vide_puis_leve_queue_closed():
    queue: BoundedSegmentQueue[int] = BoundedSegmentQueue(2)
    queue.put(1)
    queue.close()

    assert await queue.get() == 1
    with pytest.raises(QueueClosed):
        await queue.get()


async def test_fermeture_reveille_un_get_en_attente():
    queue: BoundedSegmentQueue[int] = BoundedSegmentQueue(2)
    getter = asyncio.create_task(queue.get())
    await asyncio.sleep(0.01)

    queue.close()

    with pytest.raises(QueueClosed):
        await asyncio.wait_for(getter, timeout=1)


def test_capacite_invalide_refusee():
    with pytest.raises(ValueError):
        BoundedSegmentQueue(0)


# -- TranscriptionSession (événements de la salle) -------------------------


def _participant(identity: str, sid: str = "PA_1") -> SimpleNamespace:
    return SimpleNamespace(identity=identity, sid=sid, name=identity)


def _audio_track() -> SimpleNamespace:
    return SimpleNamespace(kind=agent.rtc.TrackKind.KIND_AUDIO)


def _publication(sid: str, source=None) -> SimpleNamespace:
    return SimpleNamespace(sid=sid, source=agent.rtc.TrackSource.SOURCE_MICROPHONE if source is None else source)


def _session(probe: Probe):
    registry = PipelineRegistry()

    def launch(track, publication, participant):
        return probe.run(publication.sid)()

    return registry, agent.TranscriptionSession(registry, launch)


async def test_session_basile_se_reconnecte_quatre_fois():
    """Le scénario du soir : un téléphone instable, une piste par session."""
    probe = Probe()
    registry, session = _session(probe)

    for n in range(1, 5):
        participant = _participant("speaker-7", sid=f"PA_{n}")
        session.on_track_subscribed(_audio_track(), _publication(f"TR_{n}"), participant)
        await _settle()
        # La session précédente part APRÈS l'arrivée de la suivante.
        if n > 1:
            session.on_participant_disconnected(_participant("speaker-7", sid=f"PA_{n - 1}"))
            session.on_track_unpublished(_publication(f"TR_{n - 1}"), participant)
        await _settle()

    assert probe.running == {"TR_4"}
    assert len(registry) == 1
    assert probe.started == ["TR_1", "TR_2", "TR_3", "TR_4"]


async def test_session_depart_du_participant_libere_tout():
    probe = Probe()
    registry, session = _session(probe)
    participant = _participant("host-1")
    session.on_track_subscribed(_audio_track(), _publication("TR_1"), participant)
    await _settle()

    session.on_participant_disconnected(participant)
    await _settle()

    assert probe.running == set()
    assert len(registry) == 0


async def test_session_piste_depubliee_ou_desabonnee_libere_le_pipeline():
    probe = Probe()
    registry, session = _session(probe)
    participant = _participant("host-1")
    track = _audio_track()

    session.on_track_subscribed(track, _publication("TR_1"), participant)
    await _settle()
    session.on_track_unpublished(_publication("TR_1"), participant)
    await _settle()
    assert probe.running == set()

    session.on_track_subscribed(track, _publication("TR_2"), participant)
    await _settle()
    session.on_track_unsubscribed(track, _publication("TR_2"), participant)
    await _settle()
    assert probe.running == set()
    assert len(registry) == 0


async def test_session_evenement_rejoue_pour_la_meme_piste_ne_relance_pas():
    probe = Probe()
    registry, session = _session(probe)
    participant = _participant("host-1")

    session.on_track_subscribed(_audio_track(), _publication("TR_1"), participant)
    await _settle()
    session.on_track_subscribed(_audio_track(), _publication("TR_1"), participant)
    await _settle()

    assert probe.started == ["TR_1"]
    assert probe.released == []


async def test_session_ignore_video_et_identites_non_emettrices():
    probe = Probe()
    registry, session = _session(probe)

    video = SimpleNamespace(kind=agent.rtc.TrackKind.KIND_VIDEO)
    session.on_track_subscribed(video, _publication("TR_V"), _participant("host-1"))
    session.on_track_subscribed(_audio_track(), _publication("TR_E"), _participant("egress-1"))
    await _settle()

    assert probe.started == []
    assert len(registry) == 0


async def test_session_le_son_d_un_ecran_partage_ne_remplace_pas_le_micro():
    probe = Probe()
    registry, session = _session(probe)
    participant = _participant("speaker-7")

    session.on_track_subscribed(_audio_track(), _publication("TR_MIC"), participant)
    await _settle()
    screen_audio = _publication("TR_SCREEN", source=agent.rtc.TrackSource.SOURCE_SCREENSHARE_AUDIO)
    session.on_track_subscribed(_audio_track(), screen_audio, participant)
    await _settle()

    assert probe.running == {"TR_MIC"}
    assert probe.started == ["TR_MIC"]
