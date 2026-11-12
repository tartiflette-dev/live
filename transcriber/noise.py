"""Filtre à la source du bruit Whisper (audit P1-7, transcript direct).

Whisper produit en français deux sortes de bruit :
  - des phrases « fantômes » apprises sur des génériques de sous-titrage,
    émises sur du silence ou de la musique (« Sous-titrage Société
    Radio-Canada ») ;
  - des segments faits uniquement d'hésitations (« Euh… », « Hum. »).

Un segment de bruit n'est ni diffusé ni archivé. Les listes vivent dans
``transcript_noise.json``, lu AUSSI par le filtre d'affichage du panneau
(``app/javascript/rooms/transcript_filter.js``) : une entrée ajoutée là vaut
pour la source et pour l'écran.

La comparaison porte sur le texte NORMALISÉ (minuscules, accents retirés,
ponctuation ramenée à des espaces) : les listes sont écrites sous cette forme.
"""
from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path

NOISE_PATH = Path(__file__).with_name("transcript_noise.json")

_REPEATED_LETTERS = re.compile(r"(.)\1+")
_NON_ALNUM = re.compile(r"[^a-z0-9]+")


def _load(path: Path = NOISE_PATH) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


_NOISE = _load()
PHANTOM_PREFIXES: tuple[str, ...] = tuple(_NOISE["phantom_prefixes"])
HESITATION_WORDS: frozenset[str] = frozenset(_NOISE["hesitation_words"])
_LEADING_FILLER = re.compile(_NOISE["leading_filler_pattern"], re.IGNORECASE)


def normalize(text: str) -> str:
    decomposed = unicodedata.normalize("NFD", text)
    without_accents = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    return _NON_ALNUM.sub(" ", without_accents.lower()).strip()


def _is_phantom(normalized: str) -> bool:
    return any(
        normalized == prefix or normalized.startswith(f"{prefix} ")
        for prefix in PHANTOM_PREFIXES
    )


def _is_hesitation_only(normalized: str) -> bool:
    return all(
        _REPEATED_LETTERS.sub(r"\1", word) in HESITATION_WORDS
        for word in normalized.split(" ")
    )


def clean(text: str | None) -> str | None:
    """Texte à retenir pour un segment, ou ``None`` si c'est du bruit.

    L'hésitation de tête est retirée AVANT les contrôles, pour qu'un
    « Euh, sous-titrage… » soit reconnu comme fantôme ; « Euh, donc… »
    devient « Donc… ».
    """
    raw = text or ""
    rest = _LEADING_FILLER.sub("", raw, count=1)
    normalized = normalize(rest)
    if normalized == "" or _is_phantom(normalized) or _is_hesitation_only(normalized):
        return None
    if rest == raw:
        return raw
    return rest[:1].upper() + rest[1:]
