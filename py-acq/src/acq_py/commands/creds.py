"""``provider-credential`` set/ls/rm, ``github-scope``, and ``usai-rotate-api-key``:
per-sandbox credential binding (ADR-0013). No credential value is ever echoed.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import sys

from .. import (
    backends,
    envelope,
    errors,
    gitrepos,
    hostexec,
    lock,
    provider_creds,
    secretstore,
    state,
)
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
        with lock.provider_credential_lock(provider):
            return _set_locked(adapter, provider, key_env, hosts, value, emit_json)
    except lock.ProviderCredentialLockTimeout as exc:
        return common._operational_failure(
            command, errors.TIMEOUT, str(exc), "retry once the other command finishes; nothing was changed", emit_json
        )
    finally:
        value = ""


def _set_locked(adapter, provider: str, key_env: str, hosts: list[str], value: str, emit_json: bool) -> int:
    """``provider-credential set`` under the provider's lock.

    The binding is written before the value moves (plan default: binding
    first), so an unreadable or newer-schema record, or a state directory acq
    cannot write, fails closed with nothing stored in the backend. If the
    backend then refuses and the stored value did not change, the record is put
    back exactly as it was; once a new value is stored it keeps the new pin,
    which is what re-feeding and removing it resolve against.
    """
    command = "provider-credential set"
    try:
        snapshot = provider_creds.binding_snapshot(provider)
        before = _stored_digest(provider)
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
        after = _stored_digest(provider)
        if before is _UNREADABLE or after is _UNREADABLE or before != after:
            return common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
        return _set_failed(command, provider, snapshot, exc, emit_json)
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


# A stored value acq could not read: whether it changed is unknown.
_UNREADABLE = b"unreadable"


def _stored_digest(provider: str) -> bytes | None:
    """SHA-256 of ``provider``'s global value in the acq store (None when absent).

    Only a digest is kept, so the before/after comparison holds no second copy
    of the credential. A store that cannot be read gives :data:`_UNREADABLE`,
    which the caller treats as changed: the new pin is then kept rather than
    pointing a possibly-stored value back at the old destination.
    """
    try:
        current = secretstore.get(secretstore.key_for(provider))
    except (*common._ADAPTER_ERRORS, OSError):
        return _UNREADABLE
    return None if current is None else hashlib.sha256(current.encode("utf-8")).digest()


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


@dataclasses.dataclass
class _RmOutcome:
    """What removing a provider's credential did (``exit_code`` set on failure)."""

    removed: bool = False
    backend: str | None = None
    accepted: list[str] = dataclasses.field(default_factory=list)
    exit_code: int | None = None


def _rm_failed(provider: str, exc, outcome: _RmOutcome, emit_json: bool) -> _RmOutcome:
    kept = f"; the '{provider}' binding was kept, so the removal can be retried"
    remediation = exc.remediation
    if exc.code == errors.UNBIND_FAILED:
        remediation = (
            f"retry 'acq provider-credential rm {provider}'; remove a sandbox that stays unreachable or "
            "unconfirmed ('acq rm NAME'), or accept an unconfirmed one with "
            f"'acq provider-credential rm {provider} --accept-unconfirmed NAME'"
        )
    outcome.exit_code = common._operational_failure(
        "provider-credential rm", exc.code, exc.message + kept, remediation, emit_json
    )
    return outcome


def _remove_credential(
    provider: str, backend_override: str | None, accept: list[str] | None, emit_json: bool
) -> _RmOutcome:
    """Unbind and delete ``provider``'s global credential, as ``secret rm -g`` does.

    Runs while the binding still exists, because the backend resolves where the
    credential is bound from it. ``accept`` is ``--accept-unconfirmed`` (msb
    only; refused before anything changes on a backend without it).
    """
    command = "provider-credential rm"
    outcome = _RmOutcome()
    try:
        in_store = secretstore.exists(provider, None)
    except common._ADAPTER_ERRORS as exc:
        return _rm_failed(provider, exc, outcome, emit_json)
    outcome.backend, outcome.exit_code = _rm_credential_backend(backend_override, in_store, emit_json)
    if outcome.exit_code is not None or outcome.backend is None:
        return outcome
    backend = outcome.backend
    adapter = common._adapter(backend)
    if accept is not None and not getattr(adapter, "ACCEPT_UNCONFIRMED", False):
        outcome.exit_code = common._operational_failure(
            command, errors.UNSUPPORTED, f"--accept-unconfirmed is not supported on the {backend} backend",
            "remove the flag; nothing was changed", emit_json,
        )
        return outcome
    if not common._supports(backend, "secret-rm"):
        if in_store:
            outcome.exit_code = common._operational_failure(
                command,
                errors.UNSUPPORTED,
                f"the {backend} backend cannot unbind the stored '{provider}' credential; nothing was changed",
                "re-run with a backend that can remove secrets (--backend NAME)",
                emit_json,
            )
        return outcome
    present_fn = getattr(adapter, "secret_present", None)
    try:
        in_backend = present_fn(secretstore.GLOBAL, provider) if present_fn is not None else None
        if not in_store and not in_backend:
            return outcome
        if in_backend is not False and accept is not None:
            outcome.accepted = adapter.secret_unbind(secretstore.GLOBAL, provider, accept_unconfirmed=accept) or []
        elif in_backend is not False:
            adapter.secret_unbind(secretstore.GLOBAL, provider)
        secretstore.delete(secretstore.key_for(provider))
        secretstore.meta_delete(provider, None)
    except common._ADAPTER_ERRORS as exc:
        return _rm_failed(provider, exc, outcome, emit_json)
    outcome.removed = True
    return outcome


def _sbx_custom_secret_remains(binding: dict) -> list[str] | None:
    """After any sbx removal, successful or not: the placeholders of the global
    custom secrets sbx still lists for the binding's KEY_ENV, or ``None`` when
    there are none.

    The removal path takes only the ``set-custom`` entry whose targets match the
    binding's hosts, and deletes the stored value either way. A same-KEY_ENV
    entry it skipped (re-pinned out of band, or targets sbx lists in a form acq
    cannot match) would keep ``$KEY_ENV`` injected after a reported success, so
    the listing is re-read every time. A listing that cannot be read, or a
    binding without a KEY_ENV, counts as remaining (``[""]``): never a silent
    success.
    """
    key_env = binding.get("key_env")
    if not isinstance(key_env, str):
        return [""]
    try:
        left = common._adapter("sbx").custom_secret_placeholders(secretstore.GLOBAL, key_env)
    except common._ADAPTER_ERRORS:
        return [""]
    return left or None


def _sbx_rm_incomplete(provider: str, binding: dict, outcome: _RmOutcome, left: list[str], emit_json: bool) -> int:
    """Fail an sbx removal that left a custom secret for KEY_ENV in place."""
    key_env = binding.get("key_env") or "its KEY_ENV"
    done = f"removed the stored '{provider}' credential, but " if outcome.removed else ""
    named = [p for p in left if p]
    target = " or ".join(f"'acq secret rm {p}'" for p in named) or "'acq secret rm PLACEHOLDER' (from 'sbx secret ls')"
    return common._operational_failure(
        "provider-credential rm",
        errors.UNBIND_FAILED,
        f"{done}sbx still lists a global custom secret for ${key_env}, so it may still be injected "
        f"(credential_removed: false); the '{provider}' binding was kept",
        f"remove it with {target}, then re-run 'acq provider-credential rm {provider}'",
        emit_json,
    )


def _warn_sbx_custom_secret(provider: str, binding: dict) -> None:
    """An sbx removal that failed left the ``set-custom`` entry listed: say it may
    still be injected rather than imply it is gone."""
    key_env = binding.get("key_env") or "its KEY_ENV"
    print(
        f"acq: warning: an sbx custom secret for ${key_env} ('{provider}') may still be injected; "
        "acq did not remove it. List it with 'sbx secret ls' and remove it with "
        "'acq secret rm PLACEHOLDER' (the placeholder sbx lists for it).",
        file=sys.stderr,
    )


def _accept_names(parsed) -> tuple[list[str] | None, str | None]:
    """``--accept-unconfirmed NAME[,NAME]`` (repeatable) as names, or a problem."""
    raw = getattr(parsed, "accept_unconfirmed", None)
    if not raw:
        return None, None
    names = [n for value in raw for n in value.split(",")]
    bad = next((n for n in names if not common._secret_name_ok(n)), None)
    if bad is not None:
        return None, f"invalid sandbox name {bad!r} for --accept-unconfirmed"
    return names, None


def run_provider_credential_rm(parsed, emit_json: bool, backend_override: str | None = None) -> int:
    """``acq provider-credential rm PROVIDER [--accept-unconfirmed NAME[,NAME]]``.

    Removing an absent binding fails closed with ``secret_missing`` (reused: the
    credential binding is missing, ADR-0040m). The provider's stored global
    credential is unbound from the sandboxes that hold it and deleted first,
    exactly as ``acq secret rm -g PROVIDER`` does (``--accept-unconfirmed`` is
    passed through, msb only), so removing the destination pin never leaves the
    credential injected. Then the binding record is deleted; a record that
    cannot be deleted is a failure, never ``removed``. Runs under the
    provider's lock, like ``set``.
    """
    command = "provider-credential rm"
    provider = parsed.provider
    accept, problem = _accept_names(parsed)
    if problem is None and not provider_creds.provider_id_ok(provider):
        problem = f"invalid provider id {provider!r}"
    if problem is not None:
        return common._operational_failure(command, errors.VALIDATION_FAILED, problem, None, emit_json)
    try:
        with lock.provider_credential_lock(provider):
            return _rm_locked(provider, backend_override, accept, emit_json)
    except lock.ProviderCredentialLockTimeout as exc:
        return common._operational_failure(
            command, errors.TIMEOUT, str(exc), "retry once the other command finishes; nothing was changed", emit_json
        )


def _rm_locked(provider: str, backend_override: str | None, accept: list[str] | None, emit_json: bool) -> int:
    command = "provider-credential rm"
    unreadable = f"remove or repair the unreadable provider-credential binding for '{provider}', then retry"
    try:
        binding = provider_creds.get_binding(provider)
    except state.StateSchemaError as exc:
        # A newer/unknown-schema or unparseable binding record fails closed with
        # the ADR-0041m stable code rather than a raw traceback.
        return common._operational_failure(command, errors.STATE_SCHEMA_UNSUPPORTED, str(exc), unreadable, emit_json)
    if binding is None:
        return common._operational_failure(
            command,
            errors.SECRET_MISSING,
            f"no credential binding for provider '{provider}'",
            f"list bindings with 'acq provider-credential ls', or add one with 'acq provider-credential set {provider} KEY_ENV --host H'",
            emit_json,
        )
    outcome = _remove_credential(provider, backend_override, accept, emit_json)
    if outcome.backend == "sbx":
        left = _sbx_custom_secret_remains(binding)
        if left is not None and outcome.exit_code is not None:
            _warn_sbx_custom_secret(provider, binding)
        elif left is not None:
            return _sbx_rm_incomplete(provider, binding, outcome, left, emit_json)
    if outcome.exit_code is not None:
        return outcome.exit_code
    try:
        provider_creds.remove_binding(provider)
    except state.StateSchemaError as exc:
        return common._operational_failure(command, errors.STATE_SCHEMA_UNSUPPORTED, str(exc), unreadable, emit_json)
    except OSError as exc:
        done = f"removed the stored '{provider}' credential, but " if outcome.removed else ""
        return common._operational_failure(
            command,
            errors.FAILURE,
            f"{done}could not delete the '{provider}' binding record: {exc.strerror or exc}",
            f"check that the acq state directory is writable, then re-run 'acq provider-credential rm {provider}'",
            emit_json,
        )
    data: dict = {"provider": provider, "removed": True, "credential_removed": outcome.removed}
    if accept is not None:
        data["unconfirmed"] = outcome.accepted
    if emit_json:
        print(json.dumps(envelope.success(command, data)))
    else:
        suffix = " and its stored credential" if outcome.removed else ""
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


_ROTATE = "usai-rotate-api-key"
_ROTATE_RETRY = "re-run 'acq usai-rotate-api-key' with the same key to retry the sandboxes that were not re-fed"


def _rotation_backends(backend: str) -> tuple[list[str], list[dict]]:
    """``(names, below_floor)``: the active backend, then the other one when it
    is installed and meets acq's version floor.

    The acq store is shared, so a sandbox on the other backend uses the same
    key and is re-fed too, in both directions. Bash (``acq_propagate_usai_rotation``)
    propagates only msb to sbx: it refuses sbx to msb, because its sbx rotation
    never puts the key in the acq store, and its propagation needs an existing
    sbx entry. Here the key is always stored first, so a rotation on sbx re-feeds
    msb too, and a rotation on sbx creates a missing global sbx entry (see
    ``sbx.rotate_refeed``). acq drives no sandbox on an installed backend below
    its floor, so that backend gets a result of its own: not re-fed when it holds
    (or may hold) the key, else skipped.
    """
    names = [backend]
    below: list[dict] = []
    for other in backends.BACKEND_ORDER:
        spec = backends.BACKENDS[other]
        if other == backend or not backends.detect(spec).installed:
            continue
        problem = backends.check_version(spec)
        if problem is None:
            names.append(other)
            continue
        result: dict = {"backend": other, "refed": [], "kept_own": [], "not_refed": []}
        holds = common._adapter(other).rotate_holds_key()
        if holds is False:
            result["skipped"] = problem.message
        else:
            result["not_refed"] = [f"any sandbox holding the key ({problem.message})"]
            result["remediation"] = problem.remediation
        below.append(result)
    return names, below


_ROTATE_GLOBAL = {"updated": "the global USAi secret", "created": "the global USAi secret (created)"}


def _refed_names(result: dict) -> list[str]:
    """What took the new key: the global sbx entry, when it did, then the sandboxes."""
    glob = _ROTATE_GLOBAL.get(result.get("global", ""))
    return ([glob] if glob else []) + result["refed"]


def _rotate_lines(results: list[dict]) -> list[str]:
    lines = []
    for result in results:
        name = result["backend"]
        lines.append(f"  {name}: re-fed: {', '.join(_refed_names(result)) or 'none'}")
        if result["kept_own"]:
            lines.append(f"  {name}: kept their own usai key: {', '.join(result['kept_own'])}")
        if result.get("not_refed"):
            lines.append(f"  {name}: NOT re-fed: {', '.join(result['not_refed'])}")
        if result.get("skipped"):
            lines.append(f"  {name}: skipped (holds no usai key): {result['skipped']}")
        if name == "msb":
            lines.append("  msb: stopped sandboxes are not re-fed; 'acq start' gives them the stored key")
    return lines


def _rotate_report(results: list[dict], emit_json: bool) -> int:
    """Success when every backend re-fed everything, else exit 1 naming what
    was not re-fed. Either way ``backends`` reports each backend's outcome."""
    missed = [r for r in results if r.get("not_refed")]
    public = [{k: v for k, v in r.items() if k != "remediation"} for r in results]
    if not missed:
        data = {
            "provider": provider_creds.USAI_PROVIDER_ID,
            "key_env": provider_creds.USAI_PROVIDER_KEY_ENV,
            "rotated": True,
            "backends": public,
        }
        if emit_json:
            print(json.dumps(envelope.success(_ROTATE, data)))
        else:
            print("rotated the USAi API key (stored in the acq secret store).")
            print("\n".join(_rotate_lines(results)))
        return errors.EXIT_SUCCESS
    detail = "; ".join(
        f"{r['backend']}: not re-fed: {', '.join(r['not_refed'])}"
        + (f"; re-fed: {', '.join(_refed_names(r))}" if _refed_names(r) else "")
        for r in missed
    )
    message = f"stored the new USAi key in the acq secret store, but not every sandbox received it ({detail})"
    # One remediation per backend that missed the key (the retry hint where it
    # has none of its own), each shown once.
    remediations = list(dict.fromkeys(r.get("remediation") or _ROTATE_RETRY for r in missed))
    if emit_json:
        doc = envelope.error(_ROTATE, errors.FAILURE, message, remediation="; ".join(remediations))
        doc["error"]["backends"] = public
        print(json.dumps(doc))
    else:
        print(f"acq: {message}", file=sys.stderr)
        print("\n".join(_rotate_lines(results)), file=sys.stderr)
        print("\n".join(remediations), file=sys.stderr)
    return errors.EXIT_FAILURE


def _rotate_refeed_all(names: list[str], backend: str, value: str) -> list[dict]:
    results: list[dict] = []
    for name in names:
        try:
            results.append(common._adapter(name).rotate_refeed(value, primary=name == backend))
        except common._ADAPTER_ERRORS as exc:
            results.append({"backend": name, "refed": [], "kept_own": [], "not_refed": [f"every sandbox ({exc.message})"],
                            "remediation": exc.remediation})
    return results


def _rotate_locked(backend: str, value: str, emit_json: bool) -> int:
    """Rotation under the usai provider lock: preflight every backend that
    will be re-fed, store, then re-feed.

    A preflight refusal names its backend and changes nothing. The other
    backend may instead report that it cannot be re-fed (sbx whose secret list
    cannot be read): the rotation goes ahead without it and exits 1 naming it.
    """
    try:
        names, skipped = _rotation_backends(backend)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure(_ROTATE, exc.code, exc.message, exc.remediation, emit_json)
    ready: list[str] = []
    for name in names:
        try:
            unfed = common._adapter(name).rotate_preflight(primary=name == backend)
        except common._ADAPTER_ERRORS as exc:
            return common._operational_failure(_ROTATE, exc.code, f"{name}: {exc.message}", exc.remediation, emit_json)
        if unfed is None:
            ready.append(name)
        else:
            skipped.insert(0, unfed)
    try:
        secretstore.store(secretstore.key_for(provider_creds.USAI_PROVIDER_ID), value)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure(_ROTATE, exc.code, exc.message, exc.remediation, emit_json)
    return _rotate_report(_rotate_refeed_all(ready, backend, value) + skipped, emit_json)


def run_usai_rotate_api_key(emit_json: bool, backend: str) -> int:
    """``acq usai-rotate-api-key`` — rotate the global USAi key (ADR-0012).

    Reads the new key on stdin only (silently, after a prompt, on a terminal).
    Rotation is a store write plus a re-feed; acq does not call the provider
    (as in Bash, the key is checked against the real sandbox on the next
    attach). Under the usai provider lock, each backend to be re-fed (the
    active one and, when it is installed, the other) first refuses, with
    nothing changed, a rotation it could not deliver; the error names the
    backend. The key then goes to the acq secret store, the source of truth on
    both backends, and every sandbox that uses it is re-fed. If any sandbox did
    not receive the key (or an installed backend below acq's floor, or one whose
    secrets acq could not list, may hold it) the command exits 1 naming it, and
    ``backends`` reports each backend's outcome; the store keeps the new key, so
    re-running with the same key retries. The key never appears in argv,
    output or errors.
    """
    value = common._read_secret_value("Enter the new USAi API key: ")
    problem = None if value.strip() else "no new USAi key provided on stdin"
    problem = problem or secretstore.value_problem(value)
    if problem is not None:
        return common._operational_failure(
            _ROTATE,
            errors.VALIDATION_FAILED,
            problem,
            "pipe the new key on stdin, e.g. printf '%s' NEW_KEY | acq usai-rotate-api-key",
            emit_json,
        )
    try:
        with lock.provider_credential_lock(provider_creds.USAI_PROVIDER_ID):
            return _rotate_locked(backend, value, emit_json)
    except lock.ProviderCredentialLockTimeout as exc:
        return common._operational_failure(
            _ROTATE, errors.TIMEOUT, str(exc), "retry once the other command finishes; nothing was changed", emit_json
        )
