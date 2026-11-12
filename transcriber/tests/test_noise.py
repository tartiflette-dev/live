"""Filtre à la source du bruit Whisper : liste PARTAGÉE avec le panneau
(``transcript_noise.json`` lu aussi par transcript_filter.js)."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

import noise

KEPT = [
    "Bonjour à tous, bienvenue au Café IA.",
    "Aujourd'hui on va parler d'agents.",
    "Ben oui, c'est ça.",
    "Heureusement, ça marche.",
    "Humain avant tout.",
    "Merci d'être venus.",
]

DROPPED = [
    "Sous-titrage Société Radio-Canada",
    "SOUS-TITRAGE ST' 501",
    "Sous-titres réalisés par la communauté d'Amara.org",
    "Sous-titres fait par la communauté d'Amara.org",
    "Sous-titres faits par la communauté d'Amara.org",
    "Merci d'avoir regardé cette vidéo.",
    "merci d’avoir regarde cette video !",
    "N'oubliez pas de vous abonner à la chaîne",
    "Amara.org",
    "Thanks for watching!",
    "Euh…",
    "Hum.",
    "Bah.",
    "Euh, euh... hmmm",
    "Mhm",
    "Euh, sous-titrage Société Radio-Canada",
    "",
    "   ",
    None,
    "...",
]


@pytest.mark.parametrize("text", KEPT)
def test_phrase_normale_conservee_telle_quelle(text):
    assert noise.clean(text) == text


@pytest.mark.parametrize("text", DROPPED)
def test_bruit_ecarte(text):
    assert noise.clean(text) is None


def test_hesitation_de_tete_retiree_et_majuscule_rendue():
    assert noise.clean("Euh, donc on commence") == "Donc on commence"
    assert noise.clean("Hmm... alors voilà") == "Alors voilà"


def test_normalize_retire_accents_casse_et_ponctuation():
    assert noise.normalize("  Sous-titrage ST' 501 ! ") == "sous titrage st 501"
    assert noise.normalize("Café — À bientôt") == "cafe a bientot"


def test_la_liste_partagee_est_sous_forme_normalisee():
    shared = json.loads(noise.NOISE_PATH.read_text(encoding="utf-8"))
    assert shared["phantom_prefixes"], "liste non vide"
    for entry in shared["phantom_prefixes"] + shared["hesitation_words"]:
        assert entry == noise.normalize(entry), f"« {entry} » doit être écrit sous sa forme normalisée"


def test_le_filtre_d_affichage_lit_la_meme_liste():
    # Garde-fou de partage : si le panneau ré-embarque sa propre liste, la
    # source et l'écran divergent en silence.
    panel_filter = Path(__file__).resolve().parents[2] / "app/javascript/rooms/transcript_filter.js"
    source = panel_filter.read_text(encoding="utf-8")
    assert "transcriber/transcript_noise.json" in source
