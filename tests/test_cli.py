from __future__ import annotations

from pathlib import Path

import pytest
from typer.testing import CliRunner

from agent_sandbox.cli import _main, app
from agent_sandbox.docker_sandbox import SandboxPlan
from agent_sandbox.errors import AgentSandboxError

runner = CliRunner()


def test_version_command() -> None:
    result = runner.invoke(app, ["version"])
    assert result.exit_code == 0, result.stdout
    assert result.stdout.strip() == "0.2.0"


def test_init_command_creates_config(repo_root: Path) -> None:
    result = runner.invoke(app, ["init", "--path", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert "Initialized" in result.stdout
    assert (repo_root / ".agent-sandbox" / "config.toml").exists()
    assert (repo_root / ".agent-sandbox" / "logs" / "agent-sandbox.log").exists()


def test_doctor_command_success(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
    sample_settings,
) -> None:
    monkeypatch.setattr("agent_sandbox.cli.load_settings", lambda _: sample_settings)
    monkeypatch.setattr(
        "agent_sandbox.cli.build_doctor_report",
        lambda _: [
            ("python>=3.11", True, "3.13.11"),
            ("docker", True, "/usr/bin/docker"),
        ],
    )

    result = runner.invoke(app, ["doctor", "--path", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert "OK" in result.stdout


def test_doctor_command_failure(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
    sample_settings,
) -> None:
    monkeypatch.setattr("agent_sandbox.cli.load_settings", lambda _: sample_settings)
    monkeypatch.setattr(
        "agent_sandbox.cli.build_doctor_report",
        lambda _: [
            ("python>=3.11", True, "3.13.11"),
            ("docker", False, "missing"),
        ],
    )

    result = runner.invoke(app, ["doctor", "--path", str(repo_root)])
    assert result.exit_code == 1, result.stdout
    assert "FAIL" in result.stdout


def test_provider_probe_command(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
    sample_settings,
    sample_probe,
) -> None:
    captured: dict[str, object] = {}

    monkeypatch.setattr("agent_sandbox.cli.load_settings", lambda _: sample_settings)
    monkeypatch.setattr("agent_sandbox.cli.merged_env", lambda _: {"OPENAI_COMPAT_API_KEY": "abc"})
    monkeypatch.setattr("agent_sandbox.cli.probe_provider", lambda *_args: sample_probe)

    def fake_write_provider_lock(root: Path, probe) -> None:
        captured["repo_root"] = root
        captured["probe"] = probe

    monkeypatch.setattr("agent_sandbox.cli.write_provider_lock", fake_write_provider_lock)

    result = runner.invoke(app, ["provider", "probe", "--path", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert "Provider OK: GSAi -> model-a" in result.stdout
    assert captured["repo_root"] == repo_root
    assert captured["probe"] == sample_probe


def test_config_render_uses_existing_provider_lock(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
    sample_settings,
    sample_probe,
) -> None:
    monkeypatch.setattr("agent_sandbox.cli.load_settings", lambda _: sample_settings)
    monkeypatch.setattr("agent_sandbox.cli.load_provider_lock", lambda _: sample_probe)
    monkeypatch.setattr(
        "agent_sandbox.cli.probe_provider",
        lambda *_args: pytest.fail("should not probe"),
    )
    monkeypatch.setattr(
        "agent_sandbox.cli.render_opencode_config",
        lambda root, _settings, _probe: root / "opencode.json",
    )

    result = runner.invoke(app, ["config", "render", "--path", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert str(repo_root / "opencode.json") in result.stdout


def test_config_render_force_probe(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
    sample_settings,
    sample_probe,
) -> None:
    monkeypatch.setattr("agent_sandbox.cli.load_settings", lambda _: sample_settings)
    monkeypatch.setattr("agent_sandbox.cli.load_provider_lock", lambda _: sample_probe)
    monkeypatch.setattr("agent_sandbox.cli.merged_env", lambda _: {"OPENAI_COMPAT_API_KEY": "abc"})

    probed = {"called": False}

    def fake_probe(*_args):
        probed["called"] = True
        return sample_probe

    monkeypatch.setattr("agent_sandbox.cli.probe_provider", fake_probe)
    monkeypatch.setattr("agent_sandbox.cli.write_provider_lock", lambda *_args: None)
    monkeypatch.setattr(
        "agent_sandbox.cli.render_opencode_config",
        lambda root, _settings, _probe: root / "opencode.json",
    )

    result = runner.invoke(
        app,
        ["config", "render", "--path", str(repo_root), "--force-probe"],
    )
    assert result.exit_code == 0, result.stdout
    assert probed["called"] is True


def test_run_dry_run_prints_commands(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
    sample_settings,
    sample_probe,
) -> None:
    plan = SandboxPlan(
        create_command=[
            "docker",
            "sandbox",
            "create",
            "template",
            "--name",
            "demo",
            str(repo_root),
        ],
        network_commands=[
            ["docker", "sandbox", "network", "proxy", "demo", "--policy", "allow"],
            [
                "docker",
                "sandbox",
                "network",
                "proxy",
                "demo",
                "--block-cidr",
                "10.0.0.0/8",
            ],
        ],
        launch_command=["docker", "sandbox", "exec", "demo", "opencode"],
    )

    monkeypatch.setattr("agent_sandbox.cli.load_settings", lambda _: sample_settings)
    monkeypatch.setattr("agent_sandbox.cli.ensure_secret_backend", lambda _: None)
    monkeypatch.setattr("agent_sandbox.cli.load_provider_lock", lambda _: sample_probe)
    monkeypatch.setattr(
        "agent_sandbox.cli.render_opencode_config",
        lambda *_args: repo_root / "opencode.json",
    )
    monkeypatch.setattr("agent_sandbox.cli.build_plan", lambda *_args: plan)
    monkeypatch.setattr(
        "agent_sandbox.cli.execute_plan",
        lambda *_args: pytest.fail("should not execute"),
    )

    result = runner.invoke(app, ["run", "--repo", str(repo_root), "--dry-run"])
    assert result.exit_code == 0, result.stdout
    assert "docker sandbox create template --name demo" in result.stdout
    assert "docker sandbox exec demo opencode" in result.stdout


def test_run_without_lock_probes_provider(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
    sample_settings,
    sample_probe,
) -> None:
    plan = SandboxPlan(
        create_command=[
            "docker",
            "sandbox",
            "create",
            "template",
            "--name",
            "demo",
            str(repo_root),
        ],
        network_commands=[],
        launch_command=["docker", "sandbox", "exec", "demo", "opencode"],
    )

    called = {"probe": False, "execute": False}

    monkeypatch.setattr("agent_sandbox.cli.load_settings", lambda _: sample_settings)
    monkeypatch.setattr("agent_sandbox.cli.ensure_secret_backend", lambda _: None)
    monkeypatch.setattr("agent_sandbox.cli.load_provider_lock", lambda _: None)
    monkeypatch.setattr("agent_sandbox.cli.merged_env", lambda _: {"OPENAI_COMPAT_API_KEY": "abc"})

    def fake_probe(*_args):
        called["probe"] = True
        return sample_probe

    monkeypatch.setattr("agent_sandbox.cli.probe_provider", fake_probe)
    monkeypatch.setattr("agent_sandbox.cli.write_provider_lock", lambda *_args: None)
    monkeypatch.setattr(
        "agent_sandbox.cli.render_opencode_config",
        lambda *_args: repo_root / "opencode.json",
    )
    monkeypatch.setattr("agent_sandbox.cli.build_plan", lambda *_args: plan)

    def fake_execute(*_args) -> None:
        called["execute"] = True

    monkeypatch.setattr("agent_sandbox.cli.execute_plan", fake_execute)

    result = runner.invoke(app, ["run", "--repo", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert called["probe"] is True
    assert called["execute"] is True


def test_logs_command_without_file(repo_root: Path) -> None:
    result = runner.invoke(app, ["logs", "--path", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert "No audit log found." in result.stdout


def test_logs_command_with_file(repo_root: Path) -> None:
    log_dir = repo_root / ".agent-sandbox" / "logs"
    log_dir.mkdir(parents=True)
    log_path = log_dir / "agent-sandbox.log"
    log_path.write_text("line-1\nline-2\nline-3\n", encoding="utf-8")

    result = runner.invoke(app, ["logs", "--path", str(repo_root), "--lines", "2"])
    assert result.exit_code == 0, result.stdout
    assert "line-2" in result.stdout
    assert "line-3" in result.stdout
    assert "line-1" not in result.stdout


def test_netlogs_command(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
    sample_settings,
) -> None:
    monkeypatch.setattr("agent_sandbox.cli.load_settings", lambda _: sample_settings)
    monkeypatch.setattr("agent_sandbox.cli.fetch_network_logs", lambda *_args: '{"event":"ok"}')

    result = runner.invoke(app, ["netlogs", "--path", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert '{"event":"ok"}' in result.stdout


def test_stop_command(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
    sample_settings,
) -> None:
    monkeypatch.setattr("agent_sandbox.cli.load_settings", lambda _: sample_settings)
    monkeypatch.setattr("agent_sandbox.cli.stop_sandbox", lambda *_args: None)

    result = runner.invoke(app, ["stop", "--path", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert f"Stopped {sample_settings.sandbox_name}" in result.stdout


def test_remove_command(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
    sample_settings,
) -> None:
    monkeypatch.setattr("agent_sandbox.cli.load_settings", lambda _: sample_settings)
    monkeypatch.setattr("agent_sandbox.cli.remove_sandbox", lambda *_args: None)

    result = runner.invoke(app, ["remove", "--path", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert f"Removed {sample_settings.sandbox_name}" in result.stdout


def test_encrypt_command(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
) -> None:
    monkeypatch.setattr("agent_sandbox.cli.encrypt_env", lambda *_args: None)

    result = runner.invoke(app, ["encrypt", "--path", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert "Encrypted .env -> .env.enc" in result.stdout


def test_decrypt_command(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
) -> None:
    monkeypatch.setattr("agent_sandbox.cli.decrypt_env", lambda *_args: None)

    result = runner.invoke(app, ["decrypt", "--path", str(repo_root)])
    assert result.exit_code == 0, result.stdout
    assert "Decrypted .env.enc -> .env" in result.stdout


def test_main_returns_1_for_project_error(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_app() -> None:
        raise AgentSandboxError("boom")

    monkeypatch.setattr("agent_sandbox.cli.app", fake_app)
    assert _main() == 1
