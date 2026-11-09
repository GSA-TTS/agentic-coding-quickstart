"""Deterministic offline fake ``sbx`` for contract vectors (internal test seam).

This models only the observable surface the sbx adapter drives, against a JSON
catalog at ``$SBX_HOME/.docker-sbx/catalog.json`` (or ``$HOME/.docker-sbx/...``),
which the vector runner redirects to a throwaway directory. An initial catalog can
be seeded in-memory via ``ACQ_SBX_STUB_CATALOG`` (JSON ``{name: state}``).

Mirrors the real sbx 0.51.0 CLI surface:

* ``sbx create AGENT [PATH] --name N -t IMAGE`` — the agent + path are positional,
  the name is ``--name``, and the image is ``-t/--template``.
* ``sbx secret set SERVICE [--sandbox NAME]`` (value on stdin, global default),
  ``sbx secret rm SERVICE [--sandbox NAME] -f``, ``sbx secret ls [-g|--sandbox]
  --json``, ``sbx secret rm --placeholder TOKEN [--sandbox NAME] -f``, and ``sbx
  secret set-custom --host H --env E [--placeholder P] --value-stdin [--sandbox
  NAME]`` (value on stdin; a custom secret lands in its own table with a
  placeholder, and ``--placeholder`` naming the existing entry's placeholder
  updates that entry in place, as rotation relies on). Without
  ``-f``, ``secret rm`` asks ``Remove secret? (y/N)`` and reads the answer from
  stdin; end-of-input is "no" and exits 1. There is NO ``secret has``.
* ``sbx settings get/set kit.allowedSources`` — the owner-granular kit allowlist
  the adapter's ``kit_source_revoked`` drives (there is no ``kit-source-revoke``
  subcommand).

The catalog and secret store are backend-native state, not acq authority: acq never
reads them as configuration (ADR-0040m §trust ownership). They are never secrets and
never written to acq output.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path

CATALOG_ENV = "ACQ_SBX_STUB_CATALOG"
VERSION_ENV = "ACQ_SBX_STUB_VERSION"
PORTS_ENV = "ACQ_SBX_STUB_PORTS"
INSPECT_RAW_ENV = "ACQ_SBX_STUB_PORTS_RAW"

# Secret-store knobs. ``ACQ_SBX_STUB_SECRETS`` seeds ``{scope: {service: "set"}}``
# so a single-invocation vector can exercise ``secret ls``/``rm`` against
# pre-existing entries. ``ACQ_SBX_STUB_SECRET_LS_RAW`` forces ``secret ls`` to emit
# a raw (wrong-shape) document. The stub records ONLY scope/service/state — it never
# stores or echoes a secret value (it discards stdin after reading it).
SECRETS_ENV = "ACQ_SBX_STUB_SECRETS"
SECRET_LS_RAW_ENV = "ACQ_SBX_STUB_SECRET_LS_RAW"  # nosec B105 # an env var name

# Raw placeholders in sbx's custom-secrets table (state only, never a value).
RAW_PLACEHOLDERS_ENV = "ACQ_SBX_STUB_RAW_PLACEHOLDERS"

# Seed for sbx's custom-secrets table: a JSON list of ``{scope, env,
# placeholder, targets}`` (state only, never a value).
CUSTOM_SECRETS_ENV = "ACQ_SBX_STUB_CUSTOM_SECRETS"  # nosec B105 # an env var name

# Scopes (comma separated; ``global`` for the global scope) whose ``secret
# set-custom`` fails, so a vector can exercise a partial rotation.
FAIL_CUSTOM_SCOPES_ENV = "ACQ_SBX_STUB_FAIL_CUSTOM_SCOPES"

# ``exec``/``cp`` markers to simulate a real agent writing to stdout/stderr.
EXEC_MARKER = "[stub sbx exec]"
COPY_MARKER = "[stub sbx copy]"

# When ``ACQ_SBX_STUB_FAIL`` names a command, that command fails with a
# distinctive raw stderr line (simulating a backend-native failure).
FAIL_ENV = "ACQ_SBX_STUB_FAIL"
RAW_FAIL_STDERR = "raw backend failure detail: 5c4b3a2"

# Per-subcommand exit-status knobs for child/backend status propagation.
EXEC_EXIT_ENV = "ACQ_SBX_STUB_EXEC_EXIT"
COPY_EXIT_ENV = "ACQ_SBX_STUB_COPY_EXIT"
ECHO_EXIT_ENV = "ACQ_SBX_STUB_EXIT_CODE"

# kit.allowedSources allowlist (owner-granular, e.g. "github.com/acme/"). The
# seed is the initial value only: once a ``settings set`` has written the file,
# reads return what was written, so the adapter's re-read can verify its write.
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
    if seed and not _allowed_sources_path().exists():
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


def _secret_scope(args: list[str]) -> str:
    """Resolve the scope for ``secret set/rm/set-custom``: ``--sandbox NAME`` else global."""
    sbx = _arg_after(args, "--sandbox")
    return sbx if sbx is not None else "global"


def _discard_stdin() -> None:
    """Read stdin to completion and discard it (a value must never be stored)."""
    try:
        sys.stdin.read()
    except OSError:
        pass


def _custom_path() -> Path:
    return _catalog_path().parent / "custom-secrets.json"


def _custom_entry(entry: object) -> dict | None:
    if not isinstance(entry, dict):
        return None
    scope, env, placeholder = entry.get("scope"), entry.get("env"), entry.get("placeholder")
    if not all(isinstance(v, str) and v for v in (scope, env, placeholder)):
        return None
    targets = entry.get("targets")
    return {
        "scope": scope,
        "env": env,
        "placeholder": placeholder,
        "targets": [t for t in targets if isinstance(t, str)] if isinstance(targets, list) else [],
    }


def _load_custom() -> list[dict]:
    """sbx's custom-secrets table: ``[{scope, targets, env, placeholder}]`` (no values).

    Seeded by ``ACQ_SBX_STUB_CUSTOM_SECRETS`` until the first write, then read
    back from the file, so one invocation can both read and change it.
    """
    seed = os.environ.get(CUSTOM_SECRETS_ENV)
    raw: object
    if seed and not _custom_path().exists():
        try:
            raw = json.loads(seed)
        except json.JSONDecodeError:
            return []
    else:
        try:
            raw = json.loads(_custom_path().read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []
    if not isinstance(raw, list):
        return []
    return [e for e in (_custom_entry(item) for item in raw) if e is not None]


def _save_custom(entries: list[dict]) -> None:
    path = _custom_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(entries, sort_keys=True), encoding="utf-8")


def _confirmed(args: list[str]) -> bool:
    """Model sbx's ``Remove? (y/N)`` prompt: ``-f``/``--force`` skips it;
    otherwise one stdin line is the answer, and end-of-input is "no"."""
    if "-f" in args or "--force" in args:
        return True
    print("Remove secret? (y/N) ", end="", file=sys.stderr, flush=True)
    try:
        answer = sys.stdin.readline().strip()
    except OSError:
        answer = ""
    if answer in ("y", "Y", "yes"):
        return True
    print("sbx: aborted", file=sys.stderr)
    return False


def _first_positional(rest: list[str]) -> str | None:
    i = 0
    while i < len(rest):
        if rest[i] == "--sandbox" and i + 1 < len(rest):
            i += 2
            continue
        if rest[i].startswith("-"):
            i += 1
            continue
        return rest[i]
    return None


def _secret_set(rest: list[str], secrets: dict[str, dict[str, str]]) -> int:
    # ``sbx secret set SERVICE [--sandbox NAME]``: the value arrives on stdin and
    # is read then discarded (never stored, echoed, or logged). Only
    # (scope, service) -> "set" is recorded.
    _discard_stdin()
    if _should_fail("secret set"):
        print(RAW_FAIL_STDERR, file=sys.stderr)
        return 1
    service = _first_positional(rest)
    if service is None:
        print("sbx: secret set requires a service", file=sys.stderr)
        return 1
    secrets.setdefault(_secret_scope(rest), {})[service] = "set"
    _save_secrets(secrets)
    return 0


def _secret_set_custom(rest: list[str]) -> int:
    # ``sbx secret set-custom --host H… --env E --value-stdin [--sandbox NAME]``:
    # the value is accepted ONLY on stdin (sbx 0.51.0 ``--value-stdin``) and is
    # read then discarded. An argv-visible ``--value`` is refused outright, so a
    # regression that puts a secret on the command line fails loudly here.
    if any(a == "--value" or a.startswith("--value=") for a in rest):
        print("stub sbx: refusing an argv-visible --value", file=sys.stderr)
        return 2
    env = _arg_after(rest, "--env")
    hosts = [rest[i + 1] for i, a in enumerate(rest[:-1]) if a == "--host"]
    if env is None or not hosts:
        print("sbx: secret set-custom requires --host and --env", file=sys.stderr)
        return 1
    if "--value-stdin" not in rest:
        print("sbx: secret set-custom needs a value (use --value-stdin)", file=sys.stderr)
        return 1
    _discard_stdin()
    if _should_fail("secret set-custom"):
        print(RAW_FAIL_STDERR, file=sys.stderr)
        return 1
    scope = _secret_scope(rest)
    if scope in os.environ.get(FAIL_CUSTOM_SCOPES_ENV, "").split(","):
        print(RAW_FAIL_STDERR, file=sys.stderr)
        return 1
    entries = _load_custom()
    placeholder = _arg_after(rest, "--placeholder")
    same = [e for e in entries if e["scope"] == scope and e["env"] == env]
    if placeholder is not None and same and all(e["placeholder"] == placeholder for e in same):
        for entry in same:
            entry["targets"] = hosts  # updated in place: the placeholder is kept
        _save_custom(entries)
        return 0
    if same:
        print(f"sbx: custom secret for {env} already exists", file=sys.stderr)
        return 1
    if placeholder is None:
        placeholder = "sbx-cs-" + hashlib.sha256(f"{scope}\0{env}".encode()).hexdigest()[:16]
    entries.append({"scope": scope, "env": env, "placeholder": placeholder, "targets": hosts})
    _save_custom(entries)
    return 0


def _secret_rm_placeholder(rest: list[str]) -> int:
    # ``sbx secret rm --placeholder TOKEN [--sandbox NAME] [-f]`` targets sbx's
    # custom-secrets table only (raw placeholders included) and never touches
    # the acq store. With ``--sandbox`` only that scope's entry matches.
    token = _arg_after(rest, "--placeholder")
    if token is None:
        print("sbx: secret rm --placeholder requires a token", file=sys.stderr)
        return 1
    if not _confirmed(rest):
        return 1
    if _should_fail("secret rm"):
        print(RAW_FAIL_STDERR, file=sys.stderr)
        return 1
    sandbox = _arg_after(rest, "--sandbox")
    entries = _load_custom()
    keep = [e for e in entries if e["placeholder"] != token or (sandbox is not None and e["scope"] != sandbox)]
    if len(keep) != len(entries):
        _save_custom(keep)
    placeholders = _load_raw_placeholders()
    if token in placeholders:
        placeholders.remove(token)
        _save_raw_placeholders(placeholders)
    return 0  # idempotent: an absent placeholder is not an error


def _secret_rm(rest: list[str], secrets: dict[str, dict[str, str]]) -> int:
    if "--placeholder" in rest:
        return _secret_rm_placeholder(rest)
    # ``sbx secret rm SERVICE [--sandbox NAME] -f``.
    service = _first_positional(rest)
    if service is None:
        print("sbx: secret rm requires a service", file=sys.stderr)
        return 1
    if not _confirmed(rest):
        return 1
    if _should_fail("secret rm"):
        print(RAW_FAIL_STDERR, file=sys.stderr)
        return 1
    scope = _secret_scope(rest)
    if service not in secrets.get(scope, {}):
        print("sbx: no such secret", file=sys.stderr)
        return 1
    del secrets[scope][service]
    if not secrets[scope]:
        del secrets[scope]
    _save_secrets(secrets)
    return 0


def _secret_ls(rest: list[str], secrets: dict[str, dict[str, str]]) -> int:
    if _should_fail("secret ls"):
        print(RAW_FAIL_STDERR, file=sys.stderr)
        return 1
    raw = os.environ.get(SECRET_LS_RAW_ENV)
    if raw is not None:
        print(raw)
        return 0
    # Scope filter: -g/--global -> "global", --sandbox NAME -> NAME, else all.
    scope_filter: str | None = None
    if "-g" in rest or "--global" in rest:
        scope_filter = "global"
    else:
        scope_filter = _arg_after(rest, "--sandbox")
    entries: list[dict] = []
    for sc, services in secrets.items():
        if scope_filter is not None and sc != scope_filter:
            continue
        for svc in services:
            # Mirrors the real `sbx secret ls --json` entry: {scope, type,
            # name, secret:"(stored)"} — the value is never emitted.
            entries.append({"scope": sc, "type": "service", "name": svc, "secret": "(stored)"})  # nosec B105 # placeholder
    entries.sort(key=lambda e: (e["scope"], e["name"]))
    custom = [
        # {scope, targets, env, placeholder, secret:"(masked)"}, never a value.
        {"scope": e["scope"], "targets": e["targets"], "env": e["env"], "placeholder": e["placeholder"],
         "secret": "(masked)"}  # nosec B105 # a mask, not a value
        for e in _load_custom()
        if scope_filter is None or e["scope"] == scope_filter
    ]
    custom.sort(key=lambda e: (e["scope"], e["env"]))
    # The real `sbx secret ls --json` is an OBJECT envelope, not a bare list.
    print(json.dumps({"secrets": entries, "custom_secrets": custom, "shadowed_services": [], "env_only_count": 0}))
    return 0


def _secret_main(args: list[str]) -> int:
    """Handle ``sbx secret <subcommand> …`` (state only, never a value)."""
    if not args:
        print("sbx: secret requires a subcommand", file=sys.stderr)
        return 1
    sub, rest = args[0], args[1:]
    if sub == "set":
        return _secret_set(rest, _load_secrets())
    if sub == "set-custom":
        return _secret_set_custom(rest)
    if sub == "rm":
        return _secret_rm(rest, _load_secrets())
    if sub == "ls":
        return _secret_ls(rest, _load_secrets())
    print(f"sbx: unrecognized secret subcommand '{sub}'", file=sys.stderr)
    return 1


def _settings_main(args: list[str]) -> int:
    """Handle ``sbx settings get/set kit.allowedSources`` (owner-granular allowlist)."""
    if not args:
        print("sbx: settings requires a subcommand", file=sys.stderr)
        return 1
    sub = args[0]
    rest = args[1:]
    if sub == "get":
        if _should_fail("settings get"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        if rest and rest[0] == "kit.allowedSources":
            print(json.dumps(_load_allowed_sources()))
            return 0
        print("sbx: unsupported settings key", file=sys.stderr)
        return 1
    if sub == "set":
        if _should_fail("settings set"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        if rest and rest[0] == "kit.allowedSources":
            value = rest[1] if len(rest) > 1 else None
            if value is None:
                print("sbx: settings set requires a value", file=sys.stderr)
                return 1
            try:
                parsed = json.loads(value)
            except json.JSONDecodeError:
                print("sbx: kit.allowedSources must be a JSON array", file=sys.stderr)
                return 1
            if not isinstance(parsed, list):
                print("sbx: kit.allowedSources must be a JSON array", file=sys.stderr)
                return 1
            _save_allowed_sources([s for s in parsed if isinstance(s, str)])
            return 0
        print("sbx: unsupported settings key", file=sys.stderr)
        return 1
    print(f"sbx: unrecognized settings subcommand '{sub}'", file=sys.stderr)
    return 1


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

    if cmd == "settings":
        return _settings_main(args[1:])

    catalog = _load()

    if cmd in ("ls", "list"):
        if _should_fail("ls"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        # Real `sbx ls` has only --format/--json/-q (NO --running); --json emits a
        # list of {name, status} objects, and -q/table emit names one per line.
        if "--json" in args or "--format" in args:
            entries = [{"name": name, "status": state} for name, state in catalog.items()]
            entries.sort(key=lambda e: e["name"])
            print(json.dumps(entries))
            return 0
        for sandbox_name in catalog:
            print(sandbox_name)
        return 0

    if cmd == "create":
        if _should_fail("create"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        # ``sbx create AGENT [PATH] --name N -t IMAGE`` — the agent/path/image are
        # positional/flags the stub does not need; the name is the catalog key.
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
        # `sbx exec [-u USER] [-w DIR] [-e K=V] NAME [-- CMD...]` — exit 0 when
        # NAME exists, else 1. The command after `--` is echoed to stdout and the
        # exit status is driven by ``ACQ_SBX_STUB_EXEC_EXIT``.
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
