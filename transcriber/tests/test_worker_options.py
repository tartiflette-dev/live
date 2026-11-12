"""Le worker est NOMMÉ : l'app le dispatche à l'ouverture ET à la reprise.

Auto-dispatché (``agent_name`` vide), l'agent n'était envoyé qu'à la
création de la salle : la reprise d'un direct, dans une salle
restée ouverte, n'a pas été transcrite.
"""
from __future__ import annotations

import agent


def test_worker_nomme_depuis_agent_name(monkeypatch) -> None:
    monkeypatch.setenv("AGENT_NAME", "transcriber-staging")

    options = agent.worker_options({"job_memory_warn_mb": 700.0, "job_memory_limit_mb": 1800.0})

    assert options.agent_name == "transcriber-staging"
    assert options.entrypoint_fnc is agent.entrypoint
    assert options.job_memory_limit_mb == 1800.0


def test_jamais_d_auto_dispatch_sans_agent_name(monkeypatch) -> None:
    monkeypatch.delenv("AGENT_NAME", raising=False)
    assert agent.worker_options({}).agent_name == "transcriber"

    monkeypatch.setenv("AGENT_NAME", "")
    assert agent.worker_options({}).agent_name == "transcriber"
