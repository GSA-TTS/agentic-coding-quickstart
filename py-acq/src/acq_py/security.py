"""Security-exception gate + consent-gated recreation (ADR-0035, ADR-0041m).

ADR-0035 makes acq-trusted inputs (data *and* code) host-materialized and mounted
read-only into the guest. A sandbox that is missing that host-enforced guarantee
must fail closed for the trusted operations that rely on it, and is recreated —
explicitly, and only with consent — from host-held authority. Host records and
secrets are preserved; the guest filesystem is lost; no weaker guest-writable
fallback is permitted.

On msb the guarantee is the sandbox's host-config directory, mounted read-only
at :data:`HOST_CONFIG_GUEST_DIR` when the sandbox is created
(:func:`ro_mount_supported` decides whether acq asks for it). :func:`probe_mount`
is the real check, the same one Bash runs (``_acq_msb_host_config_mount_available``):

1. msb is a final release at or above :data:`RO_MOUNT_MIN_VERSION`, on a
   platform whose msb filesystem backend was reviewed (not Windows);
2. ``msb inspect`` (read on the host, which a guest cannot forge) records the
   mount as the one read-only Bind of this sandbox's host-config directory;
3. a guest probe does not contradict it: a write attempted as guest root must
   fail. The probe can only make acq stricter (a guest root controls the tools
   it runs, so its "denied" answer proves nothing on its own).

The read-only guarantee is msb-only; sbx sandboxes never record it.

``ACQ_SECURITY_MOUNT_STATE`` is a test seam: it is honoured only while the
backend's ``ACQ_*_BIN`` is the bundled ``__stub__``, like the other stub seams
(``backends.py``), so an exported value can never mark a real sandbox trusted.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from . import backends, errors, lock, msb

# Test seam: a JSON object mapping a sandbox name to a mount state
# ("ok" | "missing" | "unknown"), or a bare state string applied to every
# sandbox. Honoured only with the stub backend (see the module docstring).
MOUNT_STATE_ENV = "ACQ_SECURITY_MOUNT_STATE"

# The msb release from which acq relies on a read-only mount (Bash
# MSB_RO_MOUNT_MIN_VERSION, ADR-0035).
RO_MOUNT_MIN_VERSION = backends.Version(0, 7, 7, True)

# Where the host-config directory appears in the guest (Bash ACQ_HOST_CONFIG_GUEST_DIR).
HOST_CONFIG_GUEST_DIR = "/var/lib/acq/host"

_STATES = ("ok", "missing", "unknown")


class SecurityException(Exception):
    """A trusted operation was refused on a missing host-enforced guarantee."""

    def __init__(self, code: str, message: str, remediation: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.remediation = remediation


def host_config_dir(name: str) -> Path:
    """The msb sandbox's host-config directory, at the path Bash uses (``acq_host_config_dir``)."""
    return lock.bash_provenance_dir() / "msb" / f"{lock.bash_sandbox_key(name)}.config"


def ro_mount_version_problem() -> str | None:
    """Why acq cannot rely on a read-only mount with the installed msb, or ``None``."""
    if os.name == "nt":
        return "this platform's msb filesystem backend was not reviewed for read-only enforcement"
    status = backends.detect(backends.BACKENDS["msb"])
    parsed = status.parsed
    if parsed is None or not parsed.final or not backends.version_ge(parsed, RO_MOUNT_MIN_VERSION):
        found = status.version or "<unknown version>"
        return (f"msb {found} is below acq's minimum ({RO_MOUNT_MIN_VERSION.string}) for relying on a "
                "read-only mount, or its version could not be read as a final release")
    return None


def ro_mount_supported() -> bool:
    """True when acq creates msb sandboxes with the read-only host-config mount."""
    return ro_mount_version_problem() is None


def probe_mount(name: str) -> tuple[str, str]:
    """The real read-only-mount check for an msb sandbox: ``(state, reason)``.

    ``state`` is ``ok`` (reason ``""``), ``missing`` (msb's record or the guest
    contradicts the guarantee) or ``unknown`` (it could not be confirmed).
    """
    problem = ro_mount_version_problem()
    if problem is not None:
        return "unknown", problem
    hcfg = host_config_dir(name)
    state, reason = msb.ro_mount_recorded(name, HOST_CONFIG_GUEST_DIR, [str(hcfg), os.path.realpath(hcfg)])
    if state != "ok":
        return state, reason
    probe = msb.ro_mount_guest_probe(name, HOST_CONFIG_GUEST_DIR)
    if probe == 2:
        return "missing", "the host-config mount looks WRITABLE from the guest"
    if probe != 0:
        return "unknown", "the guest probe did not confirm the host-config mount"
    return "ok", ""


def _seam_state(backend: str, name: str) -> str | None:
    """The stub-only seam's state for ``name``, or ``None`` when it does not apply."""
    raw = os.environ.get(MOUNT_STATE_ENV)
    if raw is None or os.environ.get(f"ACQ_{backend.upper()}_BIN") != msb.STUB_SENTINEL:
        return None
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return "unknown"
    state = doc.get(name) if isinstance(doc, dict) else doc
    return state if state in _STATES else "unknown"


def mount_check(backend: str, name: str) -> tuple[str, str]:
    """``(state, reason)`` for the sandbox's read-only mount; only ``ok`` is trusted."""
    seam = _seam_state(backend, name)
    if seam is not None:
        return seam, "" if seam == "ok" else f"the test seam reports '{seam}'"
    if backend != "msb":
        return "unknown", "the read-only trusted-config mount is an msb-only guarantee"
    try:
        return probe_mount(name)
    except msb.MsbError as exc:
        return "unknown", exc.message


def mount_state(backend: str, name: str) -> str:
    """Return the sandbox's read-only-mount state: ``ok``/``missing``/``unknown``."""
    return mount_check(backend, name)[0]


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
    state, reason = mount_check(backend, name)
    if state == "ok":
        return
    detail = f": {reason}" if reason else ""
    remediation = (
        f"recreate it with 'acq create --recreate {name} --yes' — host records and "
        f"secrets are preserved, the guest filesystem is lost"
    )
    if backend == "msb" and os.name != "nt" and ro_mount_version_problem() is not None:
        remediation = f"upgrade msb to {RO_MOUNT_MIN_VERSION.string} or newer, then {remediation}"
    raise SecurityException(
        errors.SECURITY_EXCEPTION,
        f"sandbox '{name}' is missing (or could not verify) the required "
        f"host-enforced read-only trusted-config mount (ADR-0035){detail}",
        remediation,
    )
