"""Structured-output envelope (ADR-0038m section 2).

Every explicitly-requested JSON result is a single document on stdout:

    success: {"schema_version", "command", "data"}
    failure: {"schema_version", "command", "error": {"code", "message", "remediation?"}}

``schema_version`` here is the result-schema version. It is distinct from the
state-schema version that durable records carry (ADR-0041m); the two never share
a number space. Unknown fields are additive; removing a required field or
changing its meaning/type bumps ``SCHEMA_VERSION``.
"""

from __future__ import annotations

SCHEMA_VERSION = 1


def success(command: str, data: dict) -> dict:
    """Build a success envelope: ``{schema_version, command, data}``."""
    return {
        "schema_version": SCHEMA_VERSION,
        "command": command,
        "data": data,
    }


def error(command: str, code: str, message: str, remediation: str | None = None) -> dict:
    """Build a failure envelope: ``{schema_version, command, error{...}}``.

    ``remediation`` is optional and, when present, is actionable prose for the
    user. No secret value or raw credential record ever appears here.
    """
    body: dict = {"code": code, "message": message}
    if remediation is not None:
        body["remediation"] = remediation
    return {
        "schema_version": SCHEMA_VERSION,
        "command": command,
        "error": body,
    }
