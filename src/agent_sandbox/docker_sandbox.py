from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from agent_sandbox.constants import POLICY_PROFILES
from agent_sandbox.errors import ConfigurationError
from agent_sandbox.models import Settings
from agent_sandbox.subprocess_runner import SubprocessRunner


@dataclass(slots=True)
class SandboxPlan:
    create_command: list[str]
    network_commands: list[list[str]]
    launch_command: list[str]


def build_plan(repo_root: Path, settings: Settings) -> SandboxPlan:
    profile = POLICY_PROFILES.get(settings.policy_profile)
    if profile is None:
        raise ConfigurationError(f"Unknown policy profile: {settings.policy_profile}")
    create_command = [
        "docker",
        "sandbox",
        "create",
        settings.template,
        "--name",
        settings.sandbox_name,
        str(repo_root),
    ]
    network_commands = [
        [
            "docker",
            "sandbox",
            "network",
            "proxy",
            settings.sandbox_name,
            "--policy",
            str(profile["default_policy"]),
        ]
    ]
    for cidr in list(profile["block_cidrs"]):
        network_commands.append(
            [
                "docker",
                "sandbox",
                "network",
                "proxy",
                settings.sandbox_name,
                "--block-cidr",
                str(cidr),
            ]
        )
    for host in list(profile["block_hosts"]):
        network_commands.append(
            [
                "docker",
                "sandbox",
                "network",
                "proxy",
                settings.sandbox_name,
                "--block-host",
                str(host),
            ]
        )
    launch_command = ["docker", "sandbox", "exec", settings.sandbox_name, "opencode"]
    return SandboxPlan(
        create_command=create_command,
        network_commands=network_commands,
        launch_command=launch_command,
    )


def execute_plan(plan: SandboxPlan, runner: SubprocessRunner) -> None:
    runner.run(plan.create_command)
    for command in plan.network_commands:
        runner.run(command)
    runner.run(plan.launch_command)


def stop_sandbox(sandbox_name: str, runner: SubprocessRunner) -> None:
    runner.run(["docker", "sandbox", "stop", sandbox_name])


def remove_sandbox(sandbox_name: str, runner: SubprocessRunner) -> None:
    runner.run(["docker", "sandbox", "rm", "-f", sandbox_name])


def fetch_network_logs(sandbox_name: str, runner: SubprocessRunner) -> str:
    result = runner.run(["docker", "sandbox", "network", "log", sandbox_name, "--json"])
    return result.stdout
