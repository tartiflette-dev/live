"""Transcriber LiveKit : Whisper (auto-hébergé, API compatible OpenAI) + VAD
silero + archive signée vers l'app Rails.

Architecture
------------
Le worker (livekit-agents 0.12) est NOMMÉ (``AGENT_NAME``) : LiveKit ne
l'envoie dans une room que sur dispatch explicite de l'app
(``TranscriberPresence``), à l'ouverture et à la reprise du direct, puis à
chaque vérification tant qu'il manque. Dans la room :

1. On s'abonne aux pistes audio des participants qui peuvent publier
   (host-*, speaker-*, viewer-* à qui l'animateur a donné la parole).
2. UN pipeline par identité active (``lifecycle.PipelineRegistry``) :
   AudioStream 16 kHz -> VAD silero -> file bornée de segments -> Whisper
   NON streaming (serveur Whisper, voie ``priority=realtime``). Une
   reconnexion remplace le pipeline de l'identité ; piste dépubliée ou
   participant parti = pipeline annulé et libéré.
3. Chaque segment final est horodaté sur l'AUDIO (début/fin de parole),
   filtré du bruit Whisper connu (``noise.py``), puis doublé :
   - LIVE : text stream LiveKit topic ``lk.transcription`` (attributs
     reconnus par ``useTranscriptions`` : `lk.segment_id`,
     `lk.transcription_final`, + `lk.participant_identity` / `_name`
     + `lk.segment_start_ms` / `lk.segment_end_ms` : heure MURALE de la
     parole, epoch ms).
     Un segment dont l'audio a plus de ``LIVE_MAX_AGE_SECONDS`` n'est PLUS
     diffusé (il paraîtrait hors contexte, mêlé aux récents) ;
   - ARCHIVE : POST signé (JWT HS256 iss=api_key, claim sha256 = base64
     SHA-256 du corps brut) sur ``$ARCHIVE_WEBHOOK_URL``. Un échec de POST
     n'interrompt JAMAIS le live.
4. Fin du direct : l'app supprime le dispatch et retire l'agent de la salle ;
   l'agent voit la salle se déconnecter et arrête tout (``shutdown_session``).
   Une reprise du direct dispatche un nouvel agent.

Variables d'environnement
-------------------------
Obligatoires :
LIVEKIT_URL              wss://live.example.org
LIVEKIT_API_KEY          clé LiveKit (identité de l'agent + iss du JWT archive)
LIVEKIT_API_SECRET       secret LiveKit (jwt signing)
WHISPER_BASE_URL         http://whisper.internal.example:2023/v1
ARCHIVE_WEBHOOK_URL      https://live.example.org/webhooks/transcripts
Facultatives (valeur par défaut entre parenthèses) :
WHISPER_API_KEY          (sentinelle, pour un serveur Whisper qui n'exige pas de clé)
WHISPER_MODEL            (whisper-1)
WHISPER_LANGUAGE         (fr)
WHISPER_PRIORITY         (realtime)  voie prioritaire, si le serveur Whisper en propose une
WHISPER_SOURCE           (live)      étiquette de l'appelant pour le serveur Whisper
WHISPER_TIMEOUT_SECONDS  (20)
WHISPER_MAX_CONCURRENCY  (4)        appels Whisper simultanés pour tout le job
LIVE_MAX_AGE_SECONDS     (15)       âge audio au-delà duquel un segment n'est plus diffusé
SEGMENT_QUEUE_MAX        (12)       segments en attente par pipeline avant abandon du plus ancien
MIN_SEGMENT_SECONDS      (0.4)      segments plus courts : ignorés (hallucinations)
VAD_MIN_SILENCE_SECONDS  (0.5)  VAD_MIN_SPEECH_SECONDS (0.2)  VAD_MAX_SPEECH_SECONDS (30)
AUDIO_QUEUE_FRAMES       (3000)     trames de 10 ms gardées par pipeline (30 s)
JOB_MEMORY_WARN_MB       (700)      alerte livekit-agents ; JOB_MEMORY_LIMIT_MB (1800) = process tué
STATS_INTERVAL_SECONDS   (60)       période du journal « stats » (pipelines, mémoire, compteurs)
AGENT_NAME               (transcriber)  nom dispatché par l'app (TRANSCRIBER_AGENT_NAME)
"""
from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import json
import logging
import os
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable

import httpx
import jwt
from livekit import rtc
from livekit.agents import AutoSubscribe, JobContext, WorkerOptions, cli, vad as agents_vad
from livekit.plugins import silero

import noise
from lifecycle import BoundedSegmentQueue, PipelineRegistry, QueueClosed
from whisper_client import DEFAULT_SOURCE, REALTIME_PRIORITY, WhisperClient, WhisperError

LOGGER = logging.getLogger("transcriber")
TRANSCRIPTION_TOPIC = "lk.transcription"
# Identités émises par l'app : animateur, intervenants et spectateurs.
# Un spectateur ne publie de micro que si l'animateur lui donne la parole
# (main levée : il GARDE son identité ``viewer-<inscription>``). L'agent
# transcrit tout micro publié par ces identités ; l'archive côté app
# applique la règle fine (intervenant actif, inscription confirmée).
PUBLISHER_PREFIXES = ("host-", "speaker-", "viewer-")
# Silero et Whisper travaillent à 16 kHz mono : on le demande au flux natif
# (un seul rééchantillonnage, en Rust) plutôt que 48 kHz converti en Python.
SAMPLE_RATE = 16000
DEFAULT_MEMORY_WARN_MB = 700.0
DEFAULT_MEMORY_LIMIT_MB = 1800.0

# -- Config -----------------------------------------------------------


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    return float(raw) if raw else default


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    return int(raw) if raw else default


@dataclass(frozen=True)
class Config:
    livekit_url: str
    livekit_api_key: str
    livekit_api_secret: str
    whisper_base_url: str
    whisper_api_key: str
    whisper_model: str
    whisper_language: str
    archive_webhook_url: str
    whisper_priority: str = REALTIME_PRIORITY
    whisper_source: str = DEFAULT_SOURCE
    whisper_timeout: float = 20.0
    whisper_max_concurrency: int = 4
    live_max_age: float = 15.0
    segment_queue_max: int = 12
    min_segment_seconds: float = 0.4
    vad_min_silence: float = 0.5
    vad_min_speech: float = 0.2
    vad_max_speech: float = 30.0
    audio_queue_frames: int = 3000
    memory_warn_mb: float = DEFAULT_MEMORY_WARN_MB
    memory_limit_mb: float = DEFAULT_MEMORY_LIMIT_MB
    stats_interval: float = 60.0

    @classmethod
    def from_env(cls) -> "Config":
        required = (
            "LIVEKIT_URL",
            "LIVEKIT_API_KEY",
            "LIVEKIT_API_SECRET",
            "WHISPER_BASE_URL",
            "ARCHIVE_WEBHOOK_URL",
        )
        missing = [name for name in required if not os.getenv(name)]
        if missing:
            raise SystemExit(f"transcriber: missing env vars: {missing}")
        return cls(
            livekit_url=os.environ["LIVEKIT_URL"],
            livekit_api_key=os.environ["LIVEKIT_API_KEY"],
            livekit_api_secret=os.environ["LIVEKIT_API_SECRET"],
            whisper_base_url=os.environ["WHISPER_BASE_URL"].rstrip("/"),
            # Serveur Whisper qui ne valide pas la clé : sentinelle visible
            # dans les logs, jamais un vrai secret.
            whisper_api_key=os.getenv("WHISPER_API_KEY", "sk-whisper-adapter-noop"),
            whisper_model=os.getenv("WHISPER_MODEL", "whisper-1"),
            whisper_language=os.getenv("WHISPER_LANGUAGE", "fr"),
            archive_webhook_url=os.environ["ARCHIVE_WEBHOOK_URL"],
            whisper_priority=os.getenv("WHISPER_PRIORITY", REALTIME_PRIORITY),
            whisper_source=os.getenv("WHISPER_SOURCE", DEFAULT_SOURCE),
            whisper_timeout=_env_float("WHISPER_TIMEOUT_SECONDS", 20.0),
            whisper_max_concurrency=_env_int("WHISPER_MAX_CONCURRENCY", 4),
            live_max_age=_env_float("LIVE_MAX_AGE_SECONDS", 15.0),
            segment_queue_max=_env_int("SEGMENT_QUEUE_MAX", 12),
            min_segment_seconds=_env_float("MIN_SEGMENT_SECONDS", 0.4),
            vad_min_silence=_env_float("VAD_MIN_SILENCE_SECONDS", 0.5),
            vad_min_speech=_env_float("VAD_MIN_SPEECH_SECONDS", 0.2),
            vad_max_speech=_env_float("VAD_MAX_SPEECH_SECONDS", 30.0),
            audio_queue_frames=_env_int("AUDIO_QUEUE_FRAMES", 3000),
            memory_warn_mb=_env_float("JOB_MEMORY_WARN_MB", DEFAULT_MEMORY_WARN_MB),
            memory_limit_mb=_env_float("JOB_MEMORY_LIMIT_MB", DEFAULT_MEMORY_LIMIT_MB),
            stats_interval=_env_float("STATS_INTERVAL_SECONDS", 60.0),
        )


# -- Archive signée ---------------------------------------------------


class ArchiveClient:
    """POST signé vers l'app Rails (POST /webhooks/transcripts).

    Signature : identique au webhook LiveKit (JWT HS256, iss = api_key,
    claim sha256 = base64 SHA-256 du corps brut, exp = now + 5 min).
    """

    def __init__(self, config: Config) -> None:
        self._config = config
        self._client = httpx.AsyncClient(timeout=httpx.Timeout(5.0, connect=2.0))

    async def aclose(self) -> None:
        if self._client.is_closed:
            return
        await self._client.aclose()

    def _sign(self, body: bytes) -> str:
        claims = {
            "iss": self._config.livekit_api_key,
            "exp": int(time.time()) + 300,
            "sha256": base64.b64encode(hashlib.sha256(body).digest()).decode("ascii"),
        }
        token = jwt.encode(claims, self._config.livekit_api_secret, algorithm="HS256")
        return f"Bearer {token}"

    async def send(self, payload: dict) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        auth = self._sign(body)
        try:
            response = await self._client.post(
                self._config.archive_webhook_url,
                content=body,
                headers={"Content-Type": "application/json", "Authorization": auth},
            )
            if response.status_code >= 400:
                LOGGER.warning("archive webhook rejected: %s %s", response.status_code, response.text[:200])
        except httpx.HTTPError as exc:
            # Pas de retry : un direct qui boucle sur un webhook en panne
            # c'est pire qu'un segment manqué.
            LOGGER.warning("archive webhook error: %s", exc)


# -- Publication live --------------------------------------------------


async def publish_segment_live(
    room: rtc.Room,
    *,
    segment_id: str,
    identity: str,
    display_name: str | None,
    text: str,
    final: bool,
    start_ms: int | None = None,
    end_ms: int | None = None,
) -> None:
    """Pousse un segment sur le text stream LiveKit topic lk.transcription.

    Les attributs sont ceux reconnus par ``useTranscriptions`` de
    @livekit/components-react 2.9 (setupTextStream) :
    ``lk.segment_id`` et ``lk.transcription_final``. On ajoute pour la
    jointure côté client ``lk.participant_identity``, ``lk.participant_name``
    et l'heure MURALE de la parole (epoch ms) : ``lk.segment_start_ms`` /
    ``lk.segment_end_ms``, qui permettent au panneau de reconnaître une
    phrase dite il y a longtemps et émise maintenant.
    """
    attributes = {
        "lk.segment_id": segment_id,
        "lk.transcription_final": "true" if final else "false",
        "lk.participant_identity": identity,
    }
    if start_ms is not None:
        attributes["lk.segment_start_ms"] = str(start_ms)
    if end_ms is not None:
        attributes["lk.segment_end_ms"] = str(end_ms)
    if display_name:
        attributes["lk.participant_name"] = display_name
    try:
        # Un seul chunk par segment : nos textes pèsent qq centaines d'octets.
        await room.local_participant.send_text(
            text=text,
            topic=TRANSCRIPTION_TOPIC,
            attributes=attributes,
        )
    except Exception as exc:  # pragma: no cover — exercé en staging
        LOGGER.warning("send_text failed for segment %s: %s", segment_id, exc)


# -- Mesures ------------------------------------------------------------


@dataclass
class JobStats:
    """Compteurs du job, journalisés périodiquement (``heartbeat``)."""

    published: int = 0
    archived_only_stale: int = 0
    filtered_noise: int = 0
    too_short: int = 0
    dropped_overflow: int = 0
    whisper_errors: int = 0
    whisper_ms_max: float = 0.0
    lag_s_max: float = 0.0

    def snapshot(self) -> dict[str, float]:
        return {k: round(v, 2) if isinstance(v, float) else v for k, v in self.__dict__.items()}


def rss_mb() -> float:
    """Mémoire résidente du process, en Mo (0 si /proc est illisible)."""
    try:
        with open("/proc/self/statm", encoding="ascii") as statm:
            resident_pages = int(statm.read().split()[1])
        return resident_pages * os.sysconf("SC_PAGE_SIZE") / (1024 * 1024)
    except (OSError, ValueError, IndexError):
        return 0.0


async def heartbeat(
    *,
    registry: PipelineRegistry,
    stats: JobStats,
    config: Config,
    room_name: str,
    read_rss: Callable[[], float] = rss_mb,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> None:
    """Journal « stats » périodique : la preuve qui manquait au diagnostic."""
    while True:
        await sleep(config.stats_interval)
        memory = read_rss()
        LOGGER.info(
            "stats room=%s pipelines=%d identities=%s rss_mb=%.0f %s",
            room_name, len(registry), registry.identities(), memory, stats.snapshot(),
        )
        if memory > config.memory_warn_mb:
            LOGGER.warning(
                "mémoire du job %.0f Mo au-dessus du seuil %.0f Mo (limite %.0f Mo)",
                memory, config.memory_warn_mb, config.memory_limit_mb,
            )


# -- Pipeline STT par piste ------------------------------------------


@dataclass
class PipelineDeps:
    config: Config
    vad: Any
    whisper: Any
    archive: Any
    whisper_slots: asyncio.Semaphore
    stats: JobStats = field(default_factory=JobStats)


@dataclass(frozen=True)
class Segment:
    """Une prise de parole détectée par le VAD, horodatée sur l'AUDIO."""

    frames: list
    audio_start: float
    audio_end: float

    @property
    def duration(self) -> float:
        return self.audio_end - self.audio_start


# Résilience par piste : 5 tentatives, backoff 1 s, 2 s,
# 4 s, 8 s, plafonné à 30 s.
RETRY_MAX_ATTEMPTS = 5
RETRY_BASE_DELAY = 1.0
RETRY_MAX_DELAY = 30.0


def _frames_duration(frames: list) -> float:
    return sum(frame.samples_per_channel / frame.sample_rate for frame in frames)


async def process_segment(
    ctx: JobContext,
    participant: rtc.RemoteParticipant,
    segment: Segment,
    deps: PipelineDeps,
    *,
    now: Callable[[], float] | None = None,
) -> None:
    """Whisper -> filtre du bruit -> diffusion (si frais) -> archive.

    Une erreur Whisper perd CE segment, jamais le pipeline : le suivant part
    tout de suite. Un segment trop vieux reste archivé avec ses vrais
    horodatages mais n'est plus diffusé.
    """
    identity = participant.identity
    stats = deps.stats
    config = deps.config
    if segment.duration < config.min_segment_seconds:
        stats.too_short += 1
        return

    wav = rtc.combine_audio_frames(segment.frames).to_wav_bytes()
    started = time.monotonic()
    try:
        async with deps.whisper_slots:
            raw_text = await deps.whisper.transcribe(wav)
    except WhisperError as exc:
        stats.whisper_errors += 1
        LOGGER.warning("whisper %s: segment perdu (%.1fs d'audio): %s", identity, segment.duration, exc)
        return
    stats.whisper_ms_max = max(stats.whisper_ms_max, (time.monotonic() - started) * 1000)

    text = noise.clean((raw_text or "").strip())
    if text is None:
        stats.filtered_noise += 1
        return

    age = (now or time.time)() - segment.audio_end
    stats.lag_s_max = max(stats.lag_s_max, age)
    segment_id = str(uuid.uuid4())
    display_name = participant.name or identity

    if age <= config.live_max_age:
        await publish_segment_live(
            ctx.room,
            segment_id=segment_id,
            identity=identity,
            display_name=display_name,
            text=text,
            final=True,
            start_ms=int(segment.audio_start * 1000),
            end_ms=int(segment.audio_end * 1000),
        )
        stats.published += 1
    else:
        stats.archived_only_stale += 1
        LOGGER.info("segment %s trop vieux (%.0f s) : archivé sans diffusion", identity, age)

    await deps.archive.send({
        "room": ctx.room.name,
        "segment_id": segment_id,
        "participant": {"identity": identity, "name": display_name},
        "text": text,
        "started_at": _iso(segment.audio_start),
        "ended_at": _iso(segment.audio_end),
    })


_RELEASES_IN_FLIGHT: set[asyncio.Future] = set()


async def _release_pipeline(tasks: list[asyncio.Task], audio_stream: Any, vad_stream: Any) -> None:
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    # Source d'abord (abonnement natif à la piste), consommateur ensuite.
    with contextlib.suppress(Exception):
        await audio_stream.aclose()
    with contextlib.suppress(Exception):
        await vad_stream.aclose()


async def transcribe_track(
    ctx: JobContext,
    track: rtc.Track,
    participant: rtc.RemoteParticipant,
    deps: PipelineDeps,
) -> None:
    """Lit l'audio d'une piste et traite ses segments de parole.

    Trois tâches reliées par une file bornée : le lecteur audio alimente le
    VAD ; le détecteur range chaque fin de parole (avec son horodatage
    audio) dans la file ; le transcripteur la vide, un segment à la fois.
    Whisper lent ne bloque donc plus le VAD, et la mémoire reste bornée :
    au-delà de ``segment_queue_max`` le segment le plus ancien est abandonné.

    Le ``finally`` ferme les trois tâches, le flux audio et le flux VAD avant
    toute reprise ou sortie : un pipeline annulé ne laisse rien derrière lui.
    """
    config = deps.config
    audio_stream = rtc.AudioStream(
        track,
        sample_rate=SAMPLE_RATE,
        num_channels=1,
        capacity=config.audio_queue_frames,
    )
    vad_stream = deps.vad.stream()
    segments: BoundedSegmentQueue[Segment] = BoundedSegmentQueue(config.segment_queue_max)
    identity = participant.identity
    audio_origin: list[float] = []  # horloge murale de la première trame

    async def push_frames() -> None:
        async for ev in audio_stream:
            if not audio_origin:
                audio_origin.append(time.time())
            vad_stream.push_frame(ev.frame)
        vad_stream.end_input()

    async def detect_speech() -> None:
        try:
            async for event in vad_stream:
                if event.type != agents_vad.VADEventType.END_OF_SPEECH or not audio_origin:
                    continue
                audio_end = audio_origin[0] + event.timestamp
                audio_start = audio_end - _frames_duration(event.frames)
                dropped = segments.put(Segment(event.frames, audio_start, audio_end))
                if dropped:
                    deps.stats.dropped_overflow += len(dropped)
                    LOGGER.warning(
                        "pipeline %s en retard : %d segment(s) abandonné(s), file pleine (%d)",
                        identity, len(dropped), config.segment_queue_max,
                    )
        finally:
            segments.close()

    async def transcribe_segments() -> None:
        while True:
            try:
                segment = await segments.get()
            except QueueClosed:
                return
            await process_segment(ctx, participant, segment, deps)

    tasks = [
        asyncio.create_task(push_frames(), name=f"audio-pusher-{identity}"),
        asyncio.create_task(detect_speech(), name=f"vad-{identity}"),
        asyncio.create_task(transcribe_segments(), name=f"whisper-{identity}"),
    ]
    try:
        await asyncio.gather(*tasks)
    finally:
        # Une seconde annulation pendant la fermeture ne doit pas la couper :
        # elle laisserait les tâches internes du VAD orphelines.
        cleanup = asyncio.ensure_future(_release_pipeline(tasks, audio_stream, vad_stream))
        _RELEASES_IN_FLIGHT.add(cleanup)
        cleanup.add_done_callback(_RELEASES_IN_FLIGHT.discard)
        await asyncio.shield(cleanup)


def _track_alive(
    ctx: JobContext,
    publication: rtc.RemoteTrackPublication,
    participant: rtc.RemoteParticipant,
) -> bool:
    """Vrai si la room est toujours connectée, le participant toujours
    présent et la piste toujours publiée. Un ``False`` indique qu'il ne
    faut pas relancer après exception (room fermée, participant parti,
    piste dépubliée)."""
    room = ctx.room

    state = getattr(room, "connection_state", None)
    disconnected = getattr(rtc, "ConnectionState", None)
    if state is not None and disconnected is not None:
        for closed_name in ("CONN_DISCONNECTED", "DISCONNECTED"):
            closed = getattr(disconnected, closed_name, None)
            if closed is not None and state == closed:
                return False

    remotes = getattr(room, "remote_participants", {}) or {}
    identities = set()
    if hasattr(remotes, "values"):
        identities.update(remotes.keys())
        identities.update(p.identity for p in remotes.values())
    else:
        identities.update(p.identity for p in remotes)
    if participant.identity not in identities:
        return False

    pubs = getattr(participant, "track_publications", {}) or {}
    sids = set()
    if hasattr(pubs, "values"):
        sids.update(pubs.keys())
        sids.update(pub.sid for pub in pubs.values())
    else:
        sids.update(pub.sid for pub in pubs)
    if publication.sid not in sids:
        return False

    return True


async def supervise_track(
    ctx: JobContext,
    track: rtc.Track,
    publication: rtc.RemoteTrackPublication,
    participant: rtc.RemoteParticipant,
    deps: PipelineDeps,
    *,
    max_attempts: int = RETRY_MAX_ATTEMPTS,
    base_delay: float = RETRY_BASE_DELAY,
    max_delay: float = RETRY_MAX_DELAY,
    _transcribe=transcribe_track,
    _sleep=asyncio.sleep,
) -> None:
    """Exécute ``transcribe_track`` avec reprise bornée par piste.

    Une exception du pipeline (VAD, flux audio, bug plugin…) relance la
    piste avec backoff exponentiel plafonné. Jamais de boucle serrée :
    ``_sleep(delay)`` entre deux essais. Arrêt dès que ``_track_alive`` est
    faux (room fermée, participant parti, piste dépubliée) ou après
    ``max_attempts`` échecs cumulés.

    Un retour sans exception = fin propre (audio terminé, piste coupée) :
    aucun retry.
    """
    identity = participant.identity
    attempt = 0
    while True:
        if not _track_alive(ctx, publication, participant):
            LOGGER.info("transcribe %s: piste/room absente, arrêt", identity)
            return
        try:
            await _transcribe(ctx, track, participant, deps)
            return
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            attempt += 1
            if attempt >= max_attempts:
                LOGGER.error(
                    "transcribe %s: abandon après %d tentatives (%s: %s)",
                    identity, attempt, type(exc).__name__, exc,
                )
                return
            delay = min(max_delay, base_delay * (2 ** (attempt - 1)))
            LOGGER.warning(
                "transcribe %s: tentative %d/%d échouée (%s: %s), retry dans %.1fs",
                identity, attempt, max_attempts, type(exc).__name__, exc, delay,
            )
            await _sleep(delay)
            if not _track_alive(ctx, publication, participant):
                LOGGER.info("transcribe %s: piste/room absente pendant backoff, arrêt", identity)
                return


# -- Session : événements de la salle -> registre de pipelines -----------


class TranscriptionSession:
    """Traduit les événements de la salle en démarrages/arrêts de pipelines.

    ``launch(track, publication, participant)`` fournit la coroutine d'un
    pipeline ; le registre garantit un seul pipeline par identité.
    """

    def __init__(
        self,
        registry: PipelineRegistry,
        launch: Callable[[Any, Any, Any], Awaitable[None]],
    ) -> None:
        self._registry = registry
        self._launch = launch

    def on_track_subscribed(self, track, publication, participant) -> None:
        if track.kind != rtc.TrackKind.KIND_AUDIO:
            return
        if not should_transcribe(participant):
            LOGGER.info("ignoring non-publisher participant %s", participant.identity)
            return
        if publication.source == rtc.TrackSource.SOURCE_SCREENSHARE_AUDIO:
            # Le son d'un écran partagé n'est pas la parole de l'intervenant, et
            # son pipeline remplacerait celui de son micro (un par identité).
            LOGGER.info("ignoring screen share audio of %s", participant.identity)
            return
        if self._registry.is_running(participant.identity, publication.sid):
            return
        LOGGER.info("transcribing %s (track sid=%s)", participant.identity, publication.sid)
        self._registry.start(
            participant.identity,
            track_sid=publication.sid,
            participant_sid=participant.sid,
            run=lambda: self._launch(track, publication, participant),
        )

    def on_track_unsubscribed(self, track, publication, participant) -> None:
        self._stop_track(publication, participant)

    def on_track_unpublished(self, publication, participant) -> None:
        self._stop_track(publication, participant)

    def on_participant_disconnected(self, participant) -> None:
        if self._registry.stop_participant(participant.identity, participant.sid):
            LOGGER.info("participant %s parti : pipeline arrêté", participant.identity)

    def _stop_track(self, publication, participant) -> None:
        if self._registry.stop_track(participant.identity, publication.sid):
            LOGGER.info(
                "piste %s de %s retirée : pipeline arrêté", publication.sid, participant.identity
            )


SHUTDOWN_TRACK_TIMEOUT = 10.0


async def shutdown_session(
    *,
    registry: PipelineRegistry,
    archive: ArchiveClient,
    done: asyncio.Event,
    reason: str = "",
    whisper: WhisperClient | None = None,
    background: tuple[asyncio.Task, ...] = (),
) -> None:
    """Annule les pipelines, ferme archive et Whisper, puis signale la fin du job.

    livekit-agents 0.12 n'annule pas l'entrypoint : à la fermeture de
    salle il envoie ``Exiting`` (« process exiting ») puis attend
    ``shutdown_process_timeout`` (60 s) que le processus meure. Sans
    ce callback, les ``AudioStream`` FFI restent ouverts et le worker
    tue le job.
    Idempotent : un second appel, ``done`` déjà posé, est un no-op.
    """
    if done.is_set():
        return
    LOGGER.info(
        "arrêt propre du job (%s), %d pipeline(s)", reason or "sans motif", len(registry)
    )
    for task in background:
        task.cancel()
    leftover = await registry.stop_all(timeout=SHUTDOWN_TRACK_TIMEOUT)
    if leftover:
        LOGGER.warning("arrêt : %d pipeline(s) n'ont pas répondu en %.0fs", leftover, SHUTDOWN_TRACK_TIMEOUT)
    for closer in (archive, whisper):
        if closer is None:
            continue
        try:
            await closer.aclose()
        except Exception:
            LOGGER.warning("fermeture client HTTP échouée pendant l'arrêt", exc_info=True)
    done.set()


def _iso(epoch_seconds: float) -> str:
    """ISO 8601 UTC avec millisecondes (Rails Time.iso8601 l'accepte)."""
    seconds = int(epoch_seconds)
    millis = int((epoch_seconds - seconds) * 1000)
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(seconds)) + f".{millis:03d}Z"


def should_transcribe(participant: rtc.RemoteParticipant) -> bool:
    """Identités émises par l'app uniquement (host-, speaker-, viewer-) ;
    un ``viewer-*`` ne publie de micro qu'avec la parole accordée par
    l'animateur. L'autorisation fine est appliquée à l'archive (app)."""
    return any(participant.identity.startswith(prefix) for prefix in PUBLISHER_PREFIXES)


async def transcript_enabled(config: Config) -> bool:
    """Interroge l'app (GET <archive>/enabled). Toute erreur = désactivé."""
    url = config.archive_webhook_url.rstrip("/") + "/enabled"
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(5.0, connect=2.0)) as client:
            response = await client.get(url)
        return response.status_code == 200 and response.json().get("enabled") is True
    except (httpx.HTTPError, ValueError) as exc:
        LOGGER.warning("activation du transcript invérifiable (%s) : désactivé", exc)
        return False


# -- Entrypoint worker -----------------------------------------------


async def entrypoint(ctx: JobContext) -> None:
    config = Config.from_env()

    if not await transcript_enabled(config):
        # Fail-closed : l'app n'a pas activé le transcript (TRANSCRIPT_ENABLED,
        # posé par la configuration de déploiement) ou ne répond pas.
        LOGGER.warning("transcript non activé par l'app — salle %s ignorée", ctx.room.name)
        ctx.shutdown("transcript non activé")
        return

    archive = ArchiveClient(config)
    whisper = WhisperClient(
        base_url=config.whisper_base_url,
        model=config.whisper_model,
        language=config.whisper_language,
        api_key=config.whisper_api_key,
        priority=config.whisper_priority,
        source=config.whisper_source,
        timeout=config.whisper_timeout,
    )
    deps = PipelineDeps(
        config=config,
        vad=silero.VAD.load(
            min_speech_duration=config.vad_min_speech,
            min_silence_duration=config.vad_min_silence,
            max_buffered_speech=config.vad_max_speech,
            sample_rate=SAMPLE_RATE,
        ),
        whisper=whisper,
        archive=archive,
        whisper_slots=asyncio.Semaphore(config.whisper_max_concurrency),
    )

    LOGGER.info(
        "transcriber joined room=%s url=%s whisper_priority=%s live_max_age=%.0fs",
        ctx.room.name, config.livekit_url, config.whisper_priority, config.live_max_age,
    )

    registry = PipelineRegistry()
    done = asyncio.Event()
    session = TranscriptionSession(
        registry,
        lambda track, publication, participant: supervise_track(
            ctx, track, publication, participant, deps
        ),
    )
    stats_task = asyncio.create_task(
        heartbeat(registry=registry, stats=deps.stats, config=config, room_name=ctx.room.name),
        name="heartbeat",
    )

    async def on_shutdown(reason: str) -> None:
        await shutdown_session(
            registry=registry, archive=archive, whisper=whisper,
            done=done, reason=reason, background=(stats_task,),
        )

    ctx.add_shutdown_callback(on_shutdown)

    ctx.room.on("track_subscribed", session.on_track_subscribed)
    ctx.room.on("track_unsubscribed", session.on_track_unsubscribed)
    ctx.room.on("track_unpublished", session.on_track_unpublished)
    ctx.room.on("participant_disconnected", session.on_participant_disconnected)

    await ctx.connect(auto_subscribe=AutoSubscribe.AUDIO_ONLY)
    await done.wait()


def main() -> None:
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    memory_limits = {
        "job_memory_warn_mb": _env_float("JOB_MEMORY_WARN_MB", DEFAULT_MEMORY_WARN_MB),
        "job_memory_limit_mb": _env_float("JOB_MEMORY_LIMIT_MB", DEFAULT_MEMORY_LIMIT_MB),
    }
    # Le process d'un job dépassant ``job_memory_limit_mb`` est tué par le
    # worker : dernier garde-fou, la file bornée doit l'éviter bien avant.
    cli.run_app(worker_options(memory_limits))


def worker_options(memory_limits: dict[str, float]) -> WorkerOptions:
    """Worker NOMMÉ : jamais d'auto-dispatch.

    L'auto-dispatch (``agent_name`` vide) n'envoyait l'agent qu'à la
    création de la salle : un direct terminé puis repris dans une salle
    restée ouverte n'était plus transcrit. Nommé,
    l'agent rejoint chaque salle que l'app lui désigne, autant de fois qu'il
    le faut.
    """
    return WorkerOptions(
        entrypoint_fnc=entrypoint,
        agent_name=os.getenv("AGENT_NAME") or "transcriber",
        **memory_limits,
    )


if __name__ == "__main__":
    main()
