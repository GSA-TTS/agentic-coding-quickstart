"""Pure consumer of the guest preparation protocol, not a launch barrier.

The host establishes identity, trusted paths and bounded execution. These helpers
do no I/O and cannot authenticate guest output or authorize launch/reuse.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Literal

# Both the small success document and the producer's v1 failure fit this cap.
MAX_OUTPUT_BYTES = 1024
MetadataOutcome = Literal["not-requested", "unavailable", "available-unverified"]
_METADATA = ("not-requested", "unavailable", "available-unverified")
_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,255}")
_SHA256 = re.compile(r"[0-9a-f]{64}")
_FAILURES = frozenset({
    ("input", "invalid-input", "hard"),
    ("trust", "invalid-trust", "hard"),
    ("membership", "authentication", "hard"),
    ("membership", "response-identity", "hard"),
    ("membership", "tls", "hard"),
    ("membership", "http-refused", "hard"),
    ("membership", "invalid-response", "hard"),
    ("membership", "unknown", "hard"),
    ("membership", "provider-throttled", "transient"),
    ("membership", "provider-unavailable", "transient"),
    ("membership", "connection", "transient"),
    ("membership", "request-abort", "transient"),
    ("child", "child-protocol", "hard"),
    ("child", "child-crash", "hard"),
    ("preparation", "parent-deadline", "hard"),
    ("preparation", "lock", "hard"),
    ("preparation", "render", "hard"),
    ("preparation", "unknown", "hard"),
})


class PreparationError(ValueError):
    """Refusal with fixed or closed-enum diagnostics, never raw process output."""


@dataclass(frozen=True, slots=True)
class InvocationIdentity:
    """Host-established, non-secret identity; identifiers are opaque, not paths.

    The nonce must be new for each attempt. The generation must identify the exact
    immutable input, not a mutable alias. Shape checks do not establish either.
    """

    attempt_nonce: str
    sandbox_instance: str
    exact_generation: str
    routing_digest: str
    artifact_sha256: str
    base_config_sha256: str

    def __post_init__(self) -> None:
        for value in (self.attempt_nonce, self.sandbox_instance, self.exact_generation):
            if type(value) is not str or _IDENTIFIER.fullmatch(value) is None:
                raise PreparationError("invalid invocation identifier")
        for value in (self.routing_digest, self.artifact_sha256, self.base_config_sha256):
            if type(value) is not str or _SHA256.fullmatch(value) is None:
                raise PreparationError("invalid invocation digest")


@dataclass(frozen=True, slots=True)
class PreparationResult:
    """Ephemeral protocol evidence only; check current identity before consumption."""

    identity: InvocationIdentity
    metadata_outcome: MetadataOutcome
    source_outcome: Literal["live"] = "live"

    def __post_init__(self) -> None:
        _check_identity(self.identity)
        if type(self.source_outcome) is not str or self.source_outcome != "live":
            raise PreparationError("invalid preparation source outcome")
        if type(self.metadata_outcome) is not str or self.metadata_outcome not in _METADATA:
            raise PreparationError("invalid preparation metadata outcome")


def _check_identity(identity: InvocationIdentity) -> None:
    if type(identity) is not InvocationIdentity:
        raise PreparationError("invalid invocation identity")


def _guest_path(value: str) -> str:
    # Lexical validation only: no host stat/resolve of a guest namespace.
    if (type(value) is not str or not value or len(value) > 4096
            or not value.startswith("/") or value.startswith("//")
            or not value.isprintable() or "\\" in value):
        raise PreparationError("invalid guest path")
    path = PurePosixPath(value)
    if value == "/" or path.as_posix() != value or ".." in path.parts:
        raise PreparationError("invalid guest path")
    return value


def build_argv(*, node: str, artifact: str, provider_root: str,
               global_dir: str, base_config: str) -> tuple[str, ...]:
    """Fixed argv for trusted guest paths, never shell text or credential values.

    The host must verify path ownership, digests, mounts and absence of symlink
    substitution. This function neither locates Node nor reads any path.
    """
    return (
        _guest_path(node), _guest_path(artifact),
        "--provider-root", _guest_path(provider_root),
        "--global-dir", _guest_path(global_dir),
        "--base-config", _guest_path(base_config),
        "--mode", "live-required",
    )


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise PreparationError("invalid preparation protocol")
        result[key] = value
    return result


def _reject_constant(_value: str) -> object:
    raise PreparationError("invalid preparation protocol")


def _document(stdout: bytes) -> dict[str, str]:
    if type(stdout) is not bytes or not 0 < len(stdout) <= MAX_OUTPUT_BYTES:
        raise PreparationError("invalid preparation output bytes")
    try:
        value = json.loads(stdout.decode("utf-8", errors="strict"),
                           object_pairs_hook=_unique_object, parse_constant=_reject_constant)
    except (ValueError, RecursionError):
        raise PreparationError("invalid preparation protocol") from None
    if type(value) is not dict or any(type(item) is not str for item in value.values()):
        raise PreparationError("invalid preparation protocol")
    return value


def _failure_message(document: dict[str, str]) -> str:
    keys = {"schemaVersion", "outcome", "stage", "reason", "failureClass"}
    if (set(document) != keys
            or document["schemaVersion"] != "acq-runtime-model-outcome/v1"
            or document["outcome"] != "failure"):
        return "runtime preparation failed: invalid failure protocol"
    classification = (document["stage"], document["reason"], document["failureClass"])
    if classification not in _FAILURES:
        return "runtime preparation failed: invalid failure protocol"
    return "runtime preparation failed: " + "/".join(classification)


def parse_result(expected: InvocationIdentity, *, returncode: int,
                 stdout: bytes) -> PreparationResult:
    """Decode completed host-supervised execution; any nonzero exit refuses.

    The host must cap streams while collecting, enforce deadlines/cancellation,
    and await termination before calling. There is deliberately no stderr input.
    ``expected`` comes from that invocation, never from guest-supplied identity.
    """
    _check_identity(expected)
    if type(returncode) is not int:
        raise PreparationError("invalid preparation exit status")
    if returncode != 0:
        # Only exit 1 has the producer's typed failure protocol. Other exits,
        # including signals, never gain meaning from apparently valid output.
        if returncode != 1:
            raise PreparationError("runtime preparation failed: abnormal exit")
        raise PreparationError(_failure_message(_document(stdout)))
    document = _document(stdout)
    if set(document) != {"sourceOutcome", "metadataOutcome"}:
        raise PreparationError("invalid preparation success protocol")
    if document["sourceOutcome"] != "live":
        raise PreparationError("runtime preparation did not report live success")
    metadata = document["metadataOutcome"]
    # Narrow to Literal without trusting a cast or unvalidated JSON types.
    if metadata == "not-requested":
        return PreparationResult(expected, "not-requested")
    if metadata == "unavailable":
        return PreparationResult(expected, "unavailable")
    if metadata == "available-unverified":
        return PreparationResult(expected, "available-unverified")
    raise PreparationError("invalid preparation metadata outcome")


def require_current(result: PreparationResult,
                    current: InvocationIdentity) -> PreparationResult:
    """Refuse evidence from another attempt/instance/input before consumption.

    The host holds its lifecycle barrier across this comparison and use. This
    pure comparison cannot prevent a subsequent race or enforce single use.
    """
    _check_identity(current)
    if type(result) is not PreparationResult:
        raise PreparationError("invalid preparation result")
    if result.identity != current:
        raise PreparationError("preparation invocation identity changed")
    return result
