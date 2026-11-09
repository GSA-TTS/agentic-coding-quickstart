"""``provider-credential`` set/ls/rm, ``github-scope``, and ``usai-rotate-api-key``:
per-sandbox credential binding (ADR-0013). No credential value is ever echoed.
"""

from __future__ import annotations

import hmac
import json
import os
import sys

from .. import envelope, errors, gitrepos, hostexec, provider_creds, secretstore, state
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
    # The binding is written before the value moves (plan default: binding
    # first), so an unreadable or newer-schema record, or a state directory
    # acq cannot write, fails closed with nothing stored in the backend. If the
    # backend then refuses before storing the value, the record is put back
    # exactly as it was; once the value is stored it keeps the new pin, which
    # is what re-feeding and removing it resolve against.
    try:
        snapshot = provider_creds.binding_snapshot(provider)
        provider_creds.set_binding(provider, key_env, hosts)
    except state.StateSchemaError as exc:
        # A newer/unknown-schema or unparseable binding record fails closed with
        # the ADR-0041m stable code rather than a raw traceback.
        return common._operational_failure(
            command,
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"remove or repair the unreadable provider-credential binding for '{provider}', then retry; "
            "nothing was stored",
            emit_json,
        )
    except OSError as exc:
        return common._operational_failure(
            command,
            errors.FAILURE,
            f"could not record the '{provider}' binding: {exc.strerror or exc}",
            "check that the acq state directory is writable, then retry; nothing was stored",
            emit_json,
        )
    try:
        adapter.provider_credential_set(provider, key_env, hosts, value)
    except common._ADAPTER_ERRORS as exc:
        stored = _value_stored(provider, value)
        value = ""
        if stored:
            return common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
        return _set_failed(command, provider, snapshot, exc, emit_json)
    value = ""
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


def _value_stored(provider: str, value: str) -> bool:
    """Whether the acq store now holds ``value`` as ``provider``'s global credential.

    A store that cannot be read counts as stored, so the new pin is kept rather
    than pointing a possibly-stored value back at the old destination.
    """
    try:
        current = secretstore.get(secretstore.key_for(provider))
    except (*common._ADAPTER_ERRORS, OSError):
        return True
    return current is not None and hmac.compare_digest(current.encode("utf-8"), value.encode("utf-8"))


def _set_failed(command: str, provider: str, snapshot: bytes | None, exc, emit_json: bool) -> int:
    """Report a backend refusal after putting the binding record back."""
    try:
        provider_creds.restore_binding(provider, snapshot)
    except OSError as restore_exc:
        return common._operational_failure(
            command,
            exc.code,
            f"{exc.message}; the new '{provider}' binding could not be rolled back "
            f"({restore_exc.strerror or restore_exc})",
            f"check it with 'acq provider-credential ls' and fix or remove it; {exc.remediation or 'then retry'}",
            emit_json,
        )
    return common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)


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


def _rm_credential_backend(backend_override: str | None, in_store: bool, emit_json: bool):
    """``(backend or None, exit code or None)`` for removing a provider's credential.

    With no stored value and no backend detected there is nothing acq could
    reach, so no backend is needed. Otherwise the usual mutation resolver runs
    (version floor included), and fails closed when no backend is available to
    unbind a stored value from.
    """
    if not in_store and backend_override is None and common._resolve_active_backend(None) is None:
        return None, None
    return common._resolve_backend_for_mutation(
        backend_override, emit_json, "provider-credential rm", domain="provider credentials"
    )


def _remove_credential(provider: str, backend_override: str | None, emit_json: bool) -> tuple[bool, int | None]:
    """Unbind and delete ``provider``'s global credential, as ``secret rm -g`` does.

    Runs while the binding still exists, because the backend resolves where the
    credential is bound from it. Returns ``(removed, exit code or None)``.
    """
    command = "provider-credential rm"
    kept = f"; the '{provider}' binding was kept, so the removal can be retried"
    try:
        in_store = secretstore.exists(provider, None)
    except common._ADAPTER_ERRORS as exc:
        return False, common._operational_failure(command, exc.code, exc.message + kept, exc.remediation, emit_json)
    backend, exit_code = _rm_credential_backend(backend_override, in_store, emit_json)
    if exit_code is not None or backend is None:
        return False, exit_code
    if not common._supports(backend, "secret-rm"):
        if not in_store:
            return False, None
        return False, common._operational_failure(
            command,
            errors.UNSUPPORTED,
            f"the {backend} backend cannot unbind the stored '{provider}' credential" + kept,
            "nothing was changed",
            emit_json,
        )
    adapter = common._adapter(backend)
    present_fn = getattr(adapter, "secret_present", None)
    try:
        in_backend = present_fn(secretstore.GLOBAL, provider) if present_fn is not None else None
        if not in_store and not in_backend:
            return False, None
        if in_backend is not False:
            adapter.secret_unbind(secretstore.GLOBAL, provider)
        secretstore.delete(secretstore.key_for(provider))
        secretstore.meta_delete(provider, None)
    except common._ADAPTER_ERRORS as exc:
        return False, common._operational_failure(command, exc.code, exc.message + kept, exc.remediation, emit_json)
    return True, None


def run_provider_credential_rm(parsed, emit_json: bool, backend_override: str | None = None) -> int:
    """``acq provider-credential rm PROVIDER`` — drop the binding and its credential.

    Removing an absent binding fails closed with ``secret_missing`` (reused: the
    credential binding is missing, ADR-0040m). The provider's stored global
    credential is unbound from the sandboxes that hold it and deleted first,
    exactly as ``acq secret rm -g PROVIDER`` does, so removing the destination
    pin never leaves the credential injected. Then the binding record is
    deleted; a record that cannot be deleted is a failure, never ``removed``.
    """
    command = "provider-credential rm"
    provider = parsed.provider
    if not provider_creds.provider_id_ok(provider):
        return common._operational_failure(
            command,
            errors.VALIDATION_FAILED,
            f"invalid provider id {provider!r}",
            None,
            emit_json,
        )
    unreadable = f"remove or repair the unreadable provider-credential binding for '{provider}', then retry"
    try:
        present = provider_creds.get_binding(provider) is not None
    except state.StateSchemaError as exc:
        # A newer/unknown-schema or unparseable binding record fails closed with
        # the ADR-0041m stable code rather than a raw traceback.
        return common._operational_failure(command, errors.STATE_SCHEMA_UNSUPPORTED, str(exc), unreadable, emit_json)
    if not present:
        return common._operational_failure(
            command,
            errors.SECRET_MISSING,
            f"no credential binding for provider '{provider}'",
            f"list bindings with 'acq provider-credential ls', or add one with 'acq provider-credential set {provider} KEY_ENV --host H'",
            emit_json,
        )
    credential_removed, exit_code = _remove_credential(provider, backend_override, emit_json)
    if exit_code is not None:
        return exit_code
    try:
        provider_creds.remove_binding(provider)
    except state.StateSchemaError as exc:
        return common._operational_failure(command, errors.STATE_SCHEMA_UNSUPPORTED, str(exc), unreadable, emit_json)
    except OSError as exc:
        done = f"removed the stored '{provider}' credential, but " if credential_removed else ""
        return common._operational_failure(
            command,
            errors.FAILURE,
            f"{done}could not delete the '{provider}' binding record: {exc.strerror or exc}",
            f"check that the acq state directory is writable, then re-run 'acq provider-credential rm {provider}'",
            emit_json,
        )
    data = {"provider": provider, "removed": True, "credential_removed": credential_removed}
    if emit_json:
        print(json.dumps(envelope.success(command, data)))
    else:
        suffix = " and its stored credential" if credential_removed else ""
        print(f"removed the '{provider}' binding{suffix}.")
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
            "recreate the sandbox with 'acq create', or pass a workspace path explicitly",
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


def _github_scope_guidance(sandbox: str, owner: str, repos: list[str], url: str) -> None:
    """Tell the user how to mint the fine-grained token (stderr; Bash parity)."""
    lines = [
        f"acq: scoping a GitHub token for sandbox '{sandbox}'.",
        "      GitHub has no API to mint a fine-grained token, so create it in the browser.",
        "      Open the pre-filled link, choose 'Only select repositories' and pick the",
        "      repositories listed below, then generate the token and paste it here.",
        "      Default permissions: Contents, Pull requests and Issues read/write, Actions",
        "      read. Widen them in the form only if you need to (e.g. Workflows).",
        f"      Owner '{owner}': {url}",
        "      Repositories:",
        *(f"        {nwo}" for nwo in repos),
    ]
    print("\n".join(lines), file=sys.stderr)


def _github_scope_result(backend: str, sandbox: str, repos: list[str], owner: str | None, emit_json: bool) -> int:
    stored = owner is not None
    data: dict = {"sandbox": sandbox, "backend": backend, "scope": "sandbox" if stored else "none"}
    if stored:
        data["owner"] = owner
    data.update(repos=repos, stored=stored)
    if emit_json:
        print(json.dumps(envelope.success("github-scope", data)))
    elif stored:
        print(f"stored a GitHub token for sandbox '{sandbox}' only, requested for {', '.join(repos)}.")
    else:
        print("no GitHub repositories detected in the workspace; nothing to scope.")
    return errors.EXIT_SUCCESS


def _github_scope_owner(sandbox: str, repos: list[str], emit_json: bool) -> tuple[str | None, int | None]:
    """The workspace's single owner, or a refusal for a multi-owner workspace."""
    found = gitrepos.owners(repos)
    if len(found) == 1:
        return found[0], None
    return None, common._operational_failure(
        "github-scope",
        errors.VALIDATION_FAILED,
        f"cannot scope one GitHub token for sandbox '{sandbox}': the workspace has repositories "
        f"owned by {len(found)} accounts ({', '.join(repos)}), and a fine-grained token "
        "covers a single owner",
        f"re-run with a workspace that holds repositories from one owner: acq github-scope {sandbox} "
        "/path/to/one-owner-workspace; nothing was stored",
        emit_json,
    )


def run_github_scope(parsed, emit_json: bool, backend: str) -> int:
    """``acq github-scope SANDBOX [PATH]`` — the ADR-0013 per-sandbox token flow.

    Detects the GitHub repositories in the workspace. None: nothing to scope
    (exit 0, nothing read or stored). Several owners: refused, because a
    fine-grained token covers one owner. One owner: the pre-filled token URL is
    shown, the token is read from stdin (silently on a terminal) and stored for
    this sandbox only, in the acq secret store, then fed to the backend. The
    output names the owner and repositories the token was requested for; acq
    cannot verify a token's permissions offline, so it never claims the token
    was narrowed. The token never appears in output.
    """
    adapter = common._adapter(backend)
    sandbox = parsed.sandbox
    workspace, exit_code = _github_scope_workspace(parsed, backend, emit_json)
    if exit_code is not None:
        return exit_code
    assert workspace is not None  # nosec B101 # resolver contract; narrows the type for mypy
    repos = gitrepos.detect_workspace_repos(workspace)
    if not repos:
        return _github_scope_result(backend, sandbox, repos, None, emit_json)
    owner, exit_code = _github_scope_owner(sandbox, repos, emit_json)
    if owner is None:
        return exit_code if exit_code is not None else errors.EXIT_FAILURE
    url = gitrepos.pat_url(owner, sandbox)
    if not emit_json or hostexec.stdin_is_tty():
        _github_scope_guidance(sandbox, owner, repos, url)
    value = common._read_secret_value("Enter GitHub token: ")
    problem = None if value.strip() else "no GitHub token provided on stdin"
    problem = problem or secretstore.value_problem(value)
    if problem is not None:
        return common._operational_failure(
            "github-scope",
            errors.VALIDATION_FAILED,
            problem,
            f"create a fine-grained token for {owner} at {url} and pipe it on stdin, "
            f"e.g. printf '%s' TOKEN | acq github-scope {sandbox} PATH",
            emit_json,
        )
    try:
        adapter.github_scope(sandbox, value)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("github-scope", exc.code, exc.message, exc.remediation, emit_json)
    finally:
        value = ""
    try:
        provider_creds.github_scope_write(backend, sandbox, workspace, owner, repos)
    except OSError as exc:
        print(f"acq: warning: could not record the GitHub scope for '{sandbox}': {exc.strerror or exc}", file=sys.stderr)
    return _github_scope_result(backend, sandbox, repos, owner, emit_json)


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
