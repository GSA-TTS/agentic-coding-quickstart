"""``secret set``/``rm``/``ls``/``has``.

The value arrives on stdin only and never appears in argv or in output.
"""

from __future__ import annotations

import json
import sys

from .. import envelope, errors, msb, sbx
from . import common


def run_secret_set(parsed, emit_json: bool, backend: str) -> int:
    """``acq secret set (-g | SANDBOX) SERVICE`` — value read from stdin only.

    The value is forwarded to the backend on its stdin (never argv) and is never
    echoed; the success envelope carries only scope/service/value_state.
    """
    adapter = common._adapter(backend)
    scope, service = common._parse_secret_scope_service(parsed.global_scope, parsed.args)
    if scope is None or service is None:
        return common._usage_failure("secret set", "usage: acq secret set [-g | SANDBOX] SERVICE (value on stdin)", emit_json)
    value = common._read_secret_value()
    if not value.strip():
        # Empty (or whitespace-only) stdin is a validation failure (exit 1), not a
        # usage error (exit 2): the invocation was well-formed but supplied no
        # storable value (ADR-0038m §1 "validation" class).
        return common._operational_failure(
            "secret set",
            errors.VALIDATION_FAILED,
            "no secret value provided on stdin",
            "pipe the secret value on stdin, e.g. printf '%s' VALUE | acq secret set -g SERVICE",
            emit_json,
        )
    try:
        adapter.secret_set(scope, service, value)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("secret set", exc.code, exc.message, exc.remediation, emit_json)
    data = {"scope": scope, "service": service, "value_state": "set"}
    if emit_json:
        print(json.dumps(envelope.success("secret set", data)))
    else:
        print(f"stored secret '{service}' (scope {scope})")
    return errors.EXIT_SUCCESS


def run_secret_rm_raw(placeholder: str, emit_json: bool) -> int:
    """sbx-only raw-placeholder removal (ADR-0038m §48).

    Removes a raw placeholder from sbx's proxy table; the acq store is left
    unchanged (never rewrites host-held records). The placeholder is never a
    secret value.
    """
    try:
        sbx.secret_rm_raw(placeholder)
    except sbx.SbxError as exc:
        return common._operational_failure("secret rm", exc.code, exc.message, exc.remediation, emit_json)
    data = {"placeholder": placeholder, "value_state": "unset"}
    if emit_json:
        print(json.dumps(envelope.success("secret rm", data)))
    else:
        print(f"removed raw placeholder '{placeholder}'.")
    return errors.EXIT_SUCCESS


def run_secret_rm(parsed, emit_json: bool, backend: str) -> int:
    """``acq secret rm (-g | SANDBOX) SERVICE`` — remove a secret.

    An absent secret fails closed with ``secret_missing`` (ADR-0040m); a backend
    that cannot answer fails closed with its own accurate code (``backend_not_found``
    / ``failure``) and never deletes. On sbx, a single bare token that is not a
    managed scope+service is a raw placeholder to remove from the proxy table
    (ADR-0038m §48) and leaves the acq store unchanged.
    """
    adapter = common._adapter(backend)
    scope, service = common._parse_secret_scope_service(parsed.global_scope, parsed.args)
    if scope is None or service is None:
        # sbx raw-placeholder removal: a single bare token (no scope, no second
        # positional) is a raw placeholder for sbx's own `secret` CLI.
        if backend == "sbx" and not parsed.global_scope and len(parsed.args) == 1 and not parsed.args[0].startswith("-"):
            return run_secret_rm_raw(parsed.args[0], emit_json)
        return common._usage_failure("secret rm", "usage: acq secret rm [-g | SANDBOX] SERVICE", emit_json)
    try:
        present = adapter.key_present(scope, service) if backend == "sbx" else adapter.secret_has(scope, service)
    except common._ADAPTER_ERRORS as exc:
        # A backend that cannot answer is NOT "absent": fail closed with the
        # accurate code (backend_not_found / failure), never secret_missing, and
        # never delete.
        return common._operational_failure("secret rm", exc.code, exc.message, exc.remediation, emit_json)
    if not present:
        return common._operational_failure(
            "secret rm",
            errors.SECRET_MISSING,
            f"no secret '{service}' for scope '{scope}'",
            f"store one with 'acq secret set -g {service}' (or scoped to a sandbox)",
            emit_json,
        )
    try:
        adapter.secret_rm(scope, service)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("secret rm", exc.code, exc.message, exc.remediation, emit_json)
    data = {"scope": scope, "service": service, "value_state": "unset"}
    if emit_json:
        print(json.dumps(envelope.success("secret rm", data)))
    else:
        print(f"removed secret '{service}' (scope {scope})")
    return errors.EXIT_SUCCESS


def _print_secret_ls_human(data: dict) -> None:
    secrets = data["secrets"]
    if not secrets:
        print("no secrets")
        return
    for entry in secrets:
        print(f"  {entry['scope']}  {entry['service']}  {entry['value_state']}")


def run_secret_ls(parsed, emit_json: bool, backend: str) -> int:
    """``acq secret ls [(-g | SANDBOX)]`` — scope/service/value_state, never a value.

    An unreadable or unparseable backend listing fails closed with
    ``secret_unreadable`` (ADR-0040m) rather than being reported as empty.
    ``secret ls`` realizes the ``secret-list`` obligation: supported on sbx
    (``sbx secret ls``), unsupported on msb (no ``secret`` subcommand), where it
    fails closed with ``unsupported_capability``.
    """
    if not common._supports(backend, "secret-list"):
        return common._operational_failure(
            "secret ls",
            errors.UNSUPPORTED,
            f"secret listing is not supported on the {backend} backend",
            "sbx exposes 'sbx secret ls'; msb has no standalone secret store",
            emit_json,
        )
    scope, ok = common._parse_secret_ls_scope(parsed.global_scope, parsed.args)
    if not ok:
        return common._usage_failure("secret ls", "usage: acq secret ls [-g | SANDBOX]", emit_json)
    try:
        secrets = common._adapter(backend).secret_ls(scope)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("secret ls", exc.code, exc.message, exc.remediation, emit_json)
    data = {"secrets": secrets}
    if emit_json:
        print(json.dumps(envelope.success("secret ls", data)))
    else:
        _print_secret_ls_human(data)
    return errors.EXIT_SUCCESS


def run_secret_has(parsed, backend_override: str | None) -> int:
    """``acq secret has (-g | SANDBOX) SERVICE`` — silent predicate (ADR-0038m).

    Exit 0 (present), 1 (absent or fail-closed), 2 (usage). ``--json`` is inert:
    there is never a stdout body — the answer is the exit status alone, and
    failures are stderr diagnostics (so ``emit_json`` is deliberately not honored).
    On sbx the presence predicate is the sbx-only ``key_present`` obligation; on
    msb it is the thin ``secret has`` predicate over the secret-list capability.
    """
    scope, service = common._parse_secret_scope_service(parsed.global_scope, parsed.args)
    if scope is None or service is None:
        return common._usage_failure("secret has", "usage: acq secret has [-g | SANDBOX] SERVICE", False)
    backend, exit_code = common._resolve_backend_for_mutation(
        backend_override, False, "secret has", domain="secret management"
    )
    if exit_code is not None:
        # The resolver already wrote a stderr diagnostic (no backend, or version
        # floor): exit 1/2 with stdout still silent, so "cannot check" is never a
        # silent false "absent".
        return exit_code
    try:
        if backend == "sbx":
            present = sbx.key_present(scope, service)
        else:
            present = msb.secret_has(scope, service)
    except common._ADAPTER_ERRORS as exc:
        # Backend error at query time: keep stdout silent and exit 1, but announce
        # on stderr so a scripter can tell "absent" from "could not check".
        print(f"acq: {exc.message}", file=sys.stderr)
        if exc.remediation:
            print(exc.remediation, file=sys.stderr)
        return errors.EXIT_FAILURE
    return errors.EXIT_SUCCESS if present else errors.EXIT_FAILURE
