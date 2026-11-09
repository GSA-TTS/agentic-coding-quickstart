"""``secret set``/``rm``/``ls``/``has``/``import``, backend-neutral.

The acq secret store (:mod:`acq_py.secretstore`, shared with the Bash ``acq``)
is the source of truth on every backend (plan default 1). These handlers carry
no per-backend branches: they validate, write or read the store, and reach the
backend only through the adapter seam below, gated by its capability record.

Adapter seam (an adapter that declares the capability provides the function):

* ``secret-write``: optional ``secret_preflight(scope, service, host, env)``,
  run before anything is stored, then ``secret_feed(scope, service, value,
  host, env)`` after the store write.
* ``secret-rm``: optional ``secret_present(scope, service)`` (the backend's own
  table) and ``secret_unbind(scope, service)``, run before the store entry and
  its endpoint sidecar are deleted. An adapter with ``secret_rm_raw`` also takes
  a single bare placeholder token.
* ``secret-list``: ``secret_ls(scope)``.
* ``secret has``: ``secret_has(scope, service)``, the "can inject" predicate.

``secret import`` writes only the store and needs no backend, as in Bash.

A value is read from stdin (silently, with a prompt, on a terminal). It never
appears in argv or output, and is handed to the backend only on a child's stdin.
"""

from __future__ import annotations

import json
import os
import sys

from .. import envelope, errors, provider_creds, secretstore
from . import common

_SET_USAGE = "usage: acq secret set [-g | SANDBOX] SERVICE [--host HOST --env ENV] (value on stdin)"
_IMPORT_USAGE = "usage: acq secret import [SERVICE] [-g | SANDBOX] [--all] [--force] [--dry-run]"
_ENV_NAME_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")


def _unsupported(command: str, backend: str, emit_json: bool) -> int:
    return common._operational_failure(
        command,
        errors.UNSUPPORTED,
        f"{command} is not supported on the {backend} backend",
        "this backend cannot inject secrets from the acq store yet; nothing was changed",
        emit_json,
    )


def _prompt_for(service: str) -> str:
    # Users think of usai as their "API key", not a "secret" (Bash parity).
    if service == "usai":
        return "Enter USAi API key: "
    if service == "github":
        return "Enter GitHub token: "
    return f"Enter {service} API key: "


def _known_env_for(service: str) -> str | None:
    """The env var a service binds by default, so ``--host`` alone suffices."""
    if service == "github":
        return "GITHUB_TOKEN"
    return _provider_key_envs().get(service)


def _resolve_binding(service: str, hosts: list[str], env: str | None) -> tuple[str, str, str | None]:
    """``(host, env, problem)`` for ``secret set``'s endpoint flags.

    Host and env bind together: a host without an env var (and no default for
    the service) cannot be bound, and an env var without a host has nowhere to
    go, so either is refused before anything is stored. No flags is ``("",
    "", None)``: the backend's built-in mapping applies.
    """
    if not hosts and env is None:
        return "", "", None
    if not hosts:
        return "", "", f"--env {env} needs --host HOST as well"
    host = ",".join(hosts).lower()  # DNS names are case-insensitive; record one form
    if any(not part for part in host.split(",")) or secretstore._META_HOST_RE.fullmatch(host) is None:
        return "", "", f"invalid --host {host!r}: hosts are DNS names, comma-separated"
    env = env or _known_env_for(service)
    if env is None:
        return "", "", f"--host {host} needs --env ENV as well ('{service}' has no env mapping)"
    if env[0].isdigit() or not set(env) <= _ENV_NAME_CHARS:
        return "", "", f"invalid env var name {env!r} (must match [A-Za-z_][A-Za-z0-9_]*)"
    return host, env, None


def run_secret_set(parsed, emit_json: bool, backend: str) -> int:
    """``acq secret set (-g | SANDBOX) SERVICE [--host H --env E]``.

    Order: shape and names, then the endpoint flags, then the value (prompted
    without echo on a terminal), then the capability gate and the adapter's
    preflight, so a refusal never leaves a half-written entry. The value goes
    to the acq store, the endpoint mapping to its sidecar, and then to the
    backend's feed on the child's stdin. The success envelope carries only
    scope/service/value_state.
    """
    command = "secret set"
    tokens, hosts, env_flag, flag_error = common._split_host_env(list(parsed.args))
    hosts = list(getattr(parsed, "hosts", None) or []) + hosts
    env_flag = env_flag or getattr(parsed, "env_name", None)
    scope, service = common._parse_secret_scope_service(parsed.global_scope, tokens)
    if flag_error or scope is None or service is None:
        return common._usage_failure(command, flag_error or _SET_USAGE, emit_json)
    problem = common._secret_names_problem(scope, service)
    if problem is None:
        host, env, problem = _resolve_binding(service, hosts, env_flag)
    if problem is not None:
        return common._operational_failure(command, errors.VALIDATION_FAILED, problem, _SET_USAGE, emit_json)

    value = common._read_secret_value(_prompt_for(service))
    if not value.strip():
        # Empty (or whitespace-only) input is a validation failure (exit 1), not
        # a usage error (exit 2): the invocation was well-formed but supplied no
        # storable value (ADR-0038m §1 "validation" class).
        return common._operational_failure(
            command,
            errors.VALIDATION_FAILED,
            "no secret value provided on stdin",
            "pipe the secret value on stdin, e.g. printf '%s' VALUE | acq secret set -g SERVICE",
            emit_json,
        )
    value_problem = secretstore.value_problem(value)
    if value_problem is not None:
        return common._operational_failure(
            command, errors.VALIDATION_FAILED, value_problem, "provide a single-line value", emit_json
        )
    if not common._supports(backend, "secret-write"):
        return _unsupported(command, backend, emit_json)

    adapter = common._adapter(backend)
    preflight = getattr(adapter, "secret_preflight", None)
    try:
        if preflight is not None:
            preflight(scope, service, host, env)
        secretstore.set_secret(service, scope.sandbox, value, host, env)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    try:
        adapter.secret_feed(scope, service, value, host, env)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure(
            command,
            exc.code,
            f"stored '{service}' in the acq secret store, but {exc.message}",
            exc.remediation,
            emit_json,
        )
    finally:
        value = ""
    data = {"scope": scope.label, "service": service, "value_state": "set"}
    if emit_json:
        print(json.dumps(envelope.success(command, data)))
    else:
        print(f"stored secret '{service}' ({scope.describe()})")
    return errors.EXIT_SUCCESS


def run_secret_rm_raw(adapter, placeholder: str, emit_json: bool) -> int:
    """Raw-placeholder removal from a backend's own proxy table (ADR-0038m §48).

    The acq store is left unchanged (never rewrites host-held records). The
    placeholder is never a secret value.
    """
    try:
        adapter.secret_rm_raw(placeholder)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("secret rm", exc.code, exc.message, exc.remediation, emit_json)
    data = {"placeholder": placeholder, "value_state": "unset"}
    if emit_json:
        print(json.dumps(envelope.success("secret rm", data)))
    else:
        print(f"removed raw placeholder '{placeholder}'.")
    return errors.EXIT_SUCCESS


_RM_USAGE = "usage: acq secret rm [-g | SANDBOX] SERVICE [--accept-unconfirmed NAME[,NAME]]"


def _split_accept(parsed) -> tuple[list[str], list[str] | None, str | None]:
    """``(positionals, accepted sandbox names or None, problem)`` for ``secret rm``.

    ``--accept-unconfirmed NAME[,NAME]`` (or ``=NAME``) may come before or after
    the scope and service; it is repeatable and comma-separated. Each name must
    be a valid sandbox name.
    """
    positionals: list[str] = []
    raw = list(getattr(parsed, "accept_unconfirmed", None) or [])
    it = iter(parsed.args)
    for token in it:
        flag, eq, inline = token.partition("=")
        if flag != "--accept-unconfirmed":
            positionals.append(token)
            continue
        value = inline if eq else next(it, None)
        if not value:
            return positionals, None, "--accept-unconfirmed needs a sandbox name"
        raw.append(value)
    if not raw:
        return positionals, None, None
    names = [n for value in raw for n in value.split(",")]
    bad = next((n for n in names if not common._secret_name_ok(n)), None)
    if bad is not None:
        return positionals, None, f"invalid sandbox name {bad!r} for --accept-unconfirmed"
    return positionals, names, None


def run_secret_rm(parsed, emit_json: bool, backend: str) -> int:
    """``acq secret rm (-g | SANDBOX) SERVICE`` — remove a secret.

    Present means stored in the acq store for exactly this scope, or held in
    the backend's own table. An absent secret fails closed with
    ``secret_missing`` (ADR-0040m); a backend or store that cannot answer fails
    closed with its own accurate code and never deletes. The backend is unbound
    first, then the store value and its endpoint sidecar are deleted.
    """
    command = "secret rm"
    adapter = common._adapter(backend)
    args, accept, accept_problem = _split_accept(parsed)
    scope, service = common._parse_secret_scope_service(parsed.global_scope, args)
    if scope is None or service is None:
        # A single bare token (no scope, no second positional) is a raw
        # placeholder for a backend that keeps its own proxy table.
        raw_ok = accept is None and accept_problem is None and not parsed.global_scope and len(args) == 1
        if hasattr(adapter, "secret_rm_raw") and raw_ok and not args[0].startswith("-"):
            return run_secret_rm_raw(adapter, args[0], emit_json)
        return common._usage_failure(command, _RM_USAGE, emit_json)
    problem = accept_problem or common._secret_names_problem(scope, service)
    if problem is not None:
        return common._operational_failure(command, errors.VALIDATION_FAILED, problem, _RM_USAGE, emit_json)
    if not common._supports(backend, "secret-rm"):
        return _unsupported(command, backend, emit_json)
    if accept is not None and not getattr(adapter, "ACCEPT_UNCONFIRMED", False):
        return common._operational_failure(
            command, errors.UNSUPPORTED, f"--accept-unconfirmed is not supported on the {backend} backend",
            "remove the flag; nothing was changed", emit_json,
        )
    present_fn = getattr(adapter, "secret_present", None)
    try:
        in_backend = present_fn(scope, service) if present_fn is not None else None
        in_store = secretstore.exists(service, scope.sandbox)
    except common._ADAPTER_ERRORS as exc:
        # A backend or store that cannot answer is NOT "absent": fail closed
        # with the accurate code, never secret_missing, and never delete.
        return common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    if not in_store and not in_backend:
        return common._operational_failure(
            command,
            errors.SECRET_MISSING,
            f"no secret '{service}' for {scope.describe()}",
            f"store one with 'acq secret set -g {service}' (or scoped to a sandbox)",
            emit_json,
        )
    accepted: list[str] = []
    try:
        if in_backend is not False and accept is not None:
            accepted = adapter.secret_unbind(scope, service, accept_unconfirmed=accept) or []
        elif in_backend is not False:
            adapter.secret_unbind(scope, service)
        secretstore.delete(secretstore.key_for(service, scope.sandbox))
        secretstore.meta_delete(service, scope.sandbox)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    data: dict = {"scope": scope.label, "service": service, "value_state": "unset"}
    if accept is not None:
        data["unconfirmed"] = accepted
    if emit_json:
        print(json.dumps(envelope.success(command, data)))
    else:
        print(f"removed secret '{service}' ({scope.describe()})")
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

    An unreadable or unparseable listing fails closed with ``secret_unreadable``
    (ADR-0040m) rather than being reported as empty. A backend whose capability
    record declares ``secret-list`` unsupported fails closed with
    ``unsupported_capability``.
    """
    if not common._supports(backend, "secret-list"):
        return common._operational_failure(
            "secret ls",
            errors.UNSUPPORTED,
            f"secret listing is not supported on the {backend} backend",
            "this backend cannot list secrets from the acq store yet",
            emit_json,
        )
    scope, ok = common._parse_secret_ls_scope(parsed.global_scope, parsed.args)
    if not ok:
        return common._usage_failure("secret ls", "usage: acq secret ls [-g | SANDBOX]", emit_json)
    problem = common._secret_names_problem(scope, None)
    if problem is not None:
        return common._operational_failure("secret ls", errors.VALIDATION_FAILED, problem, None, emit_json)
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
    The answer is the adapter's ``secret_has`` "can inject" predicate.
    """
    scope, service = common._parse_secret_scope_service(parsed.global_scope, parsed.args)
    if scope is None or service is None:
        return common._usage_failure("secret has", "usage: acq secret has [-g | SANDBOX] SERVICE", False)
    problem = common._secret_names_problem(scope, service)
    if problem is not None:
        print(f"acq: {problem}", file=sys.stderr)
        return errors.EXIT_FAILURE
    backend, exit_code = common._resolve_backend_for_mutation(
        backend_override, False, "secret has", domain="secret management"
    )
    if exit_code is not None or backend is None:
        # The resolver already wrote a stderr diagnostic (no backend, or version
        # floor): exit 1/2 with stdout still silent, so "cannot check" is never a
        # silent false "absent".
        return errors.EXIT_FAILURE if exit_code is None else exit_code
    try:
        present = common._adapter(backend).secret_has(scope, service)
    except common._ADAPTER_ERRORS as exc:
        # Backend error at query time: keep stdout silent and exit 1, but announce
        # on stderr so a scripter can tell "absent" from "could not check".
        print(f"acq: {exc.message}", file=sys.stderr)
        if exc.remediation:
            print(exc.remediation, file=sys.stderr)
        return errors.EXIT_FAILURE
    return errors.EXIT_SUCCESS if present else errors.EXIT_FAILURE


# ---------------------------------------------------------------------------
# `secret import` (Bash acq_secret_import / _acq_import_*).
# ---------------------------------------------------------------------------

# Services acq manages beyond the providers, with the host env vars `secret
# import` reads for each, most preferred first. Providers come from the
# credential-bindings registry (the shipped usai trust anchor included).
_MANAGED_IMPORT_ENVS = {"github": ("GITHUB_TOKEN", "GH_TOKEN"), "gitlab": ("GITLAB_TOKEN",)}


def _provider_key_envs() -> dict[str, str]:
    """Provider id -> KEY_ENV: the trust anchor, then the registry layers.

    A malformed registry entry only narrows what can be imported (Bash ignores
    lookup errors here too); it never widens it.
    """
    out = {provider_creds.USAI_PROVIDER_ID: provider_creds.USAI_PROVIDER_KEY_ENV}
    try:
        bindings = provider_creds.list_bindings()
    except (ValueError, OSError):
        bindings = []
    for b in bindings:
        provider, key_env = b.get("provider"), b.get("key_env")
        if (
            isinstance(provider, str) and isinstance(key_env, str)
            and provider_creds.provider_id_ok(provider) and provider not in out
        ):
            out[provider] = key_env
    return out


def _import_env_vars(service: str) -> tuple[str, ...]:
    if service in _MANAGED_IMPORT_ENVS:
        return _MANAGED_IMPORT_ENVS[service]
    key_env = _provider_key_envs().get(service)
    return (key_env,) if key_env else ()


def _importable_services() -> list[str]:
    return list(_MANAGED_IMPORT_ENVS) + [p for p in _provider_key_envs() if p not in _MANAGED_IMPORT_ENVS]


class _ImportArgs:
    def __init__(self) -> None:
        self.mode = "interactive"  # interactive | all | force
        self.dry_run = False
        self.service: str | None = None
        self.sandbox: str | None = None
        self.global_flag = False


def _import_take_service(opts: _ImportArgs, service: str) -> str | None:
    if opts.service is not None and opts.service != service:
        return f"secret import: unexpected extra argument '{service}'"
    opts.service = service
    return None


def _parse_import(parsed) -> tuple[_ImportArgs, str | None]:
    """Mirror ``_acq_import_parse_args``: an optional importable SERVICE, a scope
    (``-g`` or a bare SANDBOX), and ``--all``/``--force``/``-f``/``--dry-run``.
    Returns ``(args, usage_error)``."""
    opts = _ImportArgs()
    opts.global_flag = bool(parsed.global_scope)
    opts.mode = "force" if parsed.force else ("all" if parsed.all else "interactive")
    opts.dry_run = bool(parsed.dry_run)
    importable = _importable_services()
    if parsed.service is not None:
        if parsed.service not in importable:
            return opts, f"secret import: unknown service '{parsed.service}' for --service"
        opts.service = parsed.service
    for arg in parsed.args:
        if arg in ("--all", "--force", "-f", "--dry-run", "-g", "--global"):
            opts.mode = {"--all": "all", "--force": "force", "-f": "force"}.get(arg, opts.mode)
            opts.dry_run = opts.dry_run or arg == "--dry-run"
            opts.global_flag = opts.global_flag or arg in ("-g", "--global")
        elif arg.startswith("--service="):
            name = arg[len("--service="):]
            if name not in importable:
                return opts, f"secret import: unknown service '{name}' for --service"
            err = _import_take_service(opts, name)
            if err:
                return opts, err
        elif arg.startswith("-"):
            return opts, f"secret import: unknown flag '{arg}'"
        elif arg in importable:
            err = _import_take_service(opts, arg)
            if err:
                return opts, err
        elif opts.sandbox is None:
            opts.sandbox = arg
        else:
            return opts, f"secret import: unexpected extra argument '{arg}'"
    if opts.global_flag and opts.sandbox is not None:
        # Bash lets whichever comes last win; refuse the ambiguity instead.
        return opts, "secret import: give either -g or a SANDBOX, not both"
    return opts, None


def _last4(value: str) -> str:
    """The masked preview Bash shows in prompts: the last four characters, or
    all stars for a short value. ASCII ``...`` stands in for Bash's ellipsis, so
    the line survives a Windows console or pipe's legacy code page."""
    return "..." + ("*" * len(value) if len(value) <= 4 else value[-4:])


def _confirm(svc: str, envvar: str, scope: secretstore.Scope, exists: bool, preview: str, say) -> str | None:
    """None to proceed, else the skip reason. Prompts on a terminal only;
    ``ACQ_SECRET_IMPORT_ASSUME_YES`` answers yes (Bash parity)."""
    if os.environ.get("ACQ_SECRET_IMPORT_ASSUME_YES"):
        return None
    if not common._stdin_is_terminal():
        say(f"acq: '{svc}' detected in ${envvar} but stdin is not a TTY; skipping (use --all/--force).")
        return "not_a_tty"
    if exists:
        question = f"acq: overwrite stored {svc} ({scope.describe()}) with ${envvar} ({preview})? [y/N] "
    else:
        question = f"acq: import {svc} from ${envvar} ({preview}) into {scope.describe()}? [y/N] "
    print(question, end="", file=sys.stderr, flush=True)
    answer = sys.stdin.readline().strip()
    if answer in ("y", "Y", "yes", "YES"):
        return None
    print(f"acq: skipped '{svc}'.", file=sys.stderr)
    return "declined"


def _import_one(svc: str, envvar: str, opts: _ImportArgs, scope: secretstore.Scope, say) -> dict:
    """Decide and (unless --dry-run) store one detected service. The value is
    read from the environment at the point of use and goes straight to the
    store; no message ever contains it beyond the masked preview."""
    entry: dict[str, object] = {"service": svc, "source_env": envvar}
    value = os.environ.get(envvar, "")
    problem = secretstore.value_problem(value)
    if problem is not None:
        say(f"acq: refusing '{svc}': ${envvar}: {problem}. Set a single-line value and retry.")
        return {**entry, "outcome": "refused", "reason": "unstorable"}
    exists = secretstore.exists(svc, scope.sandbox)
    entry["existed"] = exists
    desc = scope.describe()
    if opts.dry_run:
        if exists and opts.mode == "all":
            say(f"acq: [dry-run] '{svc}' already stored ({desc}); would SKIP (use --force).")
            return {**entry, "outcome": "skipped", "reason": "exists"}
        if exists:
            say(f"acq: [dry-run] would OVERWRITE '{svc}' ({desc}) from ${envvar} ({_last4(value)}).")
        else:
            say(f"acq: [dry-run] would import '{svc}' from ${envvar} ({_last4(value)}) into {desc}.")
        return {**entry, "outcome": "imported"}
    if opts.mode == "all" and exists:
        say(f"acq: '{svc}' already stored ({desc}); skipping (use --force to overwrite).")
        return {**entry, "outcome": "skipped", "reason": "exists"}
    if opts.mode == "interactive":
        reason = _confirm(svc, envvar, scope, exists, _last4(value), say)
        if reason is not None:
            return {**entry, "outcome": "skipped", "reason": reason}
    secretstore.store(secretstore.key_for(svc, scope.sandbox), value)
    value = ""
    say(f"acq: imported '{svc}' ({desc}) from ${envvar}.")
    return {**entry, "outcome": "imported"}


def run_secret_import(parsed, emit_json: bool) -> int:
    """``acq secret import [SERVICE] [-g | SANDBOX] [--all] [--force] [--dry-run]``.

    Populate the acq store from known service tokens in the host environment
    (``USAI_API_KEY``, ``GITHUB_TOKEN``/``GH_TOKEN``, ``GITLAB_TOKEN``, and each
    registered provider's KEY_ENV). Global by default. Interactive mode asks per
    service on a terminal and skips otherwise; ``--all`` imports but never
    overwrites; ``--force`` overwrites; ``--dry-run`` writes nothing. A value
    with a newline or tab is refused. Writes only the store, never a backend.
    """
    command = "secret import"
    opts, usage = _parse_import(parsed)
    if usage is not None:
        return common._usage_failure(command, usage, emit_json)
    if opts.sandbox is not None and not common._secret_name_ok(opts.sandbox):
        problem = common._secret_names_problem(secretstore.sandbox_scope(opts.sandbox), None)
        return common._operational_failure(command, errors.VALIDATION_FAILED, str(problem), _IMPORT_USAGE, emit_json)
    scope = secretstore.GLOBAL if opts.sandbox is None else secretstore.sandbox_scope(opts.sandbox)

    def say(line: str) -> None:
        if not emit_json:
            print(line, file=sys.stderr)

    say(f"acq: scanning host environment for known service tokens (scope: {scope.describe()})...")
    if opts.dry_run:
        say("acq: --dry-run: no values will be written.")
    services = [opts.service] if opts.service else _importable_services()
    results = []
    for svc in services:
        envvar = next((v for v in _import_env_vars(svc) if os.environ.get(v)), None)
        if envvar is None:
            continue
        try:
            results.append(_import_one(svc, envvar, opts, scope, say))
        except secretstore.SecretStoreError as exc:
            return common._operational_failure(
                command, exc.code, f"failed to store '{svc}' ({scope.describe()}): {exc.message}",
                exc.remediation, emit_json,
            )
    imported = sum(1 for r in results if r["outcome"] == "imported")
    skipped = len(results) - imported
    if not results:
        looked = ", ".join(_import_env_vars(opts.service)) if opts.service else (
            "USAI_API_KEY, GITHUB_TOKEN/GH_TOKEN, GITLAB_TOKEN"
        )
        say(f"acq: no known service tokens found in the environment. Looked for: {looked}.")
    data = {
        "scope": scope.label,
        "dry_run": opts.dry_run,
        "mode": opts.mode,
        "results": results,
        "imported": imported,
        "skipped": skipped,
    }
    if emit_json:
        print(json.dumps(envelope.success(command, data)))
    else:
        print(f"secret import done: {imported} imported, {skipped} skipped")
    return errors.EXIT_SUCCESS
