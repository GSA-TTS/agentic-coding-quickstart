"""Deterministic offline fake ``msb`` for contract vectors (internal test seam).

This models only the observable lifecycle surface the adapter drives — ``--version``,
``list``, ``create``, ``exec``, ``stop``, ``remove`` — against a JSON catalog at
``$MSB_HOME/.microsandbox/catalog.json`` (or ``$HOME/.microsandbox/...``), which the
vector runner redirects to a throwaway directory. An initial catalog can be seeded
in-memory via ``ACQ_MSB_STUB_CATALOG`` (JSON ``{name: state}``) so a single-invocation
vector can exercise ``ls``/``stop``/``rm`` against pre-existing sandboxes.

The catalog is backend-native state, not acq authority: acq never reads it as
configuration (ADR-0040m §trust ownership). It is never a secret and never written
to acq output.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

CATALOG_ENV = "ACQ_MSB_STUB_CATALOG"
VERSION_ENV = "ACQ_MSB_STUB_VERSION"
PORTS_ENV = "ACQ_MSB_STUB_PORTS"
INSPECT_RAW_ENV = "ACQ_MSB_STUB_INSPECT_RAW"

# Secret-store knobs. ``ACQ_MSB_STUB_SECRETS`` seeds ``{scope: {service: "set"}}``
# so a single-invocation vector can exercise ``secret ls``/``has``/``rm`` against
# pre-existing entries. ``ACQ_MSB_STUB_SECRET_LS_RAW`` forces ``secret ls`` to emit
# a raw (wrong-shape) document so a vector can assert the adapter fails closed
# with ``secret_unreadable``. The stub records ONLY scope/service/state — it never
# stores or echoes a secret value (it discards stdin after reading it).
SECRETS_ENV = "ACQ_MSB_STUB_SECRETS"
SECRET_LS_RAW_ENV = "ACQ_MSB_STUB_SECRET_LS_RAW"

# ``exec`` prints this marker to its own stdout to simulate a real agent writing
# to stdout; the adapter's json-mode launch must route it to acq's stderr so the
# CLI stdout stays a single JSON document (ADR-0038m §2).
EXEC_MARKER = "[stub exec]"
COPY_MARKER = "[stub copy]"

# Rotation probe knob. ``ACQ_MSB_STUB_ROTATE`` drives the deterministic
# provider-validation outcome for the ``rotate`` verb: "ok" (default) stores the
# new key; "unreachable" / "auth_failed" fail before any store so the old key is
# left in place (the adapter maps these to provider_unreachable /
# provider_auth_failed). The stub reads and discards the new key on stdin — it
# never stores or echoes a value.
ROTATE_ENV = "ACQ_MSB_STUB_ROTATE"

# When ``ACQ_MSB_STUB_FAIL`` names a command, that command fails with a
# distinctive raw stderr line (simulating a backend-native failure) so a vector
# can assert the raw text never reaches the structured output.
FAIL_ENV = "ACQ_MSB_STUB_FAIL"
RAW_FAIL_STDERR = "raw backend failure detail: 7f3a2c1"

# Per-subcommand exit-status knobs so contract vectors can assert child/backend
# status propagation (ADR-0038m §1) without a real guest. Each defaults to 0.
EXEC_EXIT_ENV = "ACQ_MSB_STUB_EXEC_EXIT"
COPY_EXIT_ENV = "ACQ_MSB_STUB_COPY_EXIT"
ECHO_EXIT_ENV = "ACQ_MSB_STUB_EXIT_CODE"

# ``kit-apply`` markers, mirroring ``EXEC_MARKER``/``COPY_MARKER``, so a vector or
# Tier-2 test can observe the install running (and its idempotency) without a real
# guest. The stub records ONLY the kit name — never the install argv's content as
# a value and never a secret.
KIT_APPLY_MARKER = "[stub kit-apply]"


def _exit_code(env_name: str) -> int:
    raw = os.environ.get(env_name, "0")
    try:
        return int(raw)
    except ValueError:
        return 0


def _should_fail(cmd: str) -> bool:
    return os.environ.get(FAIL_ENV) == cmd


def _catalog_path() -> Path:
    base = os.environ.get("MSB_HOME") or os.environ.get("HOME") or "."
    return Path(base) / ".microsandbox" / "catalog.json"


def _load() -> dict[str, str]:
    seed = os.environ.get(CATALOG_ENV)
    if seed:
        try:
            loaded = json.loads(seed)
        except json.JSONDecodeError:
            return {}
        if isinstance(loaded, dict):
            return {k: v for k, v in loaded.items() if isinstance(v, str)}
        return {}
    try:
        doc = json.loads(_catalog_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if isinstance(doc, dict):
        return {k: v for k, v in doc.items() if isinstance(v, str)}
    return {}


def _save(catalog: dict[str, str]) -> None:
    path = _catalog_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(catalog, sort_keys=True), encoding="utf-8")


def _secrets_path() -> Path:
    return _catalog_path().parent / "secrets.json"


def _load_secrets() -> dict[str, dict[str, str]]:
    """Return the secret store as ``{scope: {service: "set"}}`` (state only).

    The value is never stored: ``"set"`` is a presence marker. A seed via
    ``SECRETS_ENV`` is honored first (single-invocation vectors), else the on-disk
    catalog, else empty.
    """
    seed = os.environ.get(SECRETS_ENV)
    if seed:
        try:
            loaded = json.loads(seed)
        except json.JSONDecodeError:
            return {}
        if isinstance(loaded, dict):
            return {
                k: {s: st for s, st in v.items() if isinstance(st, str)}
                for k, v in loaded.items()
                if isinstance(v, dict)
            }
        return {}
    try:
        doc = json.loads(_secrets_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if isinstance(doc, dict):
        return {
            k: {s: st for s, st in v.items() if isinstance(st, str)}
            for k, v in doc.items()
            if isinstance(v, dict)
        }
    return {}


def _save_secrets(secrets: dict[str, dict[str, str]]) -> None:
    path = _secrets_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(secrets, sort_keys=True), encoding="utf-8")


def _kit_applied_path() -> Path:
    return _catalog_path().parent / "kit-applied.json"


def _load_kit_applied() -> dict[str, list[str]]:
    try:
        doc = json.loads(_kit_applied_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if isinstance(doc, dict):
        return {k: [x for x in v if isinstance(x, str)] for k, v in doc.items() if isinstance(v, list)}
    return {}


def _save_kit_applied(applied: dict[str, list[str]]) -> None:
    path = _kit_applied_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(applied, sort_keys=True), encoding="utf-8")


def _kit_apply_main(args: list[str]) -> int:
    """Handle ``msb kit-apply NAME KIT -- INSTALL...`` (in-guest install model).

    Records the applied kit per sandbox in ``kit-applied.json``; a re-apply of the
    same kit is a no-op (reports "already applied") so the stub models the
    idempotency the real ``nix profile install`` provides. The install argv after
    ``--`` is data (never a secret) and is never stored or echoed as a value.
    """
    name = args[0] if args else None
    kit = args[1] if len(args) > 1 else None
    if name is None or kit is None:
        print("msb: kit-apply requires a sandbox and kit", file=sys.stderr)
        return 1
    catalog = _load()
    if name not in catalog:
        print(f"msb: no such sandbox '{name}'", file=sys.stderr)
        return 1
    applied = _load_kit_applied()
    kits = applied.get(name, [])
    if kit in kits:
        print(f"{KIT_APPLY_MARKER} {kit} already applied")
        return 0
    kits.append(kit)
    applied[name] = kits
    _save_kit_applied(applied)
    print(f"{KIT_APPLY_MARKER} {kit} applied")
    return 0


def _arg_after(args: list[str], flag: str) -> str | None:
    for i, a in enumerate(args):
        if a == flag and i + 1 < len(args):
            return args[i + 1]
    return None


def _secret_scope_service(args: list[str]) -> tuple[str | None, str | None]:
    """Parse ``[--global | SANDBOX] SERVICE`` into ``(scope, service)``."""
    if not args:
        return None, None
    if args[0] in ("-g", "--global"):
        return "global", (args[1] if len(args) > 1 else None)
    return args[0], (args[1] if len(args) > 1 else None)


def _secret_scope_only(args: list[str]) -> str | None:
    """Parse an optional ``[--global | SANDBOX]`` scope filter (``secret ls``)."""
    if not args:
        return None
    if args[0] in ("-g", "--global"):
        return "global"
    return args[0]


def _secret_main(args: list[str]) -> int:
    """Handle ``msb secret <subcommand> …`` (state only, never a value)."""
    if not args:
        print("msb: secret requires a subcommand", file=sys.stderr)
        return 1
    sub = args[0]
    rest = args[1:]
    secrets = _load_secrets()

    if sub == "set":
        # The value arrives on stdin and is read then discarded: it is never
        # stored, echoed, or logged. Only (scope, service) -> "set" is recorded.
        try:
            sys.stdin.read()
        except OSError:
            pass
        scope, service = _secret_scope_service(rest)
        if scope is None or service is None:
            print("msb: secret set requires a scope and service", file=sys.stderr)
            return 1
        secrets.setdefault(scope, {})[service] = "set"
        _save_secrets(secrets)
        return 0

    if sub == "rm":
        scope, service = _secret_scope_service(rest)
        if scope is None or service is None:
            print("msb: secret rm requires a scope and service", file=sys.stderr)
            return 1
        if service not in secrets.get(scope, {}):
            print("msb: no such secret", file=sys.stderr)
            return 1
        del secrets[scope][service]
        if not secrets[scope]:
            del secrets[scope]
        _save_secrets(secrets)
        return 0

    if sub == "ls":
        if _should_fail("secret ls"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        raw = os.environ.get(SECRET_LS_RAW_ENV)
        if raw is not None:
            print(raw)
            return 0
        scope = _secret_scope_only(rest)
        entries: list[dict] = []
        for sc, services in secrets.items():
            if scope is not None and sc != scope:
                continue
            for svc, state in services.items():
                entries.append({"scope": sc, "service": svc, "value_state": state})
        entries.sort(key=lambda e: (e["scope"], e["service"]))
        print(json.dumps(entries))
        return 0

    if sub == "has":
        scope, service = _secret_scope_service(rest)
        if scope is None or service is None:
            print("msb: secret has requires a scope and service", file=sys.stderr)
            return 1
        return 0 if service in secrets.get(scope, {}) else 1

    print(f"msb: unrecognized secret subcommand '{sub}'", file=sys.stderr)
    return 1


def _discard_stdin() -> None:
    """Read stdin to completion and discard it (a value must never be stored)."""
    try:
        sys.stdin.read()
    except OSError:
        pass


def _provider_credential_main(args: list[str]) -> int:
    """Handle ``msb provider-credential <subcommand> …`` (metadata only, never a value)."""
    if not args:
        print("msb: provider-credential requires a subcommand", file=sys.stderr)
        return 1
    sub = args[0]
    if sub != "set":
        print(f"msb: unrecognized provider-credential subcommand '{sub}'", file=sys.stderr)
        return 1
    rest = args[1:]
    provider = rest[0] if rest else None
    key_env = rest[1] if len(rest) > 1 else None
    if provider is None or key_env is None:
        print("msb: provider-credential set requires a provider and key_env", file=sys.stderr)
        return 1
    # The value arrives on stdin and is read then discarded: it is never stored,
    # echoed, or logged. Only (global, provider) -> "set" is recorded so the
    # credential's presence is tracked; the destination pin (key_env + hosts) is
    # host-side authority, never backend state.
    _discard_stdin()
    secrets = _load_secrets()
    secrets.setdefault("global", {})[provider] = "set"
    _save_secrets(secrets)
    return 0


def _github_scope_main(args: list[str]) -> int:
    """Handle ``msb github-scope SANDBOX`` (sandbox-scoped metadata only)."""
    sandbox = args[0] if args else None
    if sandbox is None:
        print("msb: github-scope requires a sandbox name", file=sys.stderr)
        return 1
    # The token arrives on stdin and is read then discarded (never stored/echoed).
    # Only (sandbox, github) -> "set" is recorded; the per-sandbox scope record is
    # host-side authority.
    _discard_stdin()
    secrets = _load_secrets()
    secrets.setdefault(sandbox, {})["github"] = "set"
    _save_secrets(secrets)
    return 0


def _rotate_main(args: list[str]) -> int:
    """Handle ``msb rotate`` — probe the new key, then store only on success.

    Reads and discards the new key on stdin. The deterministic probe outcome is
    driven by ``ACQ_MSB_STUB_ROTATE``: on "unreachable" / "auth_failed" the store
    is skipped (the old key is left in place) and a distinct exit code is
    returned (2 / 3) so the adapter maps it to a stable code.
    """
    _discard_stdin()
    outcome = os.environ.get(ROTATE_ENV, "ok")
    if outcome == "unreachable":
        print(RAW_FAIL_STDERR, file=sys.stderr)
        return 2
    if outcome == "auth_failed":
        print(RAW_FAIL_STDERR, file=sys.stderr)
        return 3
    # ok: replace the old key only now (after the new one was confirmed).
    secrets = _load_secrets()
    secrets.setdefault("global", {})["usai"] = "set"
    _save_secrets(secrets)
    return 0


def main(argv: list[str]) -> int:
    args = argv[1:]
    if not args:
        return 1
    cmd = args[0]

    if cmd in ("--version", "-V"):
        print(f"msb {os.environ.get(VERSION_ENV, '0.7.7')}")
        return 0

    if cmd == "secret":
        return _secret_main(args[1:])

    if cmd == "provider-credential":
        return _provider_credential_main(args[1:])

    if cmd == "github-scope":
        return _github_scope_main(args[1:])

    if cmd == "rotate":
        return _rotate_main(args[1:])

    if cmd == "kit-apply":
        if _should_fail("kit-apply"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        return _kit_apply_main(args[1:])

    catalog = _load()

    if cmd in ("list", "ls"):
        running_only = "--running" in args
        for name, state in catalog.items():
            if running_only and state != "running":
                continue
            print(name)
        return 0

    if cmd == "create":
        if _should_fail("create"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        name = _arg_after(args, "--name")
        if name is None:
            print("msb: create requires --name", file=sys.stderr)
            return 1
        if name in catalog:
            print(f"msb: sandbox '{name}' already exists", file=sys.stderr)
            return 1
        catalog[name] = "running"
        _save(catalog)
        return 0

    if cmd == "exec":
        # `msb exec [-u USER] [-w DIR] [-e K=V] [-t] NAME -- CMD...` — exit 0 when
        # NAME exists (exec-ready), else 1. Flags may precede or follow NAME; the
        # command after `--` is echoed to stdout so a vector can assert verbatim
        # forwarding, and the exit status is driven by ``ACQ_MSB_STUB_EXEC_EXIT``.
        try:
            sep = args.index("--")
        except ValueError:
            sep = len(args)
        head = args[1:sep]
        command = args[sep + 1 :] if sep < len(args) else []
        name = None
        i = 0
        while i < len(head):
            token = head[i]
            if token in ("-u", "-w", "-e") and i + 1 < len(head):
                i += 2
                continue
            if token.startswith("-"):
                i += 1
                continue
            name = token
            i += 1
        if name is None or name not in catalog:
            print(f"msb: no such sandbox '{name}'", file=sys.stderr)
            return 1
        marker = EXEC_MARKER
        if command:
            marker += " " + " ".join(command)
        print(marker)
        return _exit_code(EXEC_EXIT_ENV)

    if cmd in ("copy", "cp"):
        src = args[1] if len(args) > 1 else ""
        dst = args[2] if len(args) > 2 else ""
        print(f"{COPY_MARKER} {src} -> {dst}", file=sys.stderr)
        return _exit_code(COPY_EXIT_ENV)

    if cmd == "inspect":
        if _should_fail("inspect"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        name = args[1] if len(args) > 1 else None
        if name is None or name not in catalog:
            print(f"msb: no such sandbox '{name}'", file=sys.stderr)
            return 1
        raw = os.environ.get(INSPECT_RAW_ENV)
        if raw is not None:
            # A raw inspect payload (a vector feeds a wrong-shape document here so
            # the adapter's shape guard is exercised end to end).
            print(raw)
            return 0
        ports_env = os.environ.get(PORTS_ENV, "")
        try:
            declared = json.loads(ports_env) if ports_env else {}
        except json.JSONDecodeError:
            declared = {}
        if not isinstance(declared, dict):
            declared = {}
        port_list = declared.get(name, [])
        # msb 0.6.7 `inspect --format json` shape (ADR-0014): published ports live
        # at active_config.network.ports[] as {host_port, guest_port, protocol,
        # host_bind}.
        print(json.dumps({"active_config": {"network": {"ports": port_list}}}))
        return 0

    if cmd == "echo":
        # Used only to exercise verbatim passthrough: prints its args and returns
        # ``ACQ_MSB_STUB_EXIT_CODE`` so a vector can assert forwarding + status.
        print(" ".join(args[1:]))
        return _exit_code(ECHO_EXIT_ENV)

    if cmd == "stop":
        if _should_fail("stop"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        name = args[1] if len(args) > 1 else None
        if name is None or name not in catalog:
            print(f"msb: no such sandbox '{name}'", file=sys.stderr)
            return 1
        catalog[name] = "stopped"
        _save(catalog)
        return 0

    if cmd == "remove":
        if _should_fail("remove"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        name = _arg_after(args, "--name")
        if name is None:
            for a in args[1:]:
                if not a.startswith("-"):
                    name = a
                    break
        if name is None or name not in catalog:
            print(f"msb: no such sandbox '{name}'", file=sys.stderr)
            return 1
        del catalog[name]
        _save(catalog)
        return 0

    print(f"msb: unrecognized subcommand '{cmd}'", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
