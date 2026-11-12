"""Cycle de vie des pipelines de transcription (une par identité active).

Cas réel : chaque reconnexion d'un participant
ajoutait un pipeline sans jamais retirer l'ancien (11 démarrés, 10 encore
vivants à la fin du job pour 2 participants). Les anciens pipelines
continuaient à consommer Whisper et à republier les mêmes phrases en
retard, la file VAD/STT grossissait (2,2 Go).

``PipelineRegistry`` garantit UN pipeline par identité : un nouveau
démarrage remplace l'ancien (annulé et attendu AVANT que le nouveau ne
lise quoi que ce soit), et un événement de fin (piste dépubliée, participant
parti) n'arrête que ce qu'il désigne.

``BoundedSegmentQueue`` borne la mémoire quand Whisper est plus lent que la
parole : au-delà de la capacité, le segment le plus ancien est abandonné.
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
from collections import deque
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Generic, TypeVar

LOGGER = logging.getLogger("transcriber.lifecycle")

T = TypeVar("T")


@dataclass
class _Entry:
    track_sid: str
    participant_sid: str
    task: asyncio.Task

    @property
    def alive(self) -> bool:
        """Vivant ET pas déjà en cours d'annulation."""
        return not self.task.done() and not self.task.cancelling()

    def cancel(self) -> bool:
        """Annule une seule fois : une seconde annulation interromprait le
        ``finally`` du pipeline en pleine fermeture des flux (tâches VAD
        orphelines, observé en staging)."""
        if not self.alive:
            return False
        self.task.cancel()
        return True


class PipelineRegistry:
    def __init__(self) -> None:
        self._entries: dict[str, _Entry] = {}

    def __len__(self) -> int:
        return len(self._entries)

    def identities(self) -> list[str]:
        return list(self._entries)

    def start(
        self,
        identity: str,
        *,
        track_sid: str,
        participant_sid: str,
        run: Callable[[], Awaitable[Any]],
    ) -> asyncio.Task:
        """Lance ``run`` pour ``identity``, en remplaçant le pipeline actif.

        L'ancien est annulé ; ``run`` ne démarre qu'une fois l'ancien
        terminé, donc ses ressources (flux audio, VAD) sont libérées.
        """
        previous = self._entries.get(identity)
        previous_task = previous.task if previous else None
        if previous is not None:
            previous.cancel()
            LOGGER.info(
                "pipeline %s remplacé (piste %s -> %s)",
                identity, previous.track_sid, track_sid,
            )

        async def _run_after_previous() -> Any:
            if previous_task is not None:
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await previous_task
            return await run()

        task = asyncio.create_task(_run_after_previous(), name=f"stt-{identity}-{track_sid}")
        self._entries[identity] = _Entry(track_sid, participant_sid, task)
        task.add_done_callback(lambda done, who=identity: self._forget(who, done))
        return task

    def _forget(self, identity: str, done: asyncio.Task) -> None:
        entry = self._entries.get(identity)
        if entry is not None and entry.task is done:
            del self._entries[identity]

    def is_running(self, identity: str, track_sid: str) -> bool:
        """Vrai si un pipeline vivant lit déjà cette piste (événement rejoué)."""
        entry = self._entries.get(identity)
        return entry is not None and entry.track_sid == track_sid and entry.alive

    def stop_track(self, identity: str, track_sid: str) -> bool:
        """Piste dépubliée : n'arrête que le pipeline qui lit CETTE piste."""
        entry = self._entries.get(identity)
        if entry is None or entry.track_sid != track_sid:
            return False
        return entry.cancel()

    def stop_participant(self, identity: str, participant_sid: str) -> bool:
        """Participant parti : n'arrête que la session désignée.

        Une reconnexion (même identité, nouvelle session) livre souvent le
        départ de l'ancienne session APRÈS l'arrivée de la nouvelle : le sid
        de session évite de couper le pipeline neuf.
        """
        entry = self._entries.get(identity)
        if entry is None or entry.participant_sid != participant_sid:
            return False
        return entry.cancel()

    async def stop_all(self, timeout: float) -> int:
        """Annule tout et attend jusqu'à ``timeout`` s. Retourne le nombre
        de pipelines qui n'ont pas répondu à temps."""
        pending = [entry.task for entry in self._entries.values() if not entry.task.done()]
        for entry in self._entries.values():
            entry.cancel()
        leftover = 0
        if pending:
            # ``wait`` n'annule rien au délai : ``wait_for(gather(...))``
            # attendrait indéfiniment un pipeline qui ignore l'annulation.
            _, still_running = await asyncio.wait(pending, timeout=timeout)
            leftover = len(still_running)
        self._entries.clear()
        return leftover


class BoundedSegmentQueue(Generic[T]):
    """File FIFO bornée, producteur non bloquant, abandon du plus ancien."""

    def __init__(self, capacity: int) -> None:
        if capacity < 1:
            raise ValueError("capacity must be >= 1")
        self._capacity = capacity
        self._items: deque[T] = deque()
        self._closed = False
        self._wakeup = asyncio.Event()

    def __len__(self) -> int:
        return len(self._items)

    def put(self, item: T) -> list[T]:
        """Ajoute ``item`` ; retourne les éléments abandonnés pour lui faire place."""
        dropped: list[T] = []
        while len(self._items) >= self._capacity:
            dropped.append(self._items.popleft())
        self._items.append(item)
        self._wakeup.set()
        return dropped

    def close(self) -> None:
        """Plus de producteur : ``get`` vide la file puis lève ``QueueClosed``."""
        self._closed = True
        self._wakeup.set()

    async def get(self) -> T:
        while not self._items:
            if self._closed:
                raise QueueClosed
            self._wakeup.clear()
            await self._wakeup.wait()
        return self._items.popleft()


class QueueClosed(Exception):
    """File fermée et vide."""
