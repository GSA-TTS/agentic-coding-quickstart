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
