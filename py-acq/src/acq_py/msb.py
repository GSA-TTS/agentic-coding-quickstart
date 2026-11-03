"""MSB backend adapter — subprocess-calling lifecycle side (ADR-0040m).

The read side (detection + version floor) lives in ``backends.py``; this module
owns the mutating/lifecycle verbs the seam drives — ``create``, ``list``,
``exec`` (readiness probe + agent launch), ``stop``, and ``remove`` — by invoking
the ``msb`` CLI as a subprocess. The adapter reports outcomes and never decides
trust: sandbox identity, agent, and workspace authority stay host-side in the
seam (``cli.py`` + ``state.py``), per ADR-0040m §trust ownership.

The ``msb`` executable is overridable via ``ACQ_MSB_BIN`` for reproducible,
offline contract vectors. ``__stub__`` routes to the bundled deterministic fake
``acq_py._stub_msb``; any other value is parsed as a command line. This is an
internal test seam, never a secret, never written to acq output.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import sys

from . import errors

STUB_SENTINEL = "__stub__"

# Guest sizing defaults (ADR-0011): msb defaults a sandbox to 512 MiB / 1 vCPU
# with no swap, so acq requests a larger fixed default, tunable via env.
DEFAULT_MEMORY = "4G"
DEFAULT_CPUS = "2"

# Exec-ready gate budget (seconds): `msb create` returns 0 even on async boot
# failure, so readiness is proven by a successful `msb exec` (ADR-0011).
READY_TIMEOUT_S = float(os.environ.get("ACQ_MSB_READY_TIMEOUT", "30"))


class MsbError(Exception):
    """A backend-native failure the seam maps to a stable error code.

    ``remediation`` (when present) is stable acq-authored prose only. Raw backend
    stderr is never stored or surfaced: ADR-0040m makes raw backend text a
    non-portable field, and the envelope forbids it entirely.
    """

    def __init__(self, code: str, message: str, remediation: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.remediation = remediation


def msb_command() -> list[str]:
    """Resolve the msb CLI argv (an internal test seam; default ``msb``)."""
    override = os.environ.get("ACQ_MSB_BIN")
    if override == STUB_SENTINEL:
        return [sys.executable, "-m", "acq_py._stub_msb"]
    if override:
        return shlex.split(override)
    return ["msb"]


def _run(argv: list[str], *, timeout: float | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        [*msb_command(), *argv],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def list_names() -> list[str] | None:
    """Return sandbox names (one per line), or ``None`` if ``msb list`` failed."""
    proc = _run(["list", "-q"])
    if proc.returncode != 0:
        return None
    return [line for line in proc.stdout.splitlines() if line]


def running_names() -> list[str] | None:
    """Return running sandbox names, or ``None`` if ``msb list`` failed."""
    proc = _run(["list", "--running", "-q"])
    if proc.returncode != 0:
        return None
    return [line for line in proc.stdout.splitlines() if line]


def exists(name: str) -> bool:
    names = list_names()
    return names is not None and name in names


def create(name: str, image: str, workspace: str, memory: str | None = None, cpus: str | None = None) -> None:
    """Create a sandbox. Raises :class:`MsbError` on backend failure."""
    argv = [
        "create",
        "--name",
        name,
        "--image",
        image,
        "--volume",
        f"{workspace}:{workspace}",
    ]
    if memory:
        argv += ["--memory", memory]
    if cpus:
        argv += ["--cpus", cpus]
    proc = _run(argv)
    if proc.returncode != 0:
        # `failure` is the ADR-0038m usage/failure minimum's generic
        # operational-failure code (no ADR-0040m code describes a backend command
        # returning nonzero); the raw backend stderr is deliberately not surfaced.
        raise MsbError(
            errors.FAILURE,
            f"msb create failed for sandbox '{name}'",
            "check msb logs and retry",
        )


def exec_ready(name: str) -> bool:
    """True when ``msb exec NAME -- true`` succeeds (the exec-ready gate).

    A ``TimeoutExpired`` from the probe is treated as "not ready yet": the caller
    polls until its overall deadline and then surfaces the stable ``timeout``
    code, never a traceback.
    """
    try:
        proc = _run(["exec", name, "--", "true"], timeout=5)
    except subprocess.TimeoutExpired:
        return False
    return proc.returncode == 0


def stop(name: str) -> None:
    proc = _run(["stop", name])
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"msb stop failed for sandbox '{name}'",
            "check msb logs and retry",
        )


def remove(name: str) -> None:
    proc = _run(["remove", "--force", name])
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"msb remove failed for sandbox '{name}'",
            "check msb logs and retry",
        )


def launch(name: str, workspace: str | None, agent: str | None, *, json_mode: bool = False) -> int:
    """Launch the recorded agent (or a login shell) in the foreground.

    Runs as the unprivileged ``agent`` user in the recorded workspace (ADR-0011),
    with the child's exit status as this function's return value (child-status
    propagation, ADR-0038m §1). In ``json_mode`` the child's stdout is routed to
    stderr so the CLI's stdout stays a single JSON document (ADR-0038m §2); in
    interactive use stdio is inherited so the agent renders. Interactive PTY
    allocation and ssh-agent forwarding are the attach slice's concern.
    """
    argv = ["exec", "-u", "agent"]
    if workspace:
        argv += ["-w", workspace]
    if agent and agent != "shell":
        command = [agent]
    else:
        command = ["/bin/sh", "-l"]
    argv += [name, "--", *command]
    if json_mode:
        # In --json mode the launched child's stdout must not corrupt acq's
        # single-JSON-document stdout, so route it to stderr (fd 2). Passing the
        # fd directly keeps this working when ``sys.stderr`` has been replaced by
        # a harness object without a usable fileno().
        try:
            stdout: object = sys.stderr.fileno()
        except (AttributeError, OSError, ValueError):
            stdout = 2
    else:
        stdout = None
    return subprocess.run([*msb_command(), *argv], stdout=stdout).returncode
