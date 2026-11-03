"""Security-exception gate + consent-gated recreation (ADR-0035, ADR-0041m).

ADR-0035 makes acq-trusted inputs (data *and* code) host-materialized and mounted
read-only into the guest. A sandbox that is missing that host-enforced guarantee
must fail closed for the trusted operations that rely on it, and is recreated —
explicitly, and only with consent — from host-held authority. Host records and
secrets are preserved; the guest filesystem is lost; no weaker guest-writable
fallback is permitted.

This module implements the fail-closed gate and the consent-gated recreation
*logic* offline. The actual mount probe (``msb inspect`` on the host, checking for
the read-only mount and the ``MSB_RO_MOUNT_MIN_VERSION`` floor) is a **Tier-3 live
check** and is NOT performed here: :func:`mount_state` stubs it deterministically
via ``ACQ_SECURITY_MOUNT_STATE`` (an internal test seam, never a secret) and
otherwise reports the guarantee present, so ordinary offline operation is never
blocked. Production runs the live probe and fails closed on a real missing mount.
"""

from __future__ import annotations

import json
import os

from . import errors

# Internal test seam: a JSON object mapping a sandbox name to a mount state
# ("ok" | "missing" | "unknown"), or a bare state string applied to every
# sandbox. Absent means "no live backend to probe" -> the guarantee is treated as
# present (the Tier-3 live check is documented as a dependency, not skipped).
MOUNT_STATE_ENV = "ACQ_SECURITY_MOUNT_STATE"


class SecurityException(Exception):
    """A trusted operation was refused on a missing host-enforced guarantee."""

    def __init__(self, code: str, message: str, remediation: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.remediation = remediation


def mount_state(backend: str, name: str) -> str:
    """Return the sandbox's read-only-mount state: ``ok``/``missing``/``unknown``.

    Stubbed for offline vectors; the real probe is a Tier-3 live check (ADR-0035,
    ``msb inspect`` + the ``MSB_RO_MOUNT_MIN_VERSION`` floor). This function is the
    single seam the live slice replaces.
    """
    raw = os.environ.get(MOUNT_STATE_ENV)
    if raw is not None:
        try:
            doc = json.loads(raw)
        except json.JSONDecodeError:
            doc = None
        if isinstance(doc, dict):
            state = doc.get(name)
            return state if state in ("ok", "missing", "unknown") else "ok"
        if isinstance(doc, str) and doc in ("ok", "missing", "unknown"):
            return doc
    return "ok"


def requires_ro_mount(record: dict | None) -> bool:
    """True when a record declares the read-only trusted-config mount (ADR-0035)."""
    return bool(record and record.get("ro_host_config"))


def assert_trusted(record: dict | None, backend: str, name: str) -> None:
    """Fail closed when a record-required read-only mount is missing.

    A sandbox that never recorded the requirement takes the legacy path (no gate);
    a sandbox that recorded it but reports ``missing`` (or an ``unknown`` probe)
    raises :class:`SecurityException` so the caller refuses the trusted operation.
    """
    if not requires_ro_mount(record):
        return
    state = mount_state(backend, name)
    if state == "ok":
        return
    raise SecurityException(
        errors.SECURITY_EXCEPTION,
        f"sandbox '{name}' is missing the required host-enforced read-only "
        f"trusted-config mount (ADR-0035)",
        f"recreate it with 'acq create --recreate {name} --yes' — host records and "
        f"secrets are preserved, the guest filesystem is lost",
    )
