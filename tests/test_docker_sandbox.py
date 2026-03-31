from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest

from agent_sandbox.docker_sandbox import (
    SandboxPlan,
    build_plan,
    execute_plan,
    fetch_network_logs,
    remove_sandbox,
    stop_sandbox,
)
from agent_sandbox.errors import ConfigurationError
from agent_sandbox.models import Settings
from agent_sandbox.subprocess_runner import CommandResult


class FakeRunner:
    def __init__(self) -> None:
        self.commands: list[list[str]] = []

    def run(self, command: list[str], check: bool = True) -> CommandResult:
        _ = check
        self.commands.append(command)
        return CommandResult(command=command, returncode=0, stdout='{"ok":true}', stderr="")


@pytest.fixture()
def settings() -> Settings:
    return Settings(
        project_name="demo",
        base_url="https://example.gov/v1",
        provider_id="custom",
        provider_name="Custom API",
        model="model-a",
        api_key_env="OPENAI_COMPAT_API_KEY",
        template="docker/sandbox-templates:opencode",
        policy_profile="balanced",
        secret_backend="env",
        sandbox_name="demo-sandbox",
    )


def test_build_plan_unknown_policy_raises(tmp_path: Path, settings: Settings) -> None:
    broken = replace(settings, policy_profile="not-real")
    with pytest.raises(ConfigurationError, match="Unknown policy profile"):
        build_plan(tmp_path, broken)


def test_execute_plan_runs_all_commands_in_order() -> None:
    plan = SandboxPlan(
        create_command=["docker", "sandbox", "create", "template"],
        network_commands=[
            ["docker", "sandbox", "network", "proxy", "demo", "--policy", "allow"],
            ["docker", "sandbox", "network", "proxy", "demo", "--block-cidr", "10.0.0.0/8"],
        ],
        launch_command=["docker", "sandbox", "exec", "demo", "opencode"],
    )
    runner = FakeRunner()

    execute_plan(plan, runner)

    assert runner.commands == [
        ["docker", "sandbox", "create", "template"],
        ["docker", "sandbox", "network", "proxy", "demo", "--policy", "allow"],
        ["docker", "sandbox", "network", "proxy", "demo", "--block-cidr", "10.0.0.0/8"],
        ["docker", "sandbox", "exec", "demo", "opencode"],
    ]


def test_stop_sandbox_calls_expected_command() -> None:
    runner = FakeRunner()
    stop_sandbox("demo-sandbox", runner)
    assert runner.commands == [["docker", "sandbox", "stop", "demo-sandbox"]]


def test_remove_sandbox_calls_expected_command() -> None:
    runner = FakeRunner()
    remove_sandbox("demo-sandbox", runner)
    assert runner.commands == [["docker", "sandbox", "rm", "-f", "demo-sandbox"]]


def test_fetch_network_logs_returns_stdout() -> None:
    runner = FakeRunner()
    result = fetch_network_logs("demo-sandbox", runner)
    assert result == '{"ok":true}'
    assert runner.commands == [
        ["docker", "sandbox", "network", "log", "demo-sandbox", "--json"],
    ]
