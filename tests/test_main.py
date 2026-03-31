from __future__ import annotations

import runpy
import sys


def test_python_m_invokes_cli_app(monkeypatch) -> None:
    called = {"value": False}

    def fake_app() -> None:
        called["value"] = True

    monkeypatch.setattr("agent_sandbox.cli.app", fake_app)
    monkeypatch.setattr(sys, "argv", ["agent-sandbox"])
    runpy.run_module("agent_sandbox.__main__", run_name="__main__")

    assert called["value"] is True
