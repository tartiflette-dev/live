"""Client whisper-adapter : voie temps réel et erreurs typées."""
from __future__ import annotations

import httpx
import pytest

from whisper_client import WhisperClient, WhisperError


def _client(handler) -> WhisperClient:
    return WhisperClient(
        base_url="http://gt.test:2023/v1/",
        model="whisper-1",
        language="fr",
        api_key="sk-noop",
        client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )


async def test_envoie_la_voie_temps_reel_et_la_source():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["body"] = request.content
        return httpx.Response(200, json={"text": "Bonjour"})

    text = await _client(handler).transcribe(b"RIFFfake")

    assert text == "Bonjour"
    assert seen["url"] == "http://gt.test:2023/v1/audio/transcriptions"
    body = seen["body"]
    assert b'name="priority"\r\n\r\nrealtime' in body
    assert b'name="source"\r\n\r\nlive\r\n' in body
    assert b'name="language"\r\n\r\nfr' in body
    assert b'filename="segment.wav"' in body


async def test_statut_erreur_leve_whisper_error():
    client = _client(lambda request: httpx.Response(502, text="upstream down"))
    with pytest.raises(WhisperError, match="HTTP 502"):
        await client.transcribe(b"x")


async def test_reponse_non_json_leve_whisper_error():
    client = _client(lambda request: httpx.Response(200, text="<html>"))
    with pytest.raises(WhisperError, match="non JSON"):
        await client.transcribe(b"x")


async def test_erreur_reseau_leve_whisper_error():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout("timeout", request=request)

    with pytest.raises(WhisperError, match="ConnectTimeout"):
        await _client(handler).transcribe(b"x")


async def test_texte_absent_ou_invalide_donne_chaine_vide():
    assert await _client(lambda request: httpx.Response(200, json={})).transcribe(b"x") == ""
    assert await _client(lambda request: httpx.Response(200, json={"text": 3})).transcribe(b"x") == ""
