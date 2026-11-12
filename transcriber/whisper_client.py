"""Client du whisper-adapter (OpenAI-compat), voie TEMPS RÉEL.

Pourquoi pas le plugin openai de livekit-agents : il n'envoie ni ``priority``
ni ``source``. Sans ``priority`` l'adapter route sur le backend ACCURATE
(large-v3, un seul slot), partagé avec les passes batch : mesuré sur
3 904 requêtes du transcripteur, 7,8 s en médiane, 14,9 s au p95,
29 s au pire. ``priority=realtime`` route sur le backend rapide (turbo-q5,
même VAD silero et même filtre ``--suppress-nst``), quasi inoccupé.
"""
from __future__ import annotations

import httpx

REALTIME_PRIORITY = "realtime"
# Étiquette de l'appelant envoyée au serveur Whisper (`source`), surchargée par
# WHISPER_SOURCE : chaque instance y met son propre nom.
DEFAULT_SOURCE = "live"


class WhisperError(Exception):
    """Réponse inexploitable du whisper-adapter (statut, JSON, réseau)."""


class WhisperClient:
    def __init__(
        self,
        *,
        base_url: str,
        model: str,
        language: str,
        api_key: str,
        priority: str = REALTIME_PRIORITY,
        source: str = DEFAULT_SOURCE,
        timeout: float = 20.0,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._url = f"{base_url.rstrip('/')}/audio/transcriptions"
        self._form = {
            "model": model,
            "language": language,
            "response_format": "json",
            "temperature": "0",
            "priority": priority,
            "source": source,
        }
        self._headers = {"Authorization": f"Bearer {api_key}"}
        self._client = client or httpx.AsyncClient(
            timeout=httpx.Timeout(timeout, connect=3.0),
            limits=httpx.Limits(max_connections=8, max_keepalive_connections=4),
        )

    async def aclose(self) -> None:
        if not self._client.is_closed:
            await self._client.aclose()

    async def transcribe(self, wav: bytes) -> str:
        try:
            response = await self._client.post(
                self._url,
                data=self._form,
                files={"file": ("segment.wav", wav, "audio/wav")},
                headers=self._headers,
            )
        except httpx.HTTPError as exc:
            raise WhisperError(f"{type(exc).__name__}: {exc}") from exc
        if response.status_code >= 400:
            raise WhisperError(f"HTTP {response.status_code}: {response.text[:200]}")
        try:
            text = response.json().get("text", "")
        except (ValueError, AttributeError) as exc:
            raise WhisperError(f"réponse non JSON: {response.text[:200]}") from exc
        return text if isinstance(text, str) else ""
