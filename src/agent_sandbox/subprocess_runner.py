from __future__ import annotations

import subprocess
from dataclasses import dataclass

from agent_sandbox.errors import CommandExecutionError


@dataclass(slots=True)
class CommandResult:
    command: list[str]
    returncode: int
    stdout: str
    stderr: str


class SubprocessRunner:
    def run(self, command: list[str], check: bool = True) -> CommandResult:
        completed = subprocess.run(command, capture_output=True, check=False, text=True)
        result = CommandResult(
            command=command,
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
        )
        if check and result.returncode != 0:
            joined = " ".join(command)
            raise CommandExecutionError(f"Command failed: {joined}\n{result.stderr.strip()}")
        return result
