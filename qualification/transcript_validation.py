"""Strict decoding of version-1 transcript evidence; no oracle execution."""

from datetime import datetime
import re

from .matrix import MSB, SBX
from .model import Environment, Transcript, Verdict
from .repro import reproduce

_REV = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
_SHA256 = re.compile(r"[0-9a-f]{64}")
_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def _fields(value, fields, where):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError(f"{where}: fields must be exactly {', '.join(sorted(fields))}")


def _string(value, where, *, empty=False):
    if not isinstance(value, str) or (not empty and not value):
        raise ValueError(f"{where}: must be {'a' if empty else 'a non-empty'} string")
    return value


def _timestamp(value, where):
    _string(value, where)
    if datetime.fromisoformat(value).tzinfo is None:
        raise ValueError(f"{where}: must have a timezone")


def _environment(doc, where):
    _fields(doc, Environment.__dataclass_fields__, where)
    for field, value in doc.items():
        if field == "glibc_floor" and value is None:
            continue
        _string(value, f"{where}.{field}", empty=field == "image")
    if not _REV.fullmatch(doc["rev"]) or set(doc["rev"]) == {"0"}:
        raise ValueError(f"{where}: rev must be a nonzero full commit id")
    if not _SHA256.fullmatch(doc["artifact_sha256"]):
        raise ValueError(f"{where}: artifact_sha256 must be 64 lowercase hex digits")
    if doc["backend"] not in (MSB, SBX) or not _VERSION.fullmatch(doc["backend_version"]):
        raise ValueError(f"{where}: invalid backend or backend_version")
    if doc["os"] not in ("Linux", "Darwin", "Windows"):
        raise ValueError(f"{where}: unknown OS")
    return Environment(**doc)


def _attempt(doc, index):
    where = f"attempts[{index}]"
    _fields(doc, Transcript.__dataclass_fields__, where)
    verdict = Verdict(doc["verdict"])
    env = _environment(doc["environment"], f"{where}.environment")
    commands = doc["commands"]
    if not isinstance(commands, list) or not commands:
        raise ValueError(f"{where}: commands must be a non-empty list")
    for command in commands:
        _string(command, f"{where}.commands")
    digest = _string(doc["output_sha256"], f"{where}.output_sha256", empty=True)
    if not _SHA256.fullmatch(digest) and not (digest == "" and verdict is Verdict.BLOCKED):
        raise ValueError(f"{where}: invalid output_sha256 (only BLOCKED may have no digest)")
    _string(doc["detail"], f"{where}.detail", empty=True)
    # Empty timestamps are the old runner's explicit unknown value. The recorder
    # may supply --recorded-at; a published block must still reconstruct unaided.
    _string(doc["recorded_at"], f"{where}.recorded_at", empty=True)
    if doc["recorded_at"]:
        _timestamp(doc["recorded_at"], f"{where}.recorded_at")
    return Transcript(verdict, env, tuple(commands), digest, doc["detail"], doc["recorded_at"])


def validated_attempts(doc):
    """Decode all attempts and verify the outcome with the existing reproduction rule.

    Binding divergence is valid FLAKY evidence, not a confirmed FAIL. Cross-cell
    attempts are not one run and are rejected regardless of the claimed outcome.
    The recorded length supplies the configurable budget absent from schema v1.
    """
    _fields(doc, ("schema_version", "outcome", "attempts"), "transcript")
    if type(doc["schema_version"]) is not int or doc["schema_version"] != 1:
        raise ValueError("transcript: schema_version must be integer 1")
    if not isinstance(doc["attempts"], list) or not doc["attempts"]:
        raise ValueError("transcript: attempts must be a non-empty list")
    attempts = tuple(_attempt(a, i) for i, a in enumerate(doc["attempts"]))
    first = attempts[0].environment
    for attempt in attempts[1:]:
        env = attempt.environment
        if (env.backend, env.os, env.arch) != (first.backend, first.os, first.arch):
            raise ValueError("transcript: attempts must identify the same backend/OS/architecture")
    result = reproduce(lambda number: attempts[number - 1], max_attempts=len(attempts))
    if len(result.attempts) != len(attempts):
        raise ValueError("transcript: attempts continue after the reproduction rule settled")
    if doc["outcome"] != result.outcome.value:
        raise ValueError(f"transcript: outcome must be derived as {result.outcome.value}")
    return attempts, result.outcome.value
