"""Run a contract vector that needs acq state set up by earlier acq calls.

Usage (from a vector's ``invoke.argv``)::

    {python} -I test/vectors/drivers/seeded-run.py STEPS {acq}

ADR-0043m vectors are one CLI invocation with no fixtures, and the runners do
not implement ``invoke.fixtures`` yet. A vector whose oracle needs a seeded acq
secret store runs this driver instead (the deviation is recorded in the
coverage manifest). ``STEPS`` is a JSON array of ``[ARGS, FEED_STDIN, EXPECTED_EXIT]``;
each step runs ``{acq} ARGS`` in the vector's isolated environment. The vector's
stdin (a sentinel secret value) is fed only to steps with ``FEED_STDIN`` true.

Exactly one step has ``EXPECTED_EXIT`` null: it is the observed invocation, and
its stdout, stderr and exit status become the vector's result. Every other step,
before or after it, must exit with its expected status. The driver exits 1 with
a message (and no stdout) if a step exits otherwise or if the sentinel appears
in any step's stdout or stderr, so a leak fails the vector.

A step may instead be a JSON object that sets up a fixture acq cannot create
through its own CLI:

* ``{"git_repos": {"NAME": "REMOTE_URL", ...}}`` creates a workspace in a
  temporary directory holding one git repository per NAME, each with
  ``remote.origin.url`` set (no network). Later steps get the workspace path in
  place of a literal ``{workspace}`` argument, and run with git discovery capped
  at the temporary directory. ``{"git_repos": {}}`` gives an empty workspace
  outside any repository, for a vector whose stderr must not depend on the
  checkout it runs from (create and run note a workspace's GitHub repositories).
* ``{"git_workspace": true}`` creates a workspace in a temporary directory
  that is itself a git repository root with one committed file (no remote,
  no network), for the clone-mode vectors. Later steps get its path for
  ``{workspace}``, with git discovery capped at the temporary directory.
* ``{"binding_record": PROVIDER, "text": TEXT}`` writes TEXT as PROVIDER's
  provider-credential binding record, at the path acq's state layout gives it
  (``<state root>/provider-credentials/<provider>.<first 8 hex of sha256>.json``).
* ``{"bash_state": PATH, "text": TEXT}`` writes TEXT as a file the Bash acq
  keeps, at PATH relative to its provenance root (``$ACQ_PROVENANCE_DIR``, else
  ``<XDG state home>/acq/provenance``), for example
  ``msb/<name>.<cksum of name>.env``. PATH must be relative and free of ``..``.
* ``{"lock_bindings": true}`` makes every binding record undeletable: each
  record is made read-only (Windows refuses to delete a read-only file) and the
  directory loses write permission (POSIX refuses to unlink in it). Permissions
  are restored when the driver ends. A superuser can still delete, so a vector
  using this cannot pass when run as root.
* ``{"env": {"NAME": VALUE, ...}}`` changes the environment of later steps: a
  string sets NAME, null unsets it. Only backend stub knobs (``ACQ_MSB_STUB_*``
  and ``ACQ_SBX_STUB_*``) may be changed. A vector uses it to clear a stub
  failure knob between a failing call and the retry that must fix it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


_STUB_KNOB_RE = re.compile(r"ACQ_(?:MSB|SBX)_STUB_[A-Z0-9_]+")


def _state_root() -> Path:
    override = os.environ.get("ACQ_STATE_DIR")
    if override:
        return Path(override)
    xdg = os.environ.get("XDG_STATE_HOME")
    base = Path(xdg) if xdg and os.path.isabs(xdg) else Path.home() / ".local" / "state"
    return base / "acq"


def _binding_dir() -> Path:
    return _state_root() / "provider-credentials"


def _binding_path(provider: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", provider)
    digest = hashlib.sha256(provider.encode("utf-8")).hexdigest()[:8]
    return _binding_dir() / f"{safe}.{digest}.json"


def _bash_provenance_root() -> Path:
    override = os.environ.get("ACQ_PROVENANCE_DIR")
    if override:
        return Path(override)
    xdg = os.environ.get("XDG_STATE_HOME")
    base = Path(xdg) if xdg and os.path.isabs(xdg) else Path.home() / ".local" / "state"
    return base / "acq" / "provenance"


def _bash_state(rel: str, text: str) -> None:
    parts = rel.split("/")
    if not rel or rel.startswith("/") or ".." in parts or "\\" in rel or ":" in rel:
        raise ValueError(f"bash_state path must be relative: {rel!r}")
    path = _bash_provenance_root().joinpath(*parts)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _git_repos(repos: dict, root: Path, env: dict) -> Path:
    git = shutil.which("git")
    if git is None:
        raise RuntimeError("git is not installed")
    clean = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    workspace = root / "ws"
    workspace.mkdir()  # exists even with no repositories: a workspace with none
    for name, url in repos.items():
        repo = workspace / name
        repo.mkdir(parents=True)
        subprocess.run([git, "init", "-q", str(repo)], env=clean, check=True, capture_output=True)
        subprocess.run([git, "-C", str(repo), "config", "remote.origin.url", url], env=clean, check=True,
                       capture_output=True)
    env["GIT_CEILING_DIRECTORIES"] = str(root)
    return workspace


def _git_workspace(root: Path, env: dict) -> Path:
    git = shutil.which("git")
    if git is None:
        raise RuntimeError("git is not installed")
    clean = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    clean["GIT_CONFIG_NOSYSTEM"] = "1"
    workspace = root / "ws"
    workspace.mkdir()
    (workspace / "file.txt").write_text("one\n", encoding="utf-8")
    ident = ["-c", "user.name=vector", "-c", "user.email=vector@example.invalid", "-c", "commit.gpgsign=false"]
    for args in (["init", "-q"], ["add", "file.txt"], [*ident, "commit", "-q", "-m", "init"]):
        subprocess.run([git, "-C", str(workspace), *args], env=clean, check=True, capture_output=True)
    env["GIT_CEILING_DIRECTORIES"] = str(root)
    return workspace


def _lock_bindings(locked: list[tuple[Path, int]]) -> None:
    directory = _binding_dir()
    for record in directory.glob("*.json"):
        locked.append((record, stat.S_IMODE(record.stat().st_mode)))
        record.chmod(stat.S_IREAD)
    locked.append((directory, stat.S_IMODE(directory.stat().st_mode)))
    directory.chmod(stat.S_IREAD | stat.S_IEXEC)


def _fixture(step: dict, root: Path, env: dict, locked: list) -> str | None:
    """Apply one fixture step; returns the workspace path when it created one."""
    if "git_repos" in step:
        return str(_git_repos(step["git_repos"], root, env))
    if step.get("git_workspace") is True:
        return str(_git_workspace(root, env))
    if "binding_record" in step:
        path = _binding_path(step["binding_record"])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(step["text"], encoding="utf-8")
        return None
    if "bash_state" in step:
        _bash_state(step["bash_state"], step["text"])
        return None
    if step.get("lock_bindings"):
        _lock_bindings(locked)
        return None
    if isinstance(step.get("env"), dict):
        for name in step["env"]:
            if not _STUB_KNOB_RE.fullmatch(name):
                raise ValueError(f"env step may only change ACQ_MSB_STUB_* / ACQ_SBX_STUB_* knobs, not {name!r}")
        for name, value in step["env"].items():
            if value is None:
                env.pop(name, None)
            else:
                env[name] = str(value)
        return None
    raise ValueError(f"unknown fixture step {step!r}")


def _run(steps: list, acq: list[str], value: bytes, root: Path, locked: list) -> int:
    env = dict(os.environ)
    workspace = None
    observed = None
    for step in steps:
        if isinstance(step, dict):
            workspace = _fixture(step, root, env, locked) or workspace
            continue
        args, feed, want = step
        args = [workspace if a == "{workspace}" and workspace else a for a in args]
        proc = subprocess.run([*acq, *args], input=value if feed else b"", capture_output=True, env=env)
        if value and (value in proc.stdout or value in proc.stderr):
            print("seeded-run: the secret value appeared in acq output", file=sys.stderr)
            return 1
        if want is None:
            observed = proc
        elif proc.returncode != want:
            print(f"seeded-run: {' '.join(args)} exited {proc.returncode}, expected {want}", file=sys.stderr)
            return 1
    assert observed is not None
    sys.stdout.buffer.write(observed.stdout)
    sys.stderr.buffer.write(observed.stderr)
    return observed.returncode


def main(argv: list[str]) -> int:
    steps = json.loads(argv[1])
    acq = argv[2:]
    if not acq or [s[2] for s in steps if not isinstance(s, dict)].count(None) != 1:
        print("seeded-run: need STEPS with exactly one observed step, then the acq command", file=sys.stderr)
        return 2
    value = sys.stdin.buffer.read()
    locked: list[tuple[Path, int]] = []
    with tempfile.TemporaryDirectory(prefix="seeded-run-") as tmp:
        try:
            return _run(steps, acq, value, Path(tmp), locked)
        finally:
            for path, mode in reversed(locked):
                path.chmod(mode)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
