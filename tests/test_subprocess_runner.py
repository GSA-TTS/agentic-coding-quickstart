from __future__ import annotations

from types import SimpleNamespace

import pytest

from agent_sandbox.errors import CommandExecutionError
from agent_sandbox.subprocess_runner import SubprocessRunner


def test_run_returns_command_result(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_run(command, capture_output, check, text):
        assert command == ["docker", "--version"]
        assert capture_output is True
        assert check is False
        assert text is True
        return SimpleNamespace(returncode=0, stdout="ok\n", stderr="")

    monkeypatch.setattr("agent_sandbox.subprocess_runner.subprocess.run", fake_run)

    result = SubprocessRunner().run(["docker", "--version"])

    assert result.command == ["docker", "--version"]
    assert result.returncode == 0
    assert result.stdout == "ok\n"
    assert result.stderr == ""


def test_run_raises_on_failure_when_check_enabled(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_run(command, capture_output, check, text):
        _ = command
        _ = capture_output
        _ = check
        _ = text
        return SimpleNamespace(returncode=2, stdout="", stderr="boom\n")

    monkeypatch.setattr("agent_sandbox.subprocess_runner.subprocess.run", fake_run)

    with pytest.raises(CommandExecutionError, match="Command failed"):
        SubprocessRunner().run(["docker", "sandbox", "create"])


def test_run_does_not_raise_when_check_disabled(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_run(command, capture_output, check, text):
        _ = command
        _ = capture_output
        _ = check
        _ = text
        return SimpleNamespace(returncode=1, stdout="", stderr="nope")

    monkeypatch.setattr("agent_sandbox.subprocess_runner.subprocess.run", fake_run)

    result = SubprocessRunner().run(["docker", "sandbox", "stop", "demo"], check=False)

    assert result.returncode == 1
    assert result.stderr == "nope"
