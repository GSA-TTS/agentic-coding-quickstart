"""Value types for the qualification harness (ADR-0044m).

The ADR defines three things this module owns as data:

* the verbatim ``RESULT`` transcript signature line, whose verdict is one of
  ``PASS``/``FAIL``/``BLOCKED`` (never a secret, never a raw output dump);
* the environment identity a transcript records (OS build, arch, hypervisor,
  backend + version, glibc floor where relevant, commit SHA, artifact SHA-256);
* the *binding* identity fields that must match across reproduction attempts for
  a ``FAIL`` to be confirmed real.

A transcript never carries a secret: it records hashes, versions, and the command
line, plus a SHA-256 digest of observed output — never the raw output, never an
environment dump, never a credential.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from enum import Enum


class Verdict(str, Enum):
    """A single run's verdict — the only tokens the ADR permits on the ``RESULT`` line."""

    PASS = "PASS"
    FAIL = "FAIL"
    BLOCKED = "BLOCKED"


class Outcome(str, Enum):
    """The final disposition after the reproduction rule.

    ``FLAKY`` is the escalation of a ``FAIL`` that did not reproduce on the same
    environment within three attempts (ADR-0044m). It is never softened into a
    pass and never reported as a definitive ``FAIL``.
    """

    PASS = "PASS"
    FAIL = "FAIL"
    BLOCKED = "BLOCKED"
    FLAKY = "FLAKY"


# Identity fields that must match across reproduction attempts for a FAIL to be
# confirmed real (ADR-0044m). Wall-clock time, the transcript directory, a nonce,
# and the sandbox name may differ and are therefore not binding.
BINDING_FIELDS = (
    "rev",
    "artifact_sha256",
    "backend_version",
    "os_build",
    "hypervisor",
)


@dataclass(frozen=True)
class Environment:
    """Environment identity recorded by a transcript.

    ``os`` is the short OS name ("Linux", "Darwin", "Windows"); ``os_build`` is
    the fuller build/release string; ``host`` is the combined "<os> <arch>" token
    the ``RESULT`` line carries. ``glibc_floor`` is nullable and Linux-only.
    """

    os: str
    os_build: str
    arch: str
    hypervisor: str
    backend: str
    backend_version: str
    image: str
    rev: str
    artifact_sha256: str
    transcript_dir: str
    glibc_floor: str | None = None

    @property
    def host(self) -> str:
        """The "<os> <arch>" token the RESULT line emits as ``host=``."""
        return f"{self.os} {self.arch}"


@dataclass(frozen=True)
class Transcript:
    """One run's record: a verdict, the environment identity, the command line,
    and a SHA-256 digest of observed output (never the raw output).

    ``recorded_at`` is the UTC ISO 8601 time the run finished; staleness is judged
    from it (``matrix.is_current``). Empty means unknown, which is never current.
    """

    verdict: Verdict
    environment: Environment
    commands: tuple[str, ...]
    output_sha256: str
    detail: str = ""
    recorded_at: str = ""

    def result_line(self) -> str:
        return format_result_line(self.verdict.value, self.environment)


def sha256_hex(data: bytes) -> str:
    """Hex SHA-256 of ``data`` — the only form in which observed output is kept."""
    return hashlib.sha256(data).hexdigest()


def format_result_line(verdict: str, environment: Environment) -> str:
    """The canonical one-pasteable signature line (ADR-0044m).

    ``RESULT <PASS|FAIL|BLOCKED> <backend>=<ver> image=<image> host=<os arch>
    rev=<sha> dir=<abs path>`` — the backend token is ``msb=`` or ``sbx=``. The
    ``dir`` token is the transcript directory, or ``none`` when no evidence
    directory is written (offline harness self-test).
    """
    return (
        f"RESULT {verdict} {environment.backend}={environment.backend_version} "
        f"image={environment.image} host={environment.host} rev={environment.rev} "
        f"dir={environment.transcript_dir}"
    )


def classify_exit(returncode: int) -> Verdict:
    """Map a command's exit status to a verdict (mirrors ``qualify-msb-ro-mount``).

    Exit 0 -> PASS, exit 2 -> BLOCKED (the oracle could not run to a conclusion),
    any other exit -> FAIL (candidate, subject to the reproduction rule).
    """
    if returncode == 0:
        return Verdict.PASS
    if returncode == 2:
        return Verdict.BLOCKED
    return Verdict.FAIL
