"""The two vector runners agree on the edge cases the sentinel set does not reach.

ADR-0043m wants a diverging runner to fail on the feature. Each sentinel shows
that a mode or transform works on one easy input, so the runners could still
disagree at the edges: a quote ending an absolute path, a lone CR, ``true``
against ``1``, several JSON documents, a regex character in TMPDIR, an unknown
field, a NUL byte ahead of a value that must be absent, a developer's
SSH_AUTH_SOCK. The probe vectors in ``runner-probes/probe/`` cover those cases. This
test runs every probe through the pytest engine and through ``scripts/run-vectors``
and requires both to give the verdict in ``EXPECTED``, which also records the
intended behaviour (several probes must fail or be rejected).

The probes are not part of the corpus: some of them must fail.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

import vector_engine as engine
from conftest import REPO_ROOT

PROBES = Path(__file__).resolve().parent / "runner-probes"

EXPECTED = {
    "probe/abspath-stops-at-quotes": "ok",
    "probe/abspath-stops-at-vertical-tab": "ok",
    "probe/crlf-keeps-a-lone-cr": "ok",
    "probe/json-bool-is-not-int": "fail",
    "probe/json-multidoc-fails": "fail",
    "probe/json-transform-false": "ok",
    "probe/json-transform-nonascii": "ok",
    "probe/json-transform-leaves-multidoc": "ok",
    "probe/stdin-bytes": "ok",
    "probe/stdin-empty": "ok",
    "probe/tmpdir-trailing-slash": "ok",
    "probe/tmpdir-is-literal": "ok",
    "probe/absent-passes": "ok",
    "probe/absent-fails-when-present": "fail",
    "probe/absent-after-transform": "fail",
    "probe/absent-after-nul": "fail",
    "probe/absent-nul-without-value": "fail",
    "probe/absent-with-normalize": "invalid",
    "probe/absent-value-with-nul": "invalid",
    "probe/absent-empty-value": "invalid",
    "probe/unknown-expect-field": "invalid",
    "probe/unknown-top-field": "invalid",
    "probe/unknown-spec-field": "invalid",
    "probe/unknown-mode": "invalid",
    "probe/empty-assertion-list": "invalid",
    "probe/fixtures-refused": "refused",
    "probe/ssh-auth-sock-unset": "ok",
    "probe/ssh-auth-sock-vector-env": "ok",
}


@pytest.fixture
def runner_tmpdir(tmp_path, monkeypatch):
    # A TMPDIR holding a regex metacharacter and ending in slashes, as macOS's
    # does, so the tmpdir probes can tell a literal match from a regex one.
    tmpdir = tmp_path / "a.b"
    tmpdir.mkdir()
    monkeypatch.setenv("TMPDIR", f"{tmpdir}//")
    # A developer's agent socket, which neither runner may pass on (the
    # ssh-auth-sock probes).
    monkeypatch.setenv("SSH_AUTH_SOCK", "/developer/agent.sock")
    return tmpdir


def _python_verdict(path: Path, workdir: Path) -> str:
    try:
        vector = engine.load_vector(path)
    except engine.VectorError:
        return "invalid"
    try:
        engine.run_vector(vector, acq_cmd=["false"], python_exe=sys.executable, corpus_root=PROBES, workdir=workdir)
    except engine.RefusalError:
        return "refused"
    except AssertionError:
        return "fail"
    return "ok"


def _bash_verdicts() -> dict[str, str]:
    proc = subprocess.run(
        ["bash", str(REPO_ROOT / "scripts" / "run-vectors"), "--python", sys.executable, "--acq", "false",
         "--vectors", str(PROBES)],
        capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL, env=os.environ.copy(),
    )
    verdicts = {}
    for line in proc.stdout.splitlines():
        match = re.match(r"(ok|FAIL|refused|skip) (\S+)(.*)", line)
        if not match:
            continue
        status, vid, rest = match.groups()
        if status == "FAIL":
            status = "invalid" if rest.startswith(" (invalid vector:") else "fail"
        verdicts[vid] = status
    assert verdicts, proc.stdout + proc.stderr
    return verdicts


def test_every_probe_has_an_expected_verdict():
    found = {vid for vid, _path in engine.discover_vectors(PROBES)}
    assert found == set(EXPECTED)


# The tmpdir probes rest on the POSIX convention that an absolute TMPDIR names
# the temp root, which is what both runners replace there. On Windows the
# transform replaces the interpreter's own temp directory instead (TMPDIR is not
# a Windows convention, and its paths use backslashes), and the Bash runner does
# not run at all, so these two probes have no Windows verdict to agree on.
POSIX_ONLY = {"probe/tmpdir-trailing-slash", "probe/tmpdir-is-literal"}


def test_the_pytest_engine_gives_the_expected_verdicts(runner_tmpdir, tmp_path):
    skipped = POSIX_ONLY if os.name == "nt" else set()
    got = {}
    for vid, path in engine.discover_vectors(PROBES):
        if vid in skipped:
            continue
        workdir = tmp_path / "work" / vid.replace("/", "-")
        workdir.mkdir(parents=True)
        got[vid] = _python_verdict(path, workdir)
    assert got == {vid: verdict for vid, verdict in EXPECTED.items() if vid not in skipped}


@pytest.mark.skipif(
    os.name == "nt" or not (shutil.which("bash") and shutil.which("jq") and shutil.which("timeout")),
    reason="the Bash runner needs bash, jq and timeout",
)
def test_the_bash_runner_gives_the_expected_verdicts(runner_tmpdir):
    assert _bash_verdicts() == EXPECTED
