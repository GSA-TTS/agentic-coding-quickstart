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
        # NAME exists (exec-ready), else 1. The sandbox name is the first
        # non-flag token before the `--` separator.
        name = None
        i = 1
        while i < len(args):
            token = args[i]
            if token == "--":
                break
            if token in ("-u", "-w", "-e") and i + 1 < len(args):
                i += 2
                continue
            if token.startswith("-"):
                i += 1
                continue
            name = token
            break
        if name is None or name not in catalog:
            print(f"msb: no such sandbox '{name}'", file=sys.stderr)
            return 1
        return 0

    if cmd == "stop":
        name = args[1] if len(args) > 1 else None
        if name is None or name not in catalog:
            print(f"msb: no such sandbox '{name}'", file=sys.stderr)
            return 1
        catalog[name] = "stopped"
        _save(catalog)
        return 0

    if cmd == "remove":
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
