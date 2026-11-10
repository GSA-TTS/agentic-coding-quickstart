"""The Python acq refuses ``ACQ_CLONE=1`` until clone mode is ported.

The Bash acq runs ``create``/``run`` on a disposable clone of the primary
workspace under ``--clone`` or ``ACQ_CLONE=1`` (ADR-0027). The Python acq has no
clone mode yet: it rejects ``--clone`` at the parser, and must also refuse the
env var instead of ignoring it, or a user expecting isolation gets the real
workspace mounted read/write. These tests pin the refusal (a usage error before
any state, config or backend access), that every value Bash treats as off still
proceeds, and that the predicate matches Bash's own test of the variable.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import cli, errors, migration
from acq_py.commands import common

REPO_ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")
needs_bash = pytest.mark.skipif(
    sys.platform == "win32" or BASH is None, reason="Bash parity runs on POSIX with bash"
)

# Values Bash's `[ "${ACQ_CLONE:-0}" = "1" ]` treats as off: only "1" is on.
OFF_VALUES = ["", "0", "true", "TRUE", "yes", "on", " 1", "1 ", "01", "1\n", "2", "-1"]

# Each create/run form: the AGENT PATH create and run, the re-attach, the recreate.
REFUSED_FORMS = [
    ["create", "opencode", "."],
    ["run", "opencode", "."],
    ["run", "box"],
    ["create", "--recreate", "box"],
]


def _forbid_backend_and_state(monkeypatch) -> None:
    """Fail the test if the refusal is not the first thing create/run does."""
    def forbidden(*_args, **_kwargs):
        raise AssertionError("ACQ_CLONE refusal must come before any state or backend access")

    monkeypatch.setattr(common, "_resolve_backend_for_lifecycle", forbidden)
    monkeypatch.setattr(migration, "migrate_tree", forbidden)
    monkeypatch.setattr(cli, "_user_dirs_pre_step", forbidden)


@pytest.mark.parametrize("argv", REFUSED_FORMS, ids=lambda a: " ".join(a))
def test_acq_clone_1_is_refused_as_a_usage_error(monkeypatch, tmp_path, capsys, argv):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("ACQ_CLONE", "1")
    _forbid_backend_and_state(monkeypatch)
    rc = cli.main(["--json", "--backend", "msb", *argv])
    captured = capsys.readouterr()
    doc = json.loads(captured.out)
    assert rc == errors.EXIT_USAGE
    assert doc["command"] == argv[0]
    assert doc["error"]["code"] == errors.USAGE
    assert "ACQ_CLONE=1" in doc["error"]["message"]
    assert "not supported by the Python implementation" in doc["error"]["message"]
    assert "unset ACQ_CLONE" in doc["error"]["remediation"]
    assert "ACQ_IMPL=bash" in doc["error"]["remediation"]
    assert captured.err == ""
    assert list(tmp_path.iterdir()) == []


def test_the_human_form_names_the_way_out_on_stderr(monkeypatch, tmp_path, capsys):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("ACQ_CLONE", "1")
    _forbid_backend_and_state(monkeypatch)
    rc = cli.main(["run", "opencode", "."])
    captured = capsys.readouterr()
    assert rc == errors.EXIT_USAGE
    assert captured.out == ""
    lines = captured.err.splitlines()
    assert lines[0].startswith("acq: clone mode (ACQ_CLONE=1) is not supported")
    assert lines[1] == (
        "unset ACQ_CLONE to mount the workspace itself, "
        "or use the Bash implementation (ACQ_IMPL=bash) for a disposable clone"
    )


def test_the_refusal_crosses_the_subprocess_boundary(tmp_path):
    env = {k: v for k, v in os.environ.items() if not k.startswith("ACQ_")}
    env.update(
        ACQ_CLONE="1",
        ACQ_STATE_DIR=str(tmp_path / "state"),
        ACQ_SECRET_STORE_DIR=str(tmp_path / "store"),
        PYTHONPATH=str(REPO_ROOT / "py-acq" / "src"),
    )
    proc = subprocess.run(  # nosec B603 # fixed argv: this interpreter running acq_py
        [sys.executable, "-m", "acq_py", "--json", "create", "opencode", str(tmp_path)],
        capture_output=True, text=True, env=env, cwd=tmp_path, stdin=subprocess.DEVNULL, check=False,
    )
    assert proc.returncode == 2, proc.stderr
    assert json.loads(proc.stdout)["error"]["code"] == "usage"
    assert not (tmp_path / "state").exists()


@pytest.mark.parametrize("value", OFF_VALUES, ids=repr)
@pytest.mark.parametrize("verb", ["create", "run"])
def test_values_bash_treats_as_off_proceed(monkeypatch, tmp_path, capsys, verb, value):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("ACQ_CLONE", value)
    reached = []

    def resolver(_override, _emit_json, command):
        reached.append(command)
        return None, 97

    monkeypatch.setattr(common, "_resolve_backend_for_lifecycle", resolver)
    assert cli.main(["--json", "--backend", "msb", verb, "opencode", "."]) == 97
    assert reached == [verb]
    capsys.readouterr()


@pytest.mark.parametrize("argv", [["ls"], ["stop", "box"], ["version"], ["doctor"]], ids=lambda a: a[0])
def test_other_verbs_ignore_acq_clone(monkeypatch, tmp_path, capsys, argv):
    # Bash reads ACQ_CLONE only on create/run, so no other verb refuses it.
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("ACQ_CLONE", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    cli.main(["--json", *argv])
    out = capsys.readouterr().out.strip()
    doc = json.loads(out.splitlines()[-1])
    assert "ACQ_CLONE" not in json.dumps(doc)


def test_unset_acq_clone_is_off(monkeypatch):
    monkeypatch.delenv("ACQ_CLONE", raising=False)
    assert cli._clone_requested() is False


@needs_bash
def test_the_predicate_matches_bash(monkeypatch):
    # The exact test acq, sbx.sh and msb.sh apply (pinned by the next test).
    script = '[ "${ACQ_CLONE:-0}" = "1" ] && echo on || echo off'
    for value in ["1", *OFF_VALUES, None]:
        env = {k: v for k, v in os.environ.items() if k != "ACQ_CLONE"}
        if value is None:
            monkeypatch.delenv("ACQ_CLONE", raising=False)
        else:
            env["ACQ_CLONE"] = value
            monkeypatch.setenv("ACQ_CLONE", value)
        bash = subprocess.run(  # nosec B603 # fixed argv: bash running a literal test
            [str(BASH), "-c", script], capture_output=True, text=True, env=env, check=True,
            stdin=subprocess.DEVNULL,
        ).stdout.strip()
        assert cli._clone_requested() is (bash == "on"), repr(value)


def test_bash_reads_acq_clone_only_with_the_pinned_test():
    # If Bash ever widens what turns clone mode on (say, "true"), the predicate
    # above stops matching it; fail here so the Python refusal is widened too.
    reads = []
    for rel in ("acq", "acq.backends/sbx.sh", "acq.backends/msb.sh", "acq.backends/common.sh"):
        for line in (REPO_ROOT / rel).read_text(encoding="utf-8").splitlines():
            if re.search(r"\$\{?ACQ_CLONE\b", line) and not line.lstrip().startswith("#"):
                reads.append((rel, line.strip()))
    assert reads, "expected Bash to read ACQ_CLONE"
    for rel, line in reads:
        tests = re.findall(r"\[[^]]*\$\{?ACQ_CLONE\b[^]]*\]", line)
        assert tests == ['[ "${ACQ_CLONE:-0}" = "1" ]'], (rel, line)
