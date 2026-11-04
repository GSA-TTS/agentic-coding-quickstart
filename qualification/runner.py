"""The transcript runner: drive one cell and record its transcript(s).

The runner executes a command (the Tier-3 oracle for a cell) as a subprocess and
classifies the result (``classify_exit``): exit 0 -> PASS, exit 2 -> BLOCKED,
any other exit -> FAIL. A missing/unexecutable command, a timeout, or an
unqualified cell records BLOCKED, never a pass. The reproduction rule then
confirms or escalates a FAIL.

The command's raw output is *digested, never persisted*: only its SHA-256 is
kept, so a secret the oracle happens to print never reaches the transcript. The
harness never records ``os.environ`` and never injects a secret into the command.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from typing import Sequence

from .model import Environment, Outcome, Transcript, Verdict, classify_exit, sha256_hex
from .repro import reproduce

# Harness exit codes (PASS/FAIL/BLOCKED mirror qualify-msb-ro-mount; FLAKY is the
# escalation signal a caller uses to file the tracking issue).
EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_BLOCKED = 2
EXIT_FLAKY = 3

# The 1-based attempt number is exported to the oracle command under this name so
# a fixture can branch deterministically on the attempt. It is a nonce, never a
# secret.
ATTEMPT_ENV = "ACQ_QUALIFY_ATTEMPT"


@dataclass(frozen=True)
class CellResult:
    """The settled outcome of running one cell, plus the attempt transcripts."""

    outcome: Outcome
    attempts: tuple[Transcript, ...]

    @property
    def environment(self) -> Environment:
        """The run's identity — every attempt in one run shares it."""
        return self.attempts[0].environment


def _single_run(
    command: Sequence[str],
    environment: Environment,
    attempt: int,
    timeout: float,
) -> Transcript:
    """Run the oracle once and return its transcript (never its raw output)."""
    if not command:
        return Transcript(
            Verdict.BLOCKED, environment, (), "", "no command supplied"
        )
    child_env = dict(os.environ)
    child_env[ATTEMPT_ENV] = str(attempt)
    try:
        proc = subprocess.run(
            list(command),
            env=child_env,
            capture_output=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        return Transcript(
            Verdict.BLOCKED, environment, tuple(command), "", "command not found"
        )
    except subprocess.TimeoutExpired:
        return Transcript(
            Verdict.BLOCKED, environment, tuple(command), "", "command timed out"
        )

    verdict = classify_exit(proc.returncode)
    # Digest only: raw stdout/stderr is discarded so a secret it may have printed
    # is never persisted.
    output_sha256 = sha256_hex(proc.stdout + proc.stderr)
    detail = f"exit {proc.returncode}"
    return Transcript(verdict, environment, tuple(command), output_sha256, detail)


def run_cell(
    command: Sequence[str],
    environment: Environment,
    *,
    unqualified: bool = False,
    max_attempts: int = 3,
    timeout: float = 120.0,
) -> CellResult:
    """Run one cell through the reproduction rule.

    An unqualified cell records BLOCKED before anything executes (never a pass,
    never silently skipped). Otherwise the command runs and the reproduction rule
    settles PASS/FAIL/BLOCKED/FLAKY.
    """
    if unqualified:
        blocked = Transcript(
            Verdict.BLOCKED,
            environment,
            tuple(command),
            "",
            "unqualified cell: not claimed",
        )
        return CellResult(Outcome.BLOCKED, (blocked,))

    result = reproduce(
        lambda attempt: _single_run(command, environment, attempt, timeout),
        max_attempts,
    )
    return CellResult(result.outcome, result.attempts)


def result_verdict(outcome: Outcome) -> str:
    """The RESULT-line verdict token for a settled outcome.

    ``FLAKY`` is reported red (``FAIL``): the attempts failed to establish a pass,
    and the escalation is carried by the outcome + exit code, never softened.
    """
    if outcome is Outcome.PASS:
        return Verdict.PASS.value
    if outcome is Outcome.BLOCKED:
        return Verdict.BLOCKED.value
    return Verdict.FAIL.value


def transcript_document(result: CellResult) -> dict:
    """Build the whitelisted transcript document (never a secret, never raw output).

    The environment identity and command line are recorded; observed output is a
    digest only; the process environment is never recorded.
    """
    attempts = []
    for t in result.attempts:
        env = t.environment
        attempts.append(
            {
                "verdict": t.verdict.value,
                "environment": {
                    "os": env.os,
                    "os_build": env.os_build,
                    "arch": env.arch,
                    "hypervisor": env.hypervisor,
                    "backend": env.backend,
                    "backend_version": env.backend_version,
                    "image": env.image,
                    "glibc_floor": env.glibc_floor,
                    "rev": env.rev,
                    "artifact_sha256": env.artifact_sha256,
                    "transcript_dir": env.transcript_dir,
                },
                "commands": list(t.commands),
                "output_sha256": t.output_sha256,
                "detail": t.detail,
            }
        )
    return {
        "schema_version": 1,
        "outcome": result.outcome.value,
        "attempts": attempts,
    }


def exit_code_for(outcome: Outcome) -> int:
    return {
        Outcome.PASS: EXIT_PASS,
        Outcome.FAIL: EXIT_FAIL,
        Outcome.BLOCKED: EXIT_BLOCKED,
        Outcome.FLAKY: EXIT_FLAKY,
    }[outcome]
