"""Every tracked shell script is pinned to LF line endings in .gitattributes.

Git for Windows defaults to core.autocrlf=true. A shell script without an
``eol=lf`` attribute is checked out with CRLF endings there, and bash under Git
Bash fails on the carriage returns, so a plain Windows clone of acq would not
run. This guard keeps a new shell script from slipping past the pins.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SHELL_SUFFIXES = (".sh", ".bash", ".bats")
SHELL_INTERPRETERS = ("sh", "bash", "bats", "dash", "zsh")

pytestmark = pytest.mark.skipif(
    shutil.which("git") is None or not (REPO_ROOT / ".git").exists(),
    reason="needs a git checkout of the repository",
)


def _git(*args: str, stdin: bytes | None = None) -> bytes:
    return subprocess.run(
        ["git", "-C", str(REPO_ROOT), *args],
        input=stdin,
        capture_output=True,
        check=True,
    ).stdout


def _is_shell_shebang(first_line: bytes) -> bool:
    if not first_line.startswith(b"#!"):
        return False
    words = first_line[2:].decode("utf-8", "replace").split()
    if not words:
        return False
    # "#!/usr/bin/env bash" names the interpreter in its second word.
    interpreter = words[1] if Path(words[0]).name == "env" and len(words) > 1 else words[0]
    return Path(interpreter).name in SHELL_INTERPRETERS


def _tracked_shell_scripts() -> list[str]:
    scripts = []
    # Regular files only: mode 160000 entries are the vendored bats submodules,
    # which carry their own attributes.
    for entry in _git("ls-files", "-s", "-z").split(b"\0"):
        if not entry:
            continue
        meta, _, name = entry.partition(b"\t")
        if meta.split()[0] == b"160000":
            continue
        path = name.decode("utf-8")
        if path.endswith(SHELL_SUFFIXES):
            scripts.append(path)
            continue
        try:
            with open(REPO_ROOT / path, "rb") as fh:
                first = fh.readline(256)
        except OSError:
            continue
        if _is_shell_shebang(first):
            scripts.append(path)
    return sorted(scripts)


def test_shebang_detection():
    assert _is_shell_shebang(b"#!/bin/sh\n")
    assert _is_shell_shebang(b"#!/usr/bin/env bash\n")
    assert _is_shell_shebang(b"#!/usr/bin/env bats\n")
    assert not _is_shell_shebang(b"#!/usr/bin/env python3\n")
    assert not _is_shell_shebang(b"# not a shebang\n")


def test_tracked_shell_scripts_are_pinned_lf():
    scripts = _tracked_shell_scripts()
    # The launcher and the adapters are the scripts a Windows clone runs first.
    assert {"acq", "acq-python", "acq.backends/msb.sh"} <= set(scripts)
    out = _git("check-attr", "-z", "--stdin", "eol", stdin="\0".join(scripts).encode() + b"\0")
    fields = out.split(b"\0")
    eol = {fields[i].decode(): fields[i + 2].decode() for i in range(0, len(fields) - 2, 3)}
    unpinned = [path for path in scripts if eol.get(path) != "lf"]
    assert not unpinned, f"add these shell scripts to .gitattributes with 'text eol=lf': {unpinned}"


def test_tracked_shell_scripts_are_lf_in_the_index():
    # The pin keeps the checkout LF only if the stored content is LF too.
    scripts = set(_tracked_shell_scripts())
    crlf = []
    for line in _git("ls-files", "--eol", "-z").split(b"\0"):
        if not line:
            continue
        info, _, path = line.decode("utf-8").partition("\t")
        if path in scripts and not info.startswith("i/lf"):
            crlf.append(f"{path} ({info.split()[0]})")
    assert not crlf, f"shell scripts not stored with LF endings: {crlf}"
