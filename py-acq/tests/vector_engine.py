"""Pytest vector-runner engine (ADR-0043m).

This is the "how" half of the language-neutral test-vector corpus: it loads a
vector JSON file, drives the CLI-under-test as a subprocess, applies the declared
normalisation transforms, and compares against the expected result. The Bash
runner (``scripts/run-vectors``) implements the same transforms and modes
independently; the sentinel corpus proves the two stay in lock-step.

Contract (see ``test/vectors/README.md``):
    * assertion modes: ``exact``, ``contains``, ``json``
    * normalisation transforms: ``abspath``, ``tmpdir``, ``crlf``, ``timing``,
      ``order``, ``json`` (exact-by-default; only declared transforms apply)

The ``{acq}`` token in ``invoke.argv[0]`` splices the CLI-under-test command
list; the ``{python}`` token splices the interpreter for deterministic sentinel
subjects.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ABSPATH_RE = re.compile(r"/[^ \t\r\n\"']+")
TIMING_RE = re.compile(r"[0-9]+(?:\.[0-9]+)?(?:ms|us|µs|s)")

# Throwaway redirects applied to every vector so an oracle can never read or
# mutate the developer's real HOME/XDG state (ADR-0039m).
DEFAULT_REDIRECTS = (
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "XDG_CACHE_HOME",
)

TRANSFORMS = ("abspath", "tmpdir", "crlf", "timing", "order", "json")
MODES = ("exact", "contains", "json")


class VectorError(Exception):
    """Raised for a malformed or non-conformant vector."""


def current_platform() -> str:
    if os.name == "nt":
        return "windows"
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "macos"
    return "linux"


def _tmpdir_transform(text: str) -> str:
    roots = sorted({tempfile.gettempdir(), "/tmp"}, key=len, reverse=True)
    for root in roots:
        text = text.replace(root, "<tmpdir>")
    return text


def _order_transform(text: str) -> str:
    had_nl = text.endswith("\n")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    ordered = sorted(lines)
    out = "\n".join(ordered)
    return out + "\n" if had_nl else out


def _json_transform(text: str) -> str:
    try:
        value = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return text
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def apply_transforms(text: str, transforms: list[str]) -> str:
    for name in transforms:
        if name == "abspath":
            text = ABSPATH_RE.sub("<abspath>", text)
        elif name == "tmpdir":
            text = _tmpdir_transform(text)
        elif name == "crlf":
            text = text.replace("\r\n", "\n")
        elif name == "timing":
            text = TIMING_RE.sub("<timing>", text)
        elif name == "order":
            text = _order_transform(text)
        elif name == "json":
            text = _json_transform(text)
        else:
            raise VectorError(f"unknown normalisation transform: {name!r}")
    return text


def compare(actual: str, expected, mode: str, label: str) -> None:
    if mode == "exact":
        if actual != expected:
            raise AssertionError(f"{label}: expected exact {expected!r}, got {actual!r}")
    elif mode == "contains":
        if expected not in actual:
            raise AssertionError(f"{label}: expected {expected!r} in {actual!r}")
    elif mode == "json":
        try:
            parsed = json.loads(actual)
        except json.JSONDecodeError as exc:
            raise AssertionError(f"{label}: output is not valid JSON: {exc}") from exc
        if parsed != expected:
            raise AssertionError(f"{label}: JSON mismatch\n  expected: {expected!r}\n  actual:   {parsed!r}")
    else:
        raise VectorError(f"unknown assertion mode: {mode!r}")


def resolve_tokens(argv: list[str], acq_cmd: list[str], python_exe: str) -> list[str]:
    out: list[str] = []
    for token in argv:
        if token == "{acq}":
            out.extend(acq_cmd)
        elif token == "{python}":
            out.append(python_exe)
        else:
            out.append(token)
    return out


def discover_vectors(corpus_root: Path) -> list[tuple[str, Path]]:
    """Return ``(id, path)`` pairs for every vector file under ``<section>/<id>.json``.

    The top-level ``manifest.json`` is not a vector and is not returned.
    """
    results: list[tuple[str, Path]] = []
    for section in sorted(p for p in corpus_root.iterdir() if p.is_dir()):
        for path in sorted(section.glob("*.json")):
            results.append((f"{section.name}/{path.stem}", path))
    return results


def load_vector(path: Path) -> dict:
    try:
        vector = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise VectorError(f"{path}: unreadable/invalid vector: {exc}") from exc
    _validate(vector, path)
    return vector


def _validate(vector: dict, path: Path) -> None:
    missing = [k for k in ("schema", "id", "oracle", "tier", "invoke", "expect") if k not in vector]
    if missing:
        raise VectorError(f"{path}: missing required field(s): {', '.join(missing)}")
    invoke = vector.get("invoke", {})
    expect = vector.get("expect", {})
    if "argv" not in invoke:
        raise VectorError(f"{path}: invoke.argv is required")
    if "exit" not in expect:
        raise VectorError(f"{path}: expect.exit is required")


def run_vector(
    vector: dict,
    *,
    acq_cmd: list[str],
    python_exe: str,
    corpus_root: Path,
    workdir: Path,
) -> None:
    invoke = vector.get("invoke", {})
    expect = vector.get("expect", {})
    isolation = vector.get("isolation", {})

    if isolation.get("offline") is False:
        raise VectorError(f"{vector['id']}: isolation.offline=false (network) is not supported by this runner")
    if isolation.get("ssh_stubs") is True:
        raise VectorError(f"{vector['id']}: isolation.ssh_stubs=true is not supported by this runner")

    argv = resolve_tokens(invoke.get("argv", []), acq_cmd, python_exe)
    env = dict(os.environ)
    for name in invoke.get("unset", []):
        env.pop(name, None)
    for name, value in invoke.get("env", {}).items():
        env[name] = str(value)
    for name in DEFAULT_REDIRECTS + tuple(isolation.get("redirect", [])):
        env[name] = str(workdir / "redirect" / name)

    stdin = invoke.get("stdin") or ""
    timeout = (invoke.get("timeout_ms") or 5000) / 1000.0

    # Capture raw bytes and decode UTF-8 ourselves. "Byte-exact" (ADR-0043m)
    # means no universal-newlines translation; the `crlf` transform exists
    # precisely so runners normalize line endings explicitly.
    try:
        proc = subprocess.run(
            argv,
            cwd=str(corpus_root),
            env=env,
            input=stdin.encode("utf-8") if stdin else None,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(f"{vector['id']}: timed out after {timeout}s") from exc
    except OSError as exc:
        raise AssertionError(f"{vector['id']}: failed to execute {argv!r}: {exc}") from exc

    if proc.returncode != expect.get("exit"):
        raise AssertionError(
            f"{vector['id']}: expected exit {expect.get('exit')}, got {proc.returncode}\n"
            f"  stderr: {proc.stderr!r}"
        )

    raw_stdout = proc.stdout.decode("utf-8")
    raw_stderr = proc.stderr.decode("utf-8")

    for stream in ("stdout", "stderr"):
        spec = expect.get(stream)
        if spec is None:
            continue
        mode = spec.get("mode", "exact")
        if mode not in MODES:
            raise VectorError(f"{vector['id']}: unknown mode {mode!r}")
        transforms = spec.get("normalize", [])
        unknown = [t for t in transforms if t not in TRANSFORMS]
        if unknown:
            raise VectorError(f"{vector['id']}: unknown transform(s) {unknown}")
        actual = raw_stdout if stream == "stdout" else raw_stderr
        compare(apply_transforms(actual, transforms), spec.get("value"), mode, f"{vector['id']}.{stream}")
