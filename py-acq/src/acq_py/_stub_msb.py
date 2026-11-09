"""Deterministic offline fake ``msb`` for contract vectors (internal test seam).

Mirrors the real msb 0.7.11 CLI surface the adapter drives: ``--version``, ``list``/
``ls`` (with ``-q``/``--running``), ``create --name N [--secret ENV@HOST]... [IMAGE]``,
``modify NAME [--secret ENV@HOST]... [--secret-rm ENV]...``, ``exec -u USER NAME
-- CMD``, ``stop``, ``remove -f``, ``copy``, and ``inspect NAME --format json`` —
against a JSON catalog at ``$MSB_HOME/.microsandbox/catalog.json`` (or
``$HOME/.microsandbox/...``), which the vector runner redirects to a throwaway
directory. An initial catalog can be seeded in-memory via ``ACQ_MSB_STUB_CATALOG``
(JSON ``{name: state}``).

``--secret ENV@HOST`` is checked the way it must work against the real msb, which
reads ENV from its own environment: the variable must be set, an inline
``ENV=VALUE`` form is refused, and the bound value must not appear inside any
argv element (a ``--flag=VALUE`` embedding included). The stub records each
sandbox's bindings in ``secrets.json`` next to the catalog as ``{name: {ENV:
{host, env_present}}}``: whether the variable was present, never its value.

``create`` also records each ``--volume HOST:GUEST[:ro]`` in ``mounts.json``,
and ``inspect`` reports them as ``active_config.mounts`` (``{guest, host, type:
"Bind", options: {readonly}}``), which is what acq reads to confirm a read-only
mount. ``ACQ_MSB_STUB_MOUNT_RW`` names sandboxes (comma separated) whose mounts
inspect reports as writable, and ``ACQ_MSB_STUB_RO_WRITABLE`` names sandboxes
whose guest write probe (an ``exec`` whose command mentions ``.acq-ro-probe``)
reports the read-only mount writable (exit 2). ``ACQ_MSB_STUB_NO_AGENT_USER``
names sandboxes whose image has no ``agent`` user: ``exec -u agent`` fails there.

``modify`` models the conservative reading of msb's "add or rotate": ``--secret
ENV@HOST`` for a variable already bound to the SAME hosts rotates it, but one
bound to OTHER hosts is an error (no assumption that it is replaced), and
``--secret-rm`` of a variable that is not bound is an error.
``ACQ_MSB_STUB_FAIL_ADD`` / ``ACQ_MSB_STUB_FAIL_RM`` name sandboxes (comma
separated) whose ``modify --secret`` / ``--secret-rm`` fails.

msb 0.7.11 has NO ``secret``/``kit-apply``/``substrate-provision``/
``provider-credential``/``github-scope``/``rotate`` subcommands, so the stub models
none of them: any such token is an "unrecognized subcommand" (exit 1), matching the
real CLI. The catalog is backend-native state, not acq authority: acq never reads
it as configuration (ADR-0040m §trust ownership). It is never a secret and never
written to acq output.
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

# ``exec`` prints this marker to its own stdout to simulate a real agent writing
# to stdout; the adapter's json-mode launch must route it to acq's stderr so the
# CLI stdout stays a single JSON document (ADR-0038m §2).
EXEC_MARKER = "[stub exec]"
COPY_MARKER = "[stub copy]"

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
    return _catalog_path().with_name("secrets.json")


def _load_secrets() -> dict[str, dict]:
    try:
        doc = json.loads(_secrets_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return {k: v for k, v in doc.items() if isinstance(v, dict)} if isinstance(doc, dict) else {}


def _save_secrets(records: dict[str, dict]) -> None:
    path = _secrets_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(records, sort_keys=True), encoding="utf-8")


MOUNT_RW_ENV = "ACQ_MSB_STUB_MOUNT_RW"
NO_AGENT_USER_ENV = "ACQ_MSB_STUB_NO_AGENT_USER"
RO_WRITABLE_ENV = "ACQ_MSB_STUB_RO_WRITABLE"


def _named(env_name: str, name: str | None) -> bool:
    return name is not None and name in os.environ.get(env_name, "").split(",")


def _mounts_path() -> Path:
    return _catalog_path().with_name("mounts.json")


def _load_mounts() -> dict[str, list]:
    try:
        doc = json.loads(_mounts_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return {k: v for k, v in doc.items() if isinstance(v, list)} if isinstance(doc, dict) else {}


def _save_mounts(records: dict[str, list]) -> None:
    path = _mounts_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(records, sort_keys=True), encoding="utf-8")


def _volume_mounts(args: list[str]) -> list[dict]:
    """``--volume HOST:GUEST[:ro]`` flags as msb inspect mount records."""
    out = []
    for spec in _flag_values(args, "--volume"):
        readonly = spec.endswith(":ro")
        host, _, guest = (spec[:-3] if readonly else spec).rpartition(":")
        out.append({"guest": guest, "host": host, "type": "Bind", "options": {"readonly": readonly}})
    return out


def _inspect_mounts(name: str) -> list[dict]:
    mounts = _load_mounts().get(name, [])
    if _named(MOUNT_RW_ENV, name):
        mounts = [{**m, "options": {"readonly": False}} for m in mounts]
    return mounts


def _flag_values(args: list[str], flag: str) -> list[str]:
    return [args[i + 1] for i, a in enumerate(args) if a == flag and i + 1 < len(args)]


def _apply_secrets(args: list[str], bindings: dict) -> str | None:
    """Apply ``--secret``/``--secret-rm`` flags to ``bindings``; return an error.

    Records only the host and whether the variable was present. A value is read
    solely to prove it is absent from argv and is never stored or printed.
    """
    for spec in _flag_values(args, "--secret"):
        env, sep, host = spec.partition("@")
        if not sep or not env or not host or "=" in env:
            return "invalid --secret: expected ENV@HOST (inline values are rejected)"
        value = os.environ.get(env)
        if value is None:
            return f"host environment variable {env} is not set"
        if value and any(value in a for a in args):
            return f"the value of {env} was found on the command line"
        if env in bindings and bindings[env].get("host") != host:
            return f"secret {env} is already bound to other hosts; remove it first"
        bindings[env] = {"host": host, "env_present": True}
    for env in _flag_values(args, "--secret-rm"):
        if env not in bindings:
            return f"no secret named {env}"
        del bindings[env]
    return None


def _arg_after(args: list[str], flag: str) -> str | None:
    for i, a in enumerate(args):
        if a == flag and i + 1 < len(args):
            return args[i + 1]
    return None


def main(argv: list[str]) -> int:
    args = argv[1:]
    if not args:
        return 1
    cmd = args[0]

    if cmd in ("--version", "-V"):
        print(f"msb {os.environ.get(VERSION_ENV, '0.7.7')}")
        return 0

    catalog = _load()

    if cmd in ("list", "ls"):
        running_only = "--running" in args
        for sandbox_name, state in catalog.items():
            if running_only and state != "running":
                continue
            print(sandbox_name)
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
        bindings: dict = {}
        problem = _apply_secrets(args, bindings)
        if problem is not None:
            print(f"msb: {problem}", file=sys.stderr)
            return 1
        catalog[name] = "running"
        _save(catalog)
        records = _load_secrets()
        records[name] = bindings
        _save_secrets(records)
        mounts = _load_mounts()
        mounts[name] = _volume_mounts(args)
        _save_mounts(mounts)
        return 0

    if cmd == "modify":
        if _should_fail("modify"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
        name = args[1] if len(args) > 1 else None
        if name is None or name not in catalog:
            print(f"msb: no such sandbox '{name}'", file=sys.stderr)
            return 1
        for knob, flag in (("ACQ_MSB_STUB_FAIL_ADD", "--secret"), ("ACQ_MSB_STUB_FAIL_RM", "--secret-rm")):
            if flag in args and name in os.environ.get(knob, "").split(","):
                print(RAW_FAIL_STDERR, file=sys.stderr)
                return 1
        records = _load_secrets()
        bindings = records.get(name, {})
        problem = _apply_secrets(args, bindings)
        if problem is not None:
            print(f"msb: {problem}", file=sys.stderr)
            return 1
        records[name] = bindings
        _save_secrets(records)
        return 0

    if cmd == "exec":
        if _should_fail("exec"):
            print(RAW_FAIL_STDERR, file=sys.stderr)
            return 1
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
        if any(".acq-ro-probe" in token for token in command) and _named(RO_WRITABLE_ENV, name):
            return 2
        if _arg_after(head, "-u") == "agent" and _named(NO_AGENT_USER_ENV, name):
            print("msb: unable to find user agent", file=sys.stderr)
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
        print(json.dumps({"active_config": {"network": {"ports": port_list}, "mounts": _inspect_mounts(name)}}))
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
        records = _load_secrets()
        if records.pop(name, None) is not None:
            _save_secrets(records)
        mounts = _load_mounts()
        if mounts.pop(name, None) is not None:
            _save_mounts(mounts)
        return 0

    print(f"msb: unrecognized subcommand '{cmd}'", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
