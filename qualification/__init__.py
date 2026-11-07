"""Qualification harness for the Python acq v1 replacement (ADR-0044m).

Tier-3 transcript tooling, not CLI code: it emits the verbatim ``RESULT``
signature line, reports the qualified/unqualified/blocked matrix honestly, and
enforces the 3-attempt reproduction rule for a ``FAIL``. The live Tier-3 run is
a downstream consumer; this package builds the tooling and makes it testable
offline against a fake backend.

Run ``python -m qualification --help`` for the CLI surface.

No secret value ever appears in a transcript, the harness, or its fixtures: a
transcript records hashes, versions, and the command line, plus a SHA-256 digest
of observed output — never raw output, never an environment dump, never a
credential.
"""

from __future__ import annotations

from .matrix import (
    MAX_AGE_DAYS,
    TIER3_SURFACE,
    MatrixState,
    cell_state,
    is_claimed,
    is_current,
    report_matrix,
    touches_surface,
)
from .model import (
    BINDING_FIELDS,
    Environment,
    Outcome,
    Transcript,
    Verdict,
    classify_exit,
    format_result_line,
    sha256_hex,
)
from .repro import ReproResult, reproduce
from .runner import (
    EXIT_BLOCKED,
    EXIT_FAIL,
    EXIT_FLAKY,
    EXIT_PASS,
    CellResult,
    exit_code_for,
    result_verdict,
    run_cell,
    transcript_document,
)

__version__ = "0.1.0"

__all__ = [
    "BINDING_FIELDS",
    "CellResult",
    "Environment",
    "EXIT_BLOCKED",
    "EXIT_FAIL",
    "EXIT_FLAKY",
    "EXIT_PASS",
    "MAX_AGE_DAYS",
    "MatrixState",
    "Outcome",
    "ReproResult",
    "Transcript",
    "TIER3_SURFACE",
    "Verdict",
    "cell_state",
    "classify_exit",
    "exit_code_for",
    "format_result_line",
    "is_claimed",
    "is_current",
    "report_matrix",
    "reproduce",
    "result_verdict",
    "run_cell",
    "sha256_hex",
    "touches_surface",
    "transcript_document",
]
