"""Applied-credential evidence: identity, per-service entries, and status (ADR-0053).

Pure data and validation, no I/O. Nothing here ever sees a credential value: an
identity names where a credential came from (source, scope, store authority,
opaque revision, ENV@HOST), never what it is.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import NamedTuple

from . import provider_creds, secret_revision

STATUSES = ("applied", "pending", "failed", "unknown")
SOURCES = ("sandbox", "global", "environment")

# The fixed endpoint tag of a built-in destination (github's table, the shipped
# usai anchor). Exact ENV@HOST is still captured beside it.
BUILTIN_ENDPOINT = "builtin-v1"

INSTANCE_PREFIX = "i"
ATTEMPT_PREFIX = "t"

_INSTANCE = re.compile(r"i:[0-9a-f]{32}")
_ATTEMPT = re.compile(r"t:[0-9a-f]{32}")
_REVISION_PART = r"r:[0-9a-f]{32}"
# One key's revision, or a value revision joined to a separate endpoint scope's.
_REVISION = re.compile(rf"{_REVISION_PART}(?:\+{_REVISION_PART})?")
_STATUS_AT = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
_NAME = re.compile(r"[A-Za-z0-9_-]+")
_ENTRY_KEYS = frozenset(
    {"source", "scope", "env", "host", "authority", "revision", "applied_revision", "attempt", "status", "status_at"}
)


class EffectiveIdentity(NamedTuple):
    """What the resolver says would be delivered now, without the value."""

    source: str
    scope: str | None
    env: str
    host: str
    authority: dict
    revision: str | None


def new_instance() -> str:
    return secret_revision.token(INSTANCE_PREFIX)


def new_attempt() -> str:
    return secret_revision.token(ATTEMPT_PREFIX)


def instance_ok(value: object) -> bool:
    return isinstance(value, str) and _INSTANCE.fullmatch(value) is not None


def utc_now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _endpoint_authority_ok(value: object) -> bool:
    return value is None or value == BUILTIN_ENDPOINT or (
        isinstance(value, dict) and secret_revision.authority_ok(value) and value["kind"] == "metadata"
    )


def _value_authority_ok(value: object) -> bool:
    return value is None or (
        isinstance(value, dict) and secret_revision.authority_ok(value) and value["kind"] in ("file", "dpapi")
    )


def authority_ok(value: object) -> bool:
    return (
        isinstance(value, dict) and set(value) == {"value", "endpoint"}
        and _value_authority_ok(value["value"]) and _endpoint_authority_ok(value["endpoint"])
    )


def _token_or_none(value: object, pattern: re.Pattern[str]) -> bool:
    return value is None or (isinstance(value, str) and pattern.fullmatch(value) is not None)


def entry_problem(entry: object) -> str | None:
    """Why ``entry`` is not a valid apply entry, or None. Never quotes its contents."""
    if not isinstance(entry, dict) or set(entry) != _ENTRY_KEYS:
        return "the apply entry does not have exactly the expected fields"
    if entry["status"] not in STATUSES or entry["source"] not in SOURCES:
        return "the apply entry has an unknown status or source"
    scoped = entry["source"] == "sandbox"
    if (scoped and not (isinstance(entry["scope"], str) and _NAME.fullmatch(entry["scope"]))) or (
        not scoped and entry["scope"] is not None
    ):
        return "the apply entry's scope does not match its source"
    if not (isinstance(entry["env"], str) and provider_creds.key_env_ok(entry["env"])
            and isinstance(entry["host"], str) and entry["host"]):
        return "the apply entry has an invalid endpoint"
    if not authority_ok(entry["authority"]):
        return "the apply entry has an invalid authority"
    if not (_token_or_none(entry["revision"], _REVISION) and _token_or_none(entry["applied_revision"], _REVISION)
            and isinstance(entry["attempt"], str) and _ATTEMPT.fullmatch(entry["attempt"])):
        return "the apply entry has an invalid token"
    if not (isinstance(entry["status_at"], str) and _STATUS_AT.fullmatch(entry["status_at"])):
        return "the apply entry has an invalid time"
    return _entry_consistency(entry)


def _entry_consistency(entry: dict) -> str | None:
    if entry["revision"] is not None and (
        entry["authority"]["value"] is None or entry["authority"]["endpoint"] is None
    ):
        return "a versioned apply entry must name its store authority"
    if entry["source"] == "environment" and (
        entry["revision"] is not None or entry["applied_revision"] is not None or entry["status"] != "unknown"
    ):
        return "an environment credential is never versioned or applied"
    if entry["status"] == "applied" and (entry["revision"] is None or entry["applied_revision"] != entry["revision"]):
        return "an applied entry must have delivered its own revision"
    if entry["status"] != "applied" and entry["applied_revision"] is not None:
        return "only an applied entry may carry an applied revision"
    return None


def apply_entry(identity: EffectiveIdentity, *, status: str, attempt: str | None = None) -> dict:
    """The entry for one attempt at delivering ``identity``.

    An identity with no usable revision (an environment source, a pending or
    unproven store) can only ever be ``unknown``.
    """
    if identity.revision is None:
        status = "unknown"
    return {
        "source": identity.source,
        "scope": identity.scope,
        "env": identity.env,
        "host": identity.host,
        "authority": identity.authority,
        "revision": identity.revision,
        "applied_revision": identity.revision if status == "applied" else None,
        "attempt": attempt or new_attempt(),
        "status": status,
        "status_at": utc_now(),
    }


def same_target(entry: dict, identity: EffectiveIdentity) -> bool:
    """Whether the entry's target is exactly what the resolver would deliver now."""
    return (
        entry["source"], entry["scope"], entry["env"], entry["host"], entry["authority"], entry["revision"]
    ) == tuple(identity)


def derive_status(entry: dict | None, current: EffectiveIdentity | None) -> str:
    """The status a consumer may rely on: evidence compared with the current store.

    Persisted ``applied`` survives only while the committed effective identity is
    unchanged; ``status_at`` plays no part.
    """
    if entry is None or current is None or entry["revision"] is None:
        return "unknown"
    if current.source == "environment" or current.revision is None:
        return "unknown"
    if not same_target(entry, current):
        return "pending"
    return entry["status"]


@dataclass(frozen=True)
class ServiceApply:
    """One service's current identity beside its persisted evidence."""

    service: str
    status: str
    current: EffectiveIdentity | None
    applied: dict | None


@dataclass(frozen=True)
class ApplySnapshot:
    """A validated, read-only view of one sandbox's credential application."""

    name: str
    instance: str | None
    services: dict[str, ServiceApply] = field(default_factory=dict)

    @property
    def reuse_eligible(self) -> bool:
        """Always False: older and Bash writers can change the shared store unversioned (ADR-0053)."""
        return False
