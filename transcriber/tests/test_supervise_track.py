"""Tests de ``supervise_track``.

But : prouver qu'une piste reprend après une exception STT, qu'elle
abandonne proprement après ``max_attempts`` échecs, et qu'elle ne
retente pas si la piste est dépubliée ou la room fermée. Pas de LiveKit
réel : fakes légers (`FakeRoom`, `FakeParticipant`, `FakePublication`).
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from types import SimpleNamespace
from typing import Any, Callable, Dict

import pytest

import agent


# ------------- Fakes --------------------------------------------------


class _FakeConnState:
    CONN_CONNECTED = "connected"
    CONN_DISCONNECTED = "disconnected"


@dataclass
class FakePublication:
    sid: str = "pub-1"


@dataclass
class FakeParticipant:
    identity: str = "speaker-1"
    name: str = "Speaker One"
    track_publications: Dict[str, FakePublication] = field(default_factory=dict)


@dataclass
class FakeRoom:
    name: str = "e2e"
    connection_state: str = _FakeConnState.CONN_CONNECTED
    remote_participants: Dict[str, FakeParticipant] = field(default_factory=dict)


@dataclass
class FakeCtx:
    room: FakeRoom


def _make_ctx(publication: FakePublication, participant: FakeParticipant) -> FakeCtx:
    participant.track_publications[publication.sid] = publication
    room = FakeRoom(remote_participants={participant.identity: participant})
    return FakeCtx(room=room)


@pytest.fixture(autouse=True)
def _patch_rtc(monkeypatch):
    """Détourne ``agent.rtc.ConnectionState`` vers le fake, pour que
    ``_track_alive`` sache reconnaître ``CONN_DISCONNECTED``."""
    monkeypatch.setattr(agent.rtc, "ConnectionState", _FakeConnState, raising=False)
    yield


class RecordingSleep:
    """``asyncio.sleep`` factice qui enregistre les delays sans attendre."""

    def __init__(self) -> None:
        self.delays: list[float] = []
        self.hooks: list[Callable[[], Any]] = []

    async def __call__(self, delay: float) -> None:
        self.delays.append(delay)
        for hook in self.hooks:
            hook()


# ------------- Transcribe fakes ---------------------------------------


def _flaky_transcribe(failures: int, exc: Exception):
    """Fabrique un ``transcribe`` qui lève ``failures`` fois puis réussit.

    Les appels sont comptés pour que les tests puissent vérifier le
    nombre exact d'invocations.
    """
    calls = {"n": 0}

    async def _impl(ctx, track, participant, deps):
        calls["n"] += 1
        if calls["n"] <= failures:
            raise exc
        # Succès : équivaut à audio_stream terminé proprement.
        return None

    _impl.calls = calls
    return _impl


def _always_fails_transcribe(exc: Exception):
    calls = {"n": 0}

    async def _impl(ctx, track, participant, deps):
        calls["n"] += 1
        raise exc

    _impl.calls = calls
    return _impl


# ------------- Tests --------------------------------------------------


async def test_succes_premier_essai_pas_de_retry():
    publication = FakePublication()
    participant = FakeParticipant()
    ctx = _make_ctx(publication, participant)
    sleep = RecordingSleep()

    transcribe = _flaky_transcribe(failures=0, exc=RuntimeError("unused"))

    await agent.supervise_track(
        ctx, SimpleNamespace(), publication, participant,
        deps=None,
        _transcribe=transcribe, _sleep=sleep,
    )

    assert transcribe.calls["n"] == 1
    assert sleep.delays == []


async def test_reprise_apres_un_echec_puis_succes():
    publication = FakePublication()
    participant = FakeParticipant()
    ctx = _make_ctx(publication, participant)
    sleep = RecordingSleep()

    transcribe = _flaky_transcribe(failures=1, exc=RuntimeError("Whisper injoignable"))

    await agent.supervise_track(
        ctx, SimpleNamespace(), publication, participant,
        deps=None,
        _transcribe=transcribe, _sleep=sleep,
    )

    assert transcribe.calls["n"] == 2
    assert sleep.delays == [agent.RETRY_BASE_DELAY]


async def test_backoff_exponentiel_plafonne():
    publication = FakePublication()
    participant = FakeParticipant()
    ctx = _make_ctx(publication, participant)
    sleep = RecordingSleep()

    # Base 2 s, plafond 5 s, 6 tentatives → delays 2, 4, 5, 5, 5 (5 pauses
    # avant la 6e tentative, qui réussit).
    transcribe = _flaky_transcribe(failures=5, exc=RuntimeError("boum"))

    await agent.supervise_track(
        ctx, SimpleNamespace(), publication, participant,
        deps=None,
        max_attempts=6, base_delay=2.0, max_delay=5.0,
        _transcribe=transcribe, _sleep=sleep,
    )

    assert transcribe.calls["n"] == 6
    assert sleep.delays == [2.0, 4.0, 5.0, 5.0, 5.0]


async def test_abandon_apres_max_attempts():
    publication = FakePublication()
    participant = FakeParticipant()
    ctx = _make_ctx(publication, participant)
    sleep = RecordingSleep()

    transcribe = _always_fails_transcribe(RuntimeError("Whisper HS définitif"))

    await agent.supervise_track(
        ctx, SimpleNamespace(), publication, participant,
        deps=None,
        max_attempts=3, base_delay=1.0, max_delay=10.0,
        _transcribe=transcribe, _sleep=sleep,
    )

    # 3 tentatives, 2 pauses entre elles.
    assert transcribe.calls["n"] == 3
    assert sleep.delays == [1.0, 2.0]


async def test_pas_de_retry_si_piste_depubliee_avant_premier_essai():
    publication = FakePublication()
    participant = FakeParticipant()
    ctx = _make_ctx(publication, participant)
    # Piste absente des publications dès le départ.
    participant.track_publications.clear()
    sleep = RecordingSleep()

    transcribe = _always_fails_transcribe(RuntimeError("ne doit jamais être appelé"))

    await agent.supervise_track(
        ctx, SimpleNamespace(), publication, participant,
        deps=None,
        _transcribe=transcribe, _sleep=sleep,
    )

    assert transcribe.calls["n"] == 0
    assert sleep.delays == []


async def test_pas_de_retry_si_room_fermee_pendant_backoff():
    publication = FakePublication()
    participant = FakeParticipant()
    ctx = _make_ctx(publication, participant)
    sleep = RecordingSleep()

    def _close_room() -> None:
        ctx.room.connection_state = _FakeConnState.CONN_DISCONNECTED
    sleep.hooks.append(_close_room)

    transcribe = _always_fails_transcribe(RuntimeError("STT down"))

    await agent.supervise_track(
        ctx, SimpleNamespace(), publication, participant,
        deps=None,
        max_attempts=5, base_delay=1.0, max_delay=1.0,
        _transcribe=transcribe, _sleep=sleep,
    )

    # Une tentative, un sleep pendant lequel la room ferme, puis arrêt.
    assert transcribe.calls["n"] == 1
    assert sleep.delays == [1.0]


async def test_pas_de_retry_si_piste_depubliee_pendant_backoff():
    publication = FakePublication()
    participant = FakeParticipant()
    ctx = _make_ctx(publication, participant)
    sleep = RecordingSleep()

    def _unpublish() -> None:
        participant.track_publications.clear()
    sleep.hooks.append(_unpublish)

    transcribe = _always_fails_transcribe(RuntimeError("STT down"))

    await agent.supervise_track(
        ctx, SimpleNamespace(), publication, participant,
        deps=None,
        max_attempts=5, base_delay=1.0, max_delay=1.0,
        _transcribe=transcribe, _sleep=sleep,
    )

    assert transcribe.calls["n"] == 1
    assert sleep.delays == [1.0]


async def test_cancellederror_remonte_sans_retry():
    publication = FakePublication()
    participant = FakeParticipant()
    ctx = _make_ctx(publication, participant)
    sleep = RecordingSleep()

    async def _cancelled(ctx, track, participant, deps):
        raise asyncio.CancelledError()

    with pytest.raises(asyncio.CancelledError):
        await agent.supervise_track(
            ctx, SimpleNamespace(), publication, participant,
            deps=None,
            _transcribe=_cancelled, _sleep=sleep,
        )
    assert sleep.delays == []


async def test_track_alive_detecte_participant_parti():
    publication = FakePublication()
    participant = FakeParticipant()
    ctx = _make_ctx(publication, participant)

    assert agent._track_alive(ctx, publication, participant) is True

    # Participant retiré de la room (ex. disconnected event).
    ctx.room.remote_participants.clear()
    assert agent._track_alive(ctx, publication, participant) is False
