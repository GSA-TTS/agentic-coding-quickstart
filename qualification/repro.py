"""The 3-attempt reproduction rule (ADR-0044m).

A ``FAIL`` is confirmed real only by reproducing on the same environment within
three attempts. The binding identity fields (``BINDING_FIELDS``) must match
across attempts; wall-clock time, the transcript directory, a nonce, and the
sandbox name may differ. A result that diverges across attempts — or whose
binding identity diverges — is escalated as ``FLAKY``, never softened, and never
reported as a definitive ``FAIL``.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from .model import BINDING_FIELDS, Outcome, Transcript, Verdict

# ``run_once`` performs one attempt and returns its transcript. The argument is
# the 1-based attempt number, so a fixture can branch deterministically.
RunOnce = Callable[[int], Transcript]

DEFAULT_ATTEMPTS = 3


@dataclass(frozen=True)
class ReproResult:
    """The settled outcome of a cell run plus every attempt's transcript."""

    outcome: Outcome
    attempts: tuple[Transcript, ...]


def _binding_identity(transcript: Transcript) -> tuple:
    env = transcript.environment
    return tuple(getattr(env, field) for field in BINDING_FIELDS)


def reproduce(run_once: RunOnce, max_attempts: int = DEFAULT_ATTEMPTS) -> ReproResult:
    """Run a cell up to ``max_attempts`` times and settle its final outcome.

    * ``PASS`` or ``BLOCKED`` on the first attempt is final (no reproduction).
    * ``FAIL`` is confirmed only when every attempt fails AND the binding
      identity is identical across attempts; otherwise it is escalated ``FLAKY``.
    * A single attempt (``max_attempts < 2``) cannot reproduce a ``FAIL``, so a
      one-off failure is escalated ``FLAKY`` rather than reported as definitive.
    """
    if max_attempts < 1:
        raise ValueError("max_attempts must be >= 1")

    first = run_once(1)
    attempts: list[Transcript] = [first]

    if first.verdict is Verdict.PASS:
        return ReproResult(Outcome.PASS, tuple(attempts))
    if first.verdict is Verdict.BLOCKED:
        return ReproResult(Outcome.BLOCKED, tuple(attempts))

    # first.verdict is FAIL: it must reproduce on the same environment.
    identity = _binding_identity(first)
    for attempt_number in range(2, max_attempts + 1):
        attempt = run_once(attempt_number)
        attempts.append(attempt)
        if attempt.verdict is not Verdict.FAIL:
            return ReproResult(Outcome.FLAKY, tuple(attempts))
        if _binding_identity(attempt) != identity:
            return ReproResult(Outcome.FLAKY, tuple(attempts))

    if len(attempts) < 2:
        # A lone FAIL with no reproduction evidence is not definitive.
        return ReproResult(Outcome.FLAKY, tuple(attempts))
    return ReproResult(Outcome.FAIL, tuple(attempts))
