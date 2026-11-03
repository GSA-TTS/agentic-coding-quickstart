"""``acq doctor`` check assembly (ADR-0038m §doctor).

``doctor`` reports an overall ``status`` and a list of checks, each carrying a
stable ``id``, a per-check ``status``, a human ``message``, and an optional
``remediation``. The compatibility contract fixes the *shape* — overall status
plus per-check id/status/message/remediation, stable IDs, actionable
remediation — but not the concrete list of checks; that inventory grows as the
backend adapters land (ADR-0040m ``doctor``).

Status vocabulary (stable tokens):
    * per-check: ``ok`` / ``warn`` / ``fail``
    * overall:   ``ok`` (every check ok) / ``degraded`` (any warn) / ``failed``
      (any fail)

The foundation slice knows only two honest, offline checks: the managed runtime
(ADR-0042m) and backend-adapter availability (ADR-0040m). Both are deterministic
and never touch the network, so ``doctor`` is a safe diagnostic in any context.
"""

from __future__ import annotations

from . import runtime

OK = "ok"
WARN = "warn"
FAIL = "fail"

OVERALL_OK = "ok"
OVERALL_DEGRADED = "degraded"
OVERALL_FAILED = "failed"


def runtime_check() -> dict:
    """Report whether acq can resolve the runtime it executes subprocesses with.

    ``resolve_runtime`` never downloads and always returns a usable interpreter
    — the app-private managed bundle or the documented IT-approved base
    interpreter fallback — so this check is ``ok`` in both cases and records the
    supplier in the message (ADR-0042m).
    """
    rt = runtime.resolve_runtime()
    if rt.managed:
        message = f"app-private runtime present ({rt.supplier})"
    else:
        message = "using the IT-approved base interpreter (no app-private runtime bundle present)"
    return {"id": "runtime", "status": OK, "message": message}


def backend_check() -> dict:
    """Report backend-adapter availability.

    No adapter is present in this slice, so sandbox and backend commands are
    unavailable. That is a degraded (warn) condition, not a failure: ``acq``
    itself still runs. The ID is stable; a later adapter slice reuses it and
    reports the active backend instead.
    """
    return {
        "id": "backend",
        "status": WARN,
        "message": "no sandbox backend adapter is available",
        "remediation": "backend adapters ship in a later slice; sandbox commands are unavailable in this build",
    }


def doctor_checks() -> list[dict]:
    """Return the ordered check list for the current build."""
    return [runtime_check(), backend_check()]


def overall_status(checks: list[dict]) -> str:
    """Derive the overall status from per-check statuses.

    ``failed`` (any fail) outranks ``degraded`` (any warn) outranks ``ok``.
    """
    statuses = {check["status"] for check in checks}
    if FAIL in statuses:
        return OVERALL_FAILED
    if WARN in statuses:
        return OVERALL_DEGRADED
    return OVERALL_OK


def doctor_data() -> dict:
    """Assemble the ``doctor`` command's required result data (ADR-0038m)."""
    checks = doctor_checks()
    return {"status": overall_status(checks), "checks": checks}
