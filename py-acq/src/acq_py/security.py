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
via ``ACQ_SECURITY_MOUNT_STATE`` (an internal test seam, never a secret) and, when
the seam is absent, returns ``"unknown"`` — an *unconfirmed* guarantee. The gate
fails closed for anything that is not confirmed ``"ok"``, so a sandbox that
requires the mount is never trusted by default; the live slice replaces the seam
with the real probe and the consent-gated recreation remains the escape hatch.
"""

from __future__ import annotations

import json
import os

from . import errors

# Internal test seam: a JSON object mapping a sandbox name to a mount state
# ("ok" | "missing" | "unknown"), or a bare state string applied to every
# sandbox. Absent means "the live probe has not confirmed the guarantee" -> the
# gate fails closed with "unknown", never "ok" (ADR-0041m forward-only,
# fail-closed). It is never a secret and never written to output.
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
    single seam the live slice replaces. With the seam unset it returns
    ``"unknown"`` — never ``"ok"`` — so an unconfirmed guarantee fails closed.
    """
    raw = os.environ.get(MOUNT_STATE_ENV)
    if raw is None:
        return "unknown"  # the live probe has not confirmed the guarantee
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return "unknown"
    if isinstance(doc, str):
        return doc if doc in ("ok", "missing", "unknown") else "unknown"
    if isinstance(doc, dict):
        state = doc.get(name)
        return state if state in ("ok", "missing", "unknown") else "unknown"
    return "unknown"


def requires_ro_mount(record: dict | None) -> bool:
    """True when a record declares the read-only trusted-config mount (ADR-0035)."""
    return bool(record and record.get("ro_host_config"))


def assert_trusted(record: dict | None, backend: str, name: str) -> None:
    """Fail closed when a record-required read-only mount is not confirmed.

    A sandbox that never recorded the requirement takes the legacy path (no gate);
    a sandbox that recorded it must report a confirmed ``"ok"`` probe — anything
    else (``missing``, or an ``unknown``/unconfirmed probe) raises
    :class:`SecurityException` so the caller refuses the trusted operation.
    """
    if not requires_ro_mount(record):
        return
    state = mount_state(backend, name)
    if state == "ok":
        return
    raise SecurityException(
        errors.SECURITY_EXCEPTION,
        f"sandbox '{name}' is missing (or could not verify) the required "
        f"host-enforced read-only trusted-config mount (ADR-0035)",
        f"recreate it with 'acq create --recreate {name} --yes' — host records and "
        f"secrets are preserved, the guest filesystem is lost",
    )
