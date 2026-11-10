"""Pytest vector-runner engine (ADR-0043m).

This is the "how" half of the language-neutral test-vector corpus: it loads a
vector JSON file, drives the CLI-under-test as a subprocess, applies the declared
normalisation transforms, and compares against the expected result. The Bash
runner (``scripts/run-vectors``) implements the same transforms and modes
independently; the sentinel corpus proves the two stay in lock-step.

Contract (see ``test/vectors/README.md``):
    * assertion modes: ``exact``, ``contains``, ``json``, ``absent``
    * normalisation transforms: ``abspath``, ``tmpdir``, ``crlf``, ``timing``,
      ``order``, ``json`` (exact-by-default; only declared transforms apply)
    * ``expect.stdout`` / ``expect.stderr`` is one assertion or a non-empty list
      of assertions, each applied to the raw stream
    * a field the schema does not define makes the vector invalid

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

# The excluded characters are spelled out (ASCII whitespace and both quotes)
# rather than written as \s, whose Unicode meaning the Bash runner's sed does
# not share.
ABSPATH_RE = re.compile(r"/[^ \t\n\r\v\f\"']+")
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
MODES = ("exact", "contains", "json", "absent")

# Every field the schema defines, per object. Anything else is a typo (an
# assertion under ``expect.stdot`` would otherwise never run) or a feature this
# runner does not have, so the vector is invalid rather than silently weaker.
# ``invoke.fixtures`` and ``isolation.no_live_refeed`` are defined by ADR-0043m
# but not implemented; they pass validation and are then refused.
TOP_FIELDS = ("schema", "id", "oracle", "tier", "invoke", "expect", "isolation", "backend", "platform")
INVOKE_FIELDS = ("argv", "env", "unset", "stdin", "timeout_ms", "fixtures")
EXPECT_FIELDS = ("exit", "stdout", "stderr")
SPEC_FIELDS = ("mode", "value", "normalize")
ISOLATION_FIELDS = ("offline", "ssh_stubs", "redirect", "no_live_refeed")


class VectorError(Exception):
    """Raised for a malformed or non-conformant vector."""


class RefusalError(VectorError):
    """Raised when a runner fails closed on an unsupported vector requirement.

    ``code`` is a stable machine token: ``unsupported_vector_field``,
    ``unsupported_isolation``, or ``unsupported_backend``.
    """

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def current_platform() -> str:
    if os.name == "nt":
        return "windows"
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "macos"
    return "linux"


def _tmpdir_roots() -> set[str]:
    """The temporary-directory roots the ``tmpdir`` transform replaces.

    POSIX follows the Bash runner and acq's own rule: ``$TMPDIR`` only when it
    is absolute (trailing slashes dropped; macOS's ends in one), plus ``/tmp``.
    A relative ``TMPDIR`` is ignored, as acq ignores it. Windows has no
    ``TMPDIR`` convention, so there the interpreter's temp directory is used.
    """
    roots = {"/tmp"}
    if os.name == "nt":
        roots.add(tempfile.gettempdir())
        return roots
    env = os.environ.get("TMPDIR", "")
    if env.startswith("/") and env.rstrip("/"):
        roots.add(env.rstrip("/"))
    return roots


def _tmpdir_transform(text: str) -> str:
    # Literal replacement, longest root first, so a root that contains another
    # (/tmp/x and /tmp) is replaced whole.
    for root in sorted(_tmpdir_roots(), key=len, reverse=True):
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


def _is_subset(expected, actual) -> bool:
    """Structural subset: every key/value of ``expected`` must be present in
    ``actual``, recursively. Extra fields in ``actual`` are allowed (ADR-0038m:
    unknown fields are additive). Scalars compare by equality; lists compare
    element-wise by length. A JSON boolean equals only a boolean: Python's
    ``True == 1`` would otherwise accept ``{"ok": 1}`` for ``{"ok": true}``,
    which jq (the Bash runner) rejects.
    """
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return False
        return all(k in actual and _is_subset(v, actual[k]) for k, v in expected.items())
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            return False
        return all(_is_subset(e, a) for e, a in zip(expected, actual))
    if isinstance(expected, bool) or isinstance(actual, bool):
        return type(expected) is type(actual) and expected == actual
    return expected == actual


def compare(actual: str, expected, mode: str, label: str) -> None:
    if mode == "exact":
        if actual != expected:
            raise AssertionError(f"{label}: expected exact {expected!r}, got {actual!r}")
    elif mode == "contains":
        if expected not in actual:
            raise AssertionError(f"{label}: expected {expected!r} in {actual!r}")
    elif mode == "absent":
        # The output is not echoed: what must be absent is usually a secret
        # sentinel, and the failure only needs to say that it appeared.
        if expected in actual:
            raise AssertionError(f"{label}: expected {expected!r} to be absent, but it appears")
    elif mode == "json":
        try:
            parsed = json.loads(actual)
        except json.JSONDecodeError as exc:
            raise AssertionError(f"{label}: output is not valid JSON: {exc}") from exc
        if not _is_subset(expected, parsed):
            raise AssertionError(f"{label}: JSON mismatch\n  expected (subset): {expected!r}\n  actual:           {parsed!r}")
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


def stream_specs(expect: dict, stream: str) -> list[dict]:
    """The assertions declared for ``stream``: none, one, or a list of them."""
    spec = expect.get(stream)
    if spec is None:
        return []
    return spec if isinstance(spec, list) else [spec]


def _unknown_fields(obj, allowed: tuple[str, ...], prefix: str) -> list[str]:
    return [f"{prefix}{key}" for key in obj if key not in allowed]


def _validate(vector, path: Path) -> None:
    if not isinstance(vector, dict):
        raise VectorError(f"{path}: a vector must be a JSON object")
    missing = [k for k in TOP_FIELDS if k not in vector]
    if missing:
        raise VectorError(f"{path}: missing required field(s): {', '.join(missing)}")
    for name in ("invoke", "expect", "isolation"):
        if not isinstance(vector[name], dict):
            raise VectorError(f"{path}: {name} must be an object")
    invoke, expect, isolation = vector["invoke"], vector["expect"], vector["isolation"]
    unknown = (
        _unknown_fields(vector, TOP_FIELDS, "")
        + _unknown_fields(invoke, INVOKE_FIELDS, "invoke.")
        + _unknown_fields(expect, EXPECT_FIELDS, "expect.")
        + _unknown_fields(isolation, ISOLATION_FIELDS, "isolation.")
    )
    if unknown:
        raise VectorError(f"{path}: unknown vector field(s): {', '.join(unknown)}")
    if "argv" not in invoke:
        raise VectorError(f"{path}: invoke.argv is required")
    if "exit" not in expect:
        raise VectorError(f"{path}: expect.exit is required")
    for stream in ("stdout", "stderr"):
        _validate_specs(expect.get(stream), f"{path}: expect.{stream}")


def _validate_specs(declared, label: str) -> None:
    """Check one stream's assertion (or non-empty list of assertions) up front,
    so a bad mode or transform is reported before the CLI-under-test runs."""
    if declared is None:
        return
    if isinstance(declared, list) and not declared:
        raise VectorError(f"{label}: an assertion list must not be empty")
    for spec in declared if isinstance(declared, list) else [declared]:
        if not isinstance(spec, dict):
            raise VectorError(f"{label}: an assertion must be an object")
        unknown = _unknown_fields(spec, SPEC_FIELDS, "")
        if unknown:
            raise VectorError(f"{label}: unknown vector field(s): {', '.join(unknown)}")
        mode = spec.get("mode", "exact")
        if mode not in MODES:
            raise VectorError(f"{label}: unknown mode {mode!r}")
        if "value" not in spec:
            raise VectorError(f"{label}: value is required")
        if mode != "json" and not isinstance(spec["value"], str):
            raise VectorError(f"{label}: a {mode} value must be a string")
        if mode == "absent" and not spec["value"]:
            raise VectorError(f"{label}: an absent value must not be empty")
        transforms = spec.get("normalize", [])
        if not isinstance(transforms, list) or [t for t in transforms if t not in TRANSFORMS]:
            raise VectorError(f"{label}: unknown transform(s) in {transforms!r}")


def _refuse_unsupported(vector: dict, invoke: dict, isolation: dict) -> None:
    """Fail closed on any vector requirement this runner cannot honour.

    ADR-0043m: a runner that cannot honour a vector's isolation fails closed,
    and enumerated-but-unimplemented fields (``invoke.fixtures``,
    ``isolation.no_live_refeed``) are rejected rather than silently ignored.
    A non-null ``backend`` requests a capability this foundation slice does not
    provide (ADR-0040m unsupported-capability fail-closed).
    """
    vid = vector["id"]
    if "fixtures" in invoke:
        raise RefusalError("unsupported_vector_field", f"{vid}: invoke.fixtures is not supported by this runner")
    if "no_live_refeed" in isolation:
        raise RefusalError("unsupported_vector_field", f"{vid}: isolation.no_live_refeed is not supported by this runner")
    if isolation.get("offline") is False:
        raise RefusalError("unsupported_isolation", f"{vid}: isolation.offline=false is not supported by this runner")
    if isolation.get("ssh_stubs") is True:
        raise RefusalError("unsupported_isolation", f"{vid}: isolation.ssh_stubs=true is not supported by this runner")
    if vector.get("backend"):
        raise RefusalError("unsupported_backend", f"{vid}: backend {vector['backend']!r} is not supported by this runner")


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

    _refuse_unsupported(vector, invoke, isolation)

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
    #
    # The subprocess runs from the repository ROOT, matching the Bash runner
    # (scripts/run-vectors), so a relative path in ``invoke.argv`` resolves the
    # same under both runners (ADR-0043m: the two runners must agree). The corpus
    # root is ``<repo>/test/vectors``, so its grandparent is the repo root.
    #
    # stdin is always a pipe carrying exactly ``invoke.stdin``, empty included,
    # as the Bash runner always feeds a file. Passing None for an empty value
    # would hand the child pytest's own fd 0: harmless under the default capture
    # (/dev/null), but under ``pytest -s`` the CLI would read the developer's
    # terminal, and a consent prompt would see their answer.
    try:
        proc = subprocess.run(
            argv,
            cwd=str(corpus_root.parent.parent),
            env=env,
            input=stdin.encode("utf-8"),
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

    # Modes and transforms were validated when the vector was loaded. Each
    # assertion starts from the raw stream, so one assertion's transforms never
    # change what the next one sees.
    for stream in ("stdout", "stderr"):
        actual = raw_stdout if stream == "stdout" else raw_stderr
        for spec in stream_specs(expect, stream):
            transforms = spec.get("normalize", [])
            compare(apply_transforms(actual, transforms), spec["value"], spec.get("mode", "exact"),
                    f"{vector['id']}.{stream}")
