"""Conftest du transcripteur.

Permet de lancer ``pytest`` depuis le dossier ``transcriber/`` sans
installer l'agent comme package : on ajoute le parent au sys.path.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
