"""Offline stand-ins for the OS keychain tools the acq secret store drives.

Each fake is a small Python script written into a test directory and run as an
executable, so the store's real subprocess path is exercised end to end (and
the Bash store, sourced in the round-trip tests, can call the very same
fakes). Every fake appends its argv as one JSON line to ``$FAKE_KEYCHAIN_LOG``
so a test can assert that a value never reached argv. Values live as files
under ``$FAKE_KEYCHAIN_DIR``. Nothing here touches a real keychain.
"""

from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

_PRELUDE = '''
import base64, json, os, sys
root = os.environ["FAKE_KEYCHAIN_DIR"]
os.makedirs(root, exist_ok=True)
with open(os.environ["FAKE_KEYCHAIN_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + "\\n")
def path_for(key):
    return os.path.join(root, "".join(c if c.isalnum() or c in "._-" else "_" for c in key))
def after(args, flag):
    return args[args.index(flag) + 1]
'''

# libsecret's secret-tool: `store --label=L acq_key K` (value on stdin),
# `lookup acq_key K`, `clear acq_key K`.
SECRET_TOOL = _PRELUDE + '''
args = sys.argv[1:]
cmd, key = args[0], after(args, "acq_key")
if cmd == "store":
    with open(path_for(key), "wb") as fh:
        fh.write(sys.stdin.buffer.read())
elif cmd == "lookup":
    if not os.path.exists(path_for(key)):
        sys.exit(1)
    with open(path_for(key), "rb") as fh:
        sys.stdout.buffer.write(fh.read())
elif cmd == "clear":
    if os.path.exists(path_for(key)):
        os.remove(path_for(key))
'''

# macOS security: `-i` reads one add-generic-password command from stdin
# (double-quoted tokens with backslash escapes); find prints the value and a
# newline, as the real tool does.
SECURITY = _PRELUDE + '''
def tokens(line):
    out, cur, quoted, esc, have = [], "", False, False, False
    for ch in line:
        if esc:
            cur += ch; esc = False
        elif quoted and ch == "\\\\":
            esc = True
        elif ch == '"':
            quoted = not quoted; have = True
        elif not quoted and ch in " \\t\\n":
            if cur or have:
                out.append(cur)
            cur, have = "", False
        else:
            cur += ch
    if cur or have:
        out.append(cur)
    return out
args = sys.argv[1:]
if args[0] == "-i":
    toks = tokens(sys.stdin.read())
    if not toks or toks[0] != "add-generic-password":
        sys.exit(1)
    with open(path_for(after(toks, "-a")), "w", encoding="utf-8") as fh:
        fh.write(after(toks, "-w"))
elif args[0] == "find-generic-password":
    p = path_for(after(args, "-a"))
    if not os.path.exists(p):
        sys.exit(44)
    with open(p, encoding="utf-8") as fh:
        print(fh.read())
elif args[0] == "delete-generic-password":
    p = path_for(after(args, "-a"))
    if os.path.exists(p):
        os.remove(p)
else:
    sys.exit(1)
'''

# Windows PowerShell running acq's DPAPI one-liners. A reversible, deterministic
# transform stands in for ProtectedData; the mode is picked the way the real
# one-liner differs (Unprotect vs Protect). Both directions carry base64 only,
# as the real one-liners do, and input that is not base64 fails the call. Every
# stdin is appended to $FAKE_KEYCHAIN_DIR/powershell.stdin, one line per call.
# $FAKE_DPAPI_FAIL=1 fails every call.
POWERSHELL = _PRELUDE + '''
if os.environ.get("FAKE_DPAPI_FAIL"):
    sys.exit(1)
script = " ".join(sys.argv[1:])
data = sys.stdin.buffer.read()
with open(os.path.join(root, "powershell.stdin"), "ab") as seen:
    seen.write(data + b"\\n")
try:
    raw = base64.b64decode(data.strip(), validate=True)
except ValueError:
    sys.exit(1)
if "Unprotect" in script:
    if not raw.startswith(b"DPAPI:"):
        sys.exit(1)
    sys.stdout.buffer.write(base64.b64encode(raw[len(b"DPAPI:"):]))
else:
    sys.stdout.buffer.write(base64.b64encode(b"DPAPI:" + raw))
'''


def plant(bin_dir: Path, name: str, body: str) -> Path:
    """Write fake ``name`` into ``bin_dir`` as an executable script."""
    bin_dir.mkdir(parents=True, exist_ok=True)
    path = bin_dir / name
    path.write_text(f"#!{sys.executable}\n{body}", encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def logged_argv(log: Path) -> str:
    """Everything the fakes logged, as one string for `not in` assertions."""
    return log.read_text(encoding="utf-8") if log.exists() else ""


def fake_env(root: Path) -> dict[str, str]:
    return {"FAKE_KEYCHAIN_DIR": str(root / "keychain"), "FAKE_KEYCHAIN_LOG": str(root / "keychain.log")}


def apply_env(monkeypatch, env: dict[str, str]) -> None:
    for name, value in env.items():
        monkeypatch.setenv(name, value)


def prepend_path(monkeypatch, bin_dir: Path) -> None:
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}")
