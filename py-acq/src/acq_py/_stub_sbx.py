"""Deterministic offline fake ``sbx`` for contract vectors (internal test seam).

This models only the observable surface the sbx adapter drives, against a JSON
catalog at ``$SBX_HOME/.docker-sbx/catalog.json`` (or ``$HOME/.docker-sbx/...``),
which the vector runner redirects to a throwaway directory. An initial catalog can
be seeded in-memory via ``ACQ_SBX_STUB_CATALOG`` (JSON ``{name: state}``).

sbx differs from msb in three command names the adapter translates (``ls``/``rm``/
``cp``/``ports`` vs msb's ``list``/``remove``/``copy``/``inspect``) and adds two
sbx-specific proxy-table mechanics the seam exercises:

* **raw-placeholder removal** — ``secret rm --placeholder TOKEN`` removes a raw
  placeholder from sbx's custom-secrets table (ADR-0038m §48) and never touches
  the acq store. Seeded via ``ACQ_SBX_STUB_RAW_PLACEHOLDERS``.
* **kit-source allowlist** — ``kit-source-revoke REPO`` drops the repo's owner
  prefix from ``kit.allowedSources`` so the backend can no longer fetch from that
  owner (ADR-0040m ``kit_source_revoked``). Seeded via
  ``ACQ_SBX_STUB_ALLOWED_SOURCES``.

The catalog and secret store are backend-native state, not acq authority: acq never
reads them as configuration (ADR-0040m §trust ownership). They are never secrets and
never written to acq output.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

CATALOG_ENV = "ACQ_SBX_STUB_CATALOG"
VERSION_ENV = "ACQ_SBX_STUB_VERSION"
PORTS_ENV = "ACQ_SBX_STUB_PORTS"
INSPECT_RAW_ENV = "ACQ_SBX_STUB_PORTS_RAW"

# Secret-store knobs. ``ACQ_SBX_STUB_SECRETS`` seeds ``{scope: {service: "set"}}``
# so a single-invocation vector can exercise ``secret ls``/``has``/``rm`` against
# pre-existing entries. ``ACQ_SBX_STUB_SECRET_LS_RAW`` forces ``secret ls`` to emit
# a raw (wrong-shape) document. The stub records ONLY scope/service/state — it never
# stores or echoes a secret value (it discards stdin after reading it).
SECRETS_ENV = "ACQ_SBX_STUB_SECRETS"
SECRET_LS_RAW_ENV = "ACQ_SBX_STUB_SECRET_LS_RAW"

# Raw placeholders in sbx's custom-secrets table (state only, never a value).
RAW_PLACEHOLDERS_ENV = "ACQ_SBX_STUB_RAW_PLACEHOLDERS"

# ``exec``/``cp`` markers to simulate a real agent writing to stdout/stderr.
EXEC_MARKER = "[stub sbx exec]"
COPY_MARKER = "[stub sbx copy]"

# Rotation probe knob (mirrors the msb stub): "ok" stores the new key;
# "unreachable" / "auth_failed" fail before any store (exit 2 / 3).
ROTATE_ENV = "ACQ_SBX_STUB_ROTATE"

# When ``ACQ_SBX_STUB_FAIL`` names a command, that command fails with a
# distinctive raw stderr line (simulating a backend-native failure).
FAIL_ENV = "ACQ_SBX_STUB_FAIL"
RAW_FAIL_STDERR = "raw backend failure detail: 5c4b3a2"

# Per-subcommand exit-status knobs for child/backend status propagation.
EXEC_EXIT_ENV = "ACQ_SBX_STUB_EXEC_EXIT"
COPY_EXIT_ENV = "ACQ_SBX_STUB_COPY_EXIT"
ECHO_EXIT_ENV = "ACQ_SBX_STUB_EXIT_CODE"

# kit.allowedSources allowlist (owner-granular, e.g. "github.com/acme/").
ALLOWED_SOURCES_ENV = "ACQ_SBX_STUB_ALLOWED_SOURCES"


def _exit_code(env_name: str) -> int:
    raw = os.environ.get(env_name, "0")
    try:
        return int(raw)
    except ValueError:
        return 0


def _should_fail(cmd: str) -> bool:
    return os.environ.get(FAIL_ENV) == cmd


def _home() -> Path:
    return Path(os.environ.get("SBX_HOME") or os.environ.get("HOME") or ".")


def _catalog_path() -> Path:
    return _home() / ".docker-sbx" / "catalog.json"


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
    """Return the managed secret store as ``{scope: {service: "set"}}`` (state only)."""
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


def _raw_placeholders_path() -> Path:
    return _catalog_path().parent / "raw-placeholders.json"


def _load_raw_placeholders() -> list[str]:
    seed = os.environ.get(RAW_PLACEHOLDERS_ENV)
    if seed:
        try:
            loaded = json.loads(seed)
        except json.JSONDecodeError:
            return []
        if isinstance(loaded, list):
            return [p for p in loaded if isinstance(p, str)]
        return []
    try:
        doc = json.loads(_raw_placeholders_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if isinstance(doc, list):
        return [p for p in doc if isinstance(p, str)]
    return []


def _save_raw_placeholders(placeholders: list[str]) -> None:
    path = _raw_placeholders_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(placeholders, sort_keys=True), encoding="utf-8")


def _allowed_sources_path() -> Path:
    return _catalog_path().parent / "allowed-sources.json"


def _load_allowed_sources() -> list[str]:
    seed = os.environ.get(ALLOWED_SOURCES_ENV)
    if seed:
        try:
            loaded = json.loads(seed)
        except json.JSONDecodeError:
            return ["docker.io/"]
        if isinstance(loaded, list):
            return [p for p in loaded if isinstance(p, str)]
        return ["docker.io/"]
    try:
        doc = json.loads(_allowed_sources_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ["docker.io/"]
    if isinstance(doc, list):
        return [p for p in doc if isinstance(p, str)]
    return ["docker.io/"]


def _save_allowed_sources(sources: list[str]) -> None:
    path = _allowed_sources_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(sources, sort_keys=True), encoding="utf-8")


def _arg_after(args: list[str], flag: str) -> str | None:
    for i, a in enumerate(args):
        if a == flag and i + 1 < len(args):
            return args[i + 1]
    return None


def _owner_prefix(repo: str) -> str:
    """sbx's kit.allowedSources is owner-granular: ``host/owner/``."""
    parts = [p for p in repo.split("/") if p]
    if len(parts) >= 2:
        return "/".join(parts[:2]) + "/"
    return repo + "/"


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
    """Handle ``sbx secret <subcommand> …`` (state only, never a value)."""
    if not args:
        print("sbx: secret requires a subcommand", file=sys.stderr)
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
            print("sbx: secret set requires a scope and service", file=sys.stderr)
            return 1
        secrets.setdefault(scope, {})[service] = "set"
        _save_secrets(secrets)
        return 0

    if sub == "rm":
        # Raw-placeholder removal (ADR-0038m §48): `secret rm --placeholder TOKEN`
        # targets sbx's custom-secrets table only and never touches the acq store.
        if rest and rest[0] == "--placeholder":
            token = rest[1] if len(rest) > 1 else None
            if token is None:
                print("sbx: secret rm --placeholder requires a token", file=sys.stderr)
                return 1
            placeholders = _load_raw_placeholders()
            if token in placeholders:
                placeholders.remove(token)
                _save_raw_placeholders(placeholders)
            return 0  # idempotent: an absent placeholder is not an error
        scope, service = _secret_scope_service(rest)
        if scope is None or service is None:
            print("sbx: secret rm requires a scope and service", file=sys.stderr)
            return 1
        if service not in secrets.get(scope, {}):
            print("sbx: no such secret", file=sys.stderr)
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
            print("sbx: secret has requires a scope and service", file=sys.stderr)
            return 1
        return 0 if service in secrets.get(scope, {}) else 1

    print(f"sbx: unrecognized secret subcommand '{sub}'", file=sys.stderr)
    return 1


def _discard_stdin() -> None:
    """Read stdin to completion and discard it (a value must never be stored)."""
    try:
        sys.stdin.read()
    except OSError:
        pass


def _provider_credential_main(args: list[str]) -> int:
    """Handle ``sbx provider-credential <subcommand> …`` (metadata only, never a value)."""
    if not args:
        print("sbx: provider-credential requires a subcommand", file=sys.stderr)
        return 1
    sub = args[0]
    if sub != "set":
        print(f"sbx: unrecognized provider-credential subcommand '{sub}'", file=sys.stderr)
        return 1
    rest = args[1:]
    provider = rest[0] if rest else None
    key_env = rest[1] if len(rest) > 1 else None
    if provider is None or key_env is None:
        print("sbx: provider-credential set requires a provider and key_env", file=sys.stderr)
        return 1
    _discard_stdin()
    secrets = _load_secrets()
    secrets.setdefault("global", {})[provider] = "set"
    _save_secrets(secrets)
    return 0


def _github_scope_main(args: list[str]) -> int:
    """Handle ``sbx github-scope SANDBOX`` (sandbox-scoped metadata only)."""
    sandbox = args[0] if args else None
    if sandbox is None:
        print("sbx: github-scope requires a sandbox name", file=sys.stderr)
        return 1
    _discard_stdin()
    secrets = _load_secrets()
    secrets.setdefault(sandbox, {})["github"] = "set"
    _save_secrets(secrets)
    return 0


def _rotate_main(args: list[str]) -> int:
    """Handle ``sbx rotate`` — probe the new key, then store only on success."""
    _discard_stdin()
    outcome = os.environ.get(ROTATE_ENV, "ok")
    if outcome == "unreachable":
        print(RAW_FAIL_STDERR, file=sys.stderr)
        return 2
    if outcome == "auth_failed":
        print(RAW_FAIL_STDERR, file=sys.stderr)
        return 3
    secrets = _load_secrets()
    secrets.setdefault("global", {})["usai"] = "set"
    _save_secrets(secrets)
    return 0


def _kit_source_revoke_main(args: list[str]) -> int:
    """Handle ``sbx kit-source-revoke REPO`` — drop the owner prefix from the allowlist.

    Idempotent: an absent prefix is not an error. Reports the revoked owner prefix
    on stdout (the "revoked ref") so the adapter can surface it; the repo's kit
    *value* (its ref) is host-held and never crosses this boundary.
    """
    repo = args[0] if args else None
    if repo is None:
        print("sbx: kit-source-revoke requires a repository", file=sys.stderr)
        return 1
    prefix = _owner_prefix(repo)
    sources = _load_allowed_sources()
    if prefix in sources:
        sources = [s for s in sources if s != prefix]
        _save_allowed_sources(sources)
    print(f"revoked {prefix}")
    return 0


def main(argv: list[str]) -> int:
    args = argv[1:]
    if not args:
        return 1
    cmd = args[0]

    if cmd in ("version", "--version", "-V"):
        print(f"sbx {os.environ.get(VERSION_ENV, '0.39.0')}")
        return 0

    if cmd == "secret":
        return _secret_main(args[1:])

    if cmd == "provider-credential":
        return _provider_credential_main(args[1:])

    if cmd == "github-scope":
        return _github_scope_main(args[1:])

    if cmd == "rotate":
        return _rotate_main(args[1:])

    if cmd == "kit-source-revoke":
        return _kit_source_revoke_main(args[1:])

    catalog = _load()

    if cmd in ("ls", "list"):
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
            print("sbx: create requires --name", file=sys.stderr)
            return 1
        if name in catalog:
            print(f"sbx: sandbox '{name}' already exists", file=sys.stderr)
            return 1
        catalog[name] = "running"
        _save(catalog)
        return 0

    if cmd == "exec":
        # `sbx exec [-u USER] [-w DIR] NAME -- CMD...` — exit 0 when NAME exists,
        # else 1. The command after `--` is echoed to stdout and the exit status is
        # driven by ``ACQ_SBX_STUB_EXEC_EXIT``.
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
            print(f"sbx: no such sandbox '{name}'", file=sys.stderr)
            return 1
        marker = EXEC_MARKER
        if command:
            marker += " " + " ".join(command)
        print(marker)
        return _exit_code(EXEC_EXIT_ENV)

    if cmd in ("cp", "copy"):
        src = args[1] if len(args) > 1 else ""
        dst = args[2] if len(args) > 2 else ""
        print(f"{COPY_MARKER} {src} -> {dst}", file=sys.stderr)
        return _exit_code(COPY_EXIT_ENV)

    if cmd == "ports":
        if _should_fail("ports"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        name = args[1] if len(args) > 1 else None
        if name is None or name not in catalog:
            print(f"sbx: no such sandbox '{name}'", file=sys.stderr)
            return 1
        raw = os.environ.get(INSPECT_RAW_ENV)
        if raw is not None:
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
        print(json.dumps({"ports": port_list}))
        return 0

    if cmd == "echo":
        print(" ".join(args[1:]))
        return _exit_code(ECHO_EXIT_ENV)

    if cmd == "stop":
        if _should_fail("stop"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        name = args[1] if len(args) > 1 else None
        if name is None or name not in catalog:
            print(f"sbx: no such sandbox '{name}'", file=sys.stderr)
            return 1
        catalog[name] = "stopped"
        _save(catalog)
        return 0

    if cmd == "rm":
        if _should_fail("rm"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        name = _arg_after(args, "--name")
        if name is None:
            for a in args[1:]:
                if not a.startswith("-"):
                    name = a
                    break
        if name is None or name not in catalog:
            print(f"sbx: no such sandbox '{name}'", file=sys.stderr)
            return 1
        del catalog[name]
        _save(catalog)
        return 0

    print(f"sbx: unrecognized subcommand '{cmd}'", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
