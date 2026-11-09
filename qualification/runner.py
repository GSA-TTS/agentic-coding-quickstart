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
import signal
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Sequence

from .model import (
    TRANSCRIPT_DIR_TOKEN,
    Environment,
    Outcome,
    Transcript,
    Verdict,
    classify_exit,
    publishable_argv,
    sha256_hex,
)
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

# A command that outlives its timeout is asked to stop (SIGTERM; CTRL_BREAK on
# Windows) and given this long to tear down (at most a quarter of the timeout)
# before it is killed. The deadline exported to it under ``DEADLINE_ENV`` (epoch
# seconds) ends that long before the timeout, so a well-behaved oracle stops on
# its own and tears down while the harness is still waiting.
TERMINATE_GRACE = 300.0
DEADLINE_ENV = "ACQ_QUALIFY_DEADLINE"
# After the command is killed, how long to wait for its pipes to close: a process
# it started and that outlived it can hold them open indefinitely.
REAP_TIMEOUT = 5.0


def _grace(timeout: float) -> float:
    return min(TERMINATE_GRACE, timeout / 4)


def _stop(proc: subprocess.Popen, grace: float, *, ask: bool = True) -> None:
    """Ask ``proc`` to stop (unless ``ask`` is false), wait ``grace`` seconds, then kill it."""
    try:
        if ask:
            proc.send_signal(signal.CTRL_BREAK_EVENT if os.name == "nt" else signal.SIGTERM)
        proc.communicate(timeout=grace)
    except (subprocess.TimeoutExpired, OSError):
        proc.kill()
        _reap(proc, min(REAP_TIMEOUT, grace))


def _reap(proc: subprocess.Popen, timeout: float) -> None:
    """Wait at most ``timeout`` seconds for a killed ``proc``, then close its pipes."""
    try:
        proc.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, OSError, ValueError):
        pass
    for pipe in (proc.stdout, proc.stderr):
        if pipe is not None:
            try:
                pipe.close()
            except OSError:
                pass
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        pass


def _now() -> str:
    """The current UTC time as ISO 8601 (the transcript's ``recorded_at``)."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


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
            Verdict.BLOCKED, environment, (), "", "no command supplied", _now()
        )
    grace = _grace(timeout)
    child_env = dict(os.environ)
    child_env[ATTEMPT_ENV] = str(attempt)
    child_env[DEADLINE_ENV] = str(int(time.time() + timeout - grace))
    # Its own process group on Windows, so CTRL_BREAK reaches only the command.
    flags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    try:
        proc = subprocess.Popen(
            list(command), env=child_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=flags
        )
    except FileNotFoundError:
        return Transcript(
            Verdict.BLOCKED, environment, tuple(command), "", "command not found", _now()
        )
    except OSError:
        return Transcript(
            Verdict.BLOCKED, environment, tuple(command), "", "command could not start", _now()
        )
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _stop(proc, grace)
        return Transcript(
            Verdict.BLOCKED, environment, tuple(command), "", "command timed out", _now()
        )
    except KeyboardInterrupt:
        # On Windows the command runs in its own process group and never sees the
        # operator's Ctrl+C, so pass the stop on. On POSIX it shares the terminal's
        # process group and already has the SIGINT; a second signal would interrupt
        # its orderly stop. Either way, let it tear down before giving up.
        _stop(proc, grace, ask=os.name == "nt")
        raise

    verdict = classify_exit(proc.returncode)
    # Digest only: raw stdout/stderr is discarded so a secret it may have printed
    # is never persisted.
    output_sha256 = sha256_hex(stdout + stderr)
    detail = f"exit {proc.returncode}"
    return Transcript(verdict, environment, tuple(command), output_sha256, detail, _now())


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
            _now(),
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
    digest only; the process environment is never recorded. No host-local path is
    recorded either: the transcript directory becomes ``TRANSCRIPT_DIR_TOKEN`` and
    an absolute command-line path keeps only its final component
    (:func:`qualification.model.publishable_argv`), so the document can be published
    verbatim. Write it with :func:`qualification.model.canonical_transcript_bytes`.
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
                    "transcript_dir": (
                        env.transcript_dir if env.transcript_dir == "none" else TRANSCRIPT_DIR_TOKEN
                    ),
                },
                "commands": publishable_argv(t.commands),
                "output_sha256": t.output_sha256,
                "detail": t.detail,
                "recorded_at": t.recorded_at,
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
