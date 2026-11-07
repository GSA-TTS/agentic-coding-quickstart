"""``provider-credential`` set/ls/rm, ``github-scope``, and ``usai-rotate-api-key``:
per-sandbox credential binding (ADR-0013). No credential value is ever echoed.
"""

from __future__ import annotations

import json
import os

from .. import envelope, errors, provider_creds, state
from . import common


def run_provider_credential_set(parsed, emit_json: bool, backend: str) -> int:
    """``acq provider-credential set PROVIDER KEY_ENV --host H[,H]`` (value on stdin).

    Validates the destination pin, reads the value on stdin only, forwards it to
    the backend on the child's stdin, and records the binding host-side. The
    success envelope carries only the binding fields (never a value).
    """
    adapter = common._adapter(backend)
    command = "provider-credential set"
    provider = parsed.provider
    key_env = parsed.key_env
    hosts = provider_creds.parse_hosts(parsed.host)
    if not hosts:
        return common._operational_failure(
            command,
            errors.VALIDATION_FAILED,
            "a --host is required",
            f"the host is the trust decision that lets acq send this credential to "
            f"a destination; usage: acq provider-credential set {provider} {key_env} --host models.example.gov",
            emit_json,
        )
    problem = provider_creds.validate_binding(provider, key_env, hosts)
    if problem is not None:
        return common._operational_failure(command, errors.VALIDATION_FAILED, problem, None, emit_json)
    value = common._read_secret_value()
    if not value.strip():
        return common._operational_failure(
            command,
            errors.VALIDATION_FAILED,
            "no credential value provided on stdin",
            "pipe the credential value on stdin, e.g. printf '%s' VALUE | acq provider-credential set PROVIDER KEY_ENV --host H",
            emit_json,
        )
    try:
        adapter.provider_credential_set(provider, key_env, hosts, value)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    try:
        provider_creds.set_binding(provider, key_env, hosts)
    except state.StateSchemaError as exc:
        # A newer/unknown-schema or unparseable binding record fails closed with
        # the ADR-0041m stable code rather than a raw traceback.
        return common._operational_failure(
            command,
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"remove or repair the unreadable provider-credential binding for '{provider}', then retry",
            emit_json,
        )
    data = {
        "provider": provider,
        "key_env": key_env,
        "hosts": hosts,
        "source_layer": provider_creds.CONFIG_LAYER,
    }
    if emit_json:
        print(json.dumps(envelope.success(command, data)))
    else:
        print(f"bound provider '{provider}' to ${key_env} for host(s) {', '.join(hosts)}.")
    return errors.EXIT_SUCCESS

def _print_provider_credential_ls_human(data: dict) -> None:
    bindings = data["bindings"]
    if not bindings:
        print("no provider-credential bindings")
        return
    for entry in bindings:
        hosts = ",".join(entry["hosts"]) if entry["hosts"] else "(none)"
        print(f"  {entry['provider']}  {entry['key_env']}  {hosts}  {entry['source_layer']}")

def run_provider_credential_ls(emit_json: bool) -> int:
    """``acq provider-credential ls`` — provider/key_env/hosts/source_layer, never a value.

    Reads host-authoritative binding records plus the per-invocation env layer. A
    malformed env-layer entry fails closed (validation_failed) rather than being
    silently dropped (ADR-0038m).
    """
    try:
        bindings = provider_creds.list_bindings()
    except ValueError as exc:
        return common._operational_failure(
            "provider-credential ls",
            errors.VALIDATION_FAILED,
            str(exc),
            "fix the malformed ACQ_PROVIDER_CREDENTIAL_BINDINGS entry and retry",
            emit_json,
        )
    data = {"bindings": bindings}
    if emit_json:
        print(json.dumps(envelope.success("provider-credential ls", data)))
    else:
        _print_provider_credential_ls_human(data)
    return errors.EXIT_SUCCESS

def run_provider_credential_rm(parsed, emit_json: bool) -> int:
    """``acq provider-credential rm PROVIDER`` — drop the host-side binding.

    Removing an absent binding fails closed with ``secret_missing`` (reused: the
    credential binding is missing, ADR-0040m). The value itself is a backend
    secret and is not touched here (matching the legacy split between the binding
    and the stored value).
    """
    provider = parsed.provider
    if not provider_creds.provider_id_ok(provider):
        return common._operational_failure(
            "provider-credential rm",
            errors.VALIDATION_FAILED,
            f"invalid provider id {provider!r}",
            None,
            emit_json,
        )
    try:
        removed = provider_creds.remove_binding(provider)
    except state.StateSchemaError as exc:
        # A newer/unknown-schema or unparseable binding record fails closed with
        # the ADR-0041m stable code rather than a raw traceback.
        return common._operational_failure(
            "provider-credential rm",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"remove or repair the unreadable provider-credential binding for '{provider}', then retry",
            emit_json,
        )
    if not removed:
        return common._operational_failure(
            "provider-credential rm",
            errors.SECRET_MISSING,
            f"no credential binding for provider '{provider}'",
            f"list bindings with 'acq provider-credential ls', or add one with 'acq provider-credential set {provider} KEY_ENV --host H'",
            emit_json,
        )
    data = {"provider": provider, "removed": True}
    if emit_json:
        print(json.dumps(envelope.success("provider-credential rm", data)))
    else:
        print(f"removed the '{provider}' binding.")
    return errors.EXIT_SUCCESS

def _github_scope_workspace(parsed, backend: str, emit_json: bool) -> tuple[str | None, int | None]:
    """Resolve the workspace for ``github-scope`` (PATH, else the recorded one)."""
    sandbox = parsed.sandbox
    if parsed.path:
        resolved = common._mount_workspace(backend, os.path.abspath(parsed.path))
        if not os.path.isdir(resolved):
            return None, common._operational_failure(
                "github-scope",
                errors.VALIDATION_FAILED,
                f"workspace path does not exist or is not a directory: {parsed.path}",
                "pass an existing workspace directory, or omit PATH to use the recorded sandbox workspace",
                emit_json,
            )
        return resolved, None
    try:
        record = state.record_read(backend, sandbox)
    except state.StateSchemaError as exc:
        return None, common._operational_failure(
            "github-scope",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or pass a workspace path explicitly",
            emit_json,
        )
    workspace = (record or {}).get("workspace")
    if not workspace:
        return None, common._operational_failure(
            "github-scope",
            errors.VALIDATION_FAILED,
            f"no workspace path was provided, and no workspace is recorded for sandbox '{sandbox}'",
            f"usage: acq github-scope {sandbox} /path/to/workspace",
            emit_json,
        )
    return workspace, None

def run_github_scope(parsed, emit_json: bool, backend: str) -> int:
    """``acq github-scope SANDBOX [PATH]`` — per-sandbox GitHub token scope.

    The token is read on stdin only and forwarded to the backend (bound to the
    sandbox, never global); the scope is recorded host-side (ADR-0013). The token
    never appears in output.
    """
    adapter = common._adapter(backend)
    sandbox = parsed.sandbox
    workspace, exit_code = _github_scope_workspace(parsed, backend, emit_json)
    if exit_code is not None:
        return exit_code
    value = common._read_secret_value()
    if not value.strip():
        return common._operational_failure(
            "github-scope",
            errors.VALIDATION_FAILED,
            "no GitHub token provided on stdin",
            "pipe the token on stdin, e.g. printf '%s' TOKEN | acq github-scope SANDBOX PATH",
            emit_json,
        )
    try:
        adapter.github_scope(sandbox, value)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("github-scope", exc.code, exc.message, exc.remediation, emit_json)
    provider_creds.github_scope_write(backend, sandbox, workspace)
    data = {"sandbox": sandbox, "backend": backend, "scoped": True}
    if emit_json:
        print(json.dumps(envelope.success("github-scope", data)))
    else:
        print(f"scoped a GitHub token to sandbox '{sandbox}' (workspace {workspace}).")
    return errors.EXIT_SUCCESS

def run_usai_rotate_api_key(emit_json: bool, backend: str) -> int:
    """``acq usai-rotate-api-key`` — rotate the stored USAi key (ADR-0012).

    Reads the new key on stdin only and forwards it to the backend on the child's
    stdin. The backend validates the new key before replacing the old one, so a
    failed rotation (provider_unreachable / provider_auth_failed) leaves the old
    key in place. The new key never appears in output.
    """
    adapter = common._adapter(backend)
    value = common._read_secret_value()
    if not value.strip():
        return common._operational_failure(
            "usai-rotate-api-key",
            errors.VALIDATION_FAILED,
            "no new USAi key provided on stdin",
            "pipe the new key on stdin, e.g. printf '%s' NEW_KEY | acq usai-rotate-api-key",
            emit_json,
        )
    try:
        adapter.rotate_key(value)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("usai-rotate-api-key", exc.code, exc.message, exc.remediation, emit_json)
    data = {
        "provider": provider_creds.USAI_PROVIDER_ID,
        "key_env": provider_creds.USAI_PROVIDER_KEY_ENV,
        "rotated": True,
    }
    if emit_json:
        print(json.dumps(envelope.success("usai-rotate-api-key", data)))
    else:
        print("rotated the USAi API key.")
    return errors.EXIT_SUCCESS
