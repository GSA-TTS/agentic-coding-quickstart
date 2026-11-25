"""When clone mode is on: ``--clone`` or ``ACQ_CLONE`` exactly ``1`` (ADR-0027).

Bash turns clone mode on for ``create``/``run`` with the ``--clone`` flag or
``[ "${ACQ_CLONE:-0}" = "1" ]``; nothing else (``true``, `` 1``, empty) does.
These tests pin that the Python predicate agrees with Bash's own test of the
variable, that only ``create`` and ``run`` read it, and that the read sites in
Bash still use that one test. What clone mode does is covered by
``test_clone_mode.py``.
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

from acq_py import cli
from acq_py.commands import common

REPO_ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")
needs_bash = pytest.mark.skipif(
    sys.platform == "win32" or BASH is None, reason="Bash parity runs on POSIX with bash"
)

# Values Bash's `[ "${ACQ_CLONE:-0}" = "1" ]` treats as off: only "1" is on.
OFF_VALUES = ["", "0", "true", "TRUE", "yes", "on", " 1", "1 ", "01", "1\n", "2", "-1"]


class _Parsed:
    def __init__(self, clone: bool = False):
        self.clone = clone


@pytest.mark.parametrize("value", OFF_VALUES, ids=repr)
def test_values_bash_treats_as_off_leave_clone_mode_off(monkeypatch, value):
    monkeypatch.setenv("ACQ_CLONE", value)
    assert common.clone_requested(_Parsed()) is False
    assert common.clone_requested(_Parsed(clone=True)) is True


def test_acq_clone_1_or_the_flag_turns_clone_mode_on(monkeypatch):
    monkeypatch.delenv("ACQ_CLONE", raising=False)
    assert common.clone_requested(_Parsed()) is False
    assert common.clone_requested(_Parsed(clone=True)) is True
    monkeypatch.setenv("ACQ_CLONE", "1")
    assert common.clone_requested(_Parsed()) is True
    assert cli._clone_requested() is True


@pytest.mark.parametrize("verb", ["create", "run"])
def test_create_and_run_accept_the_clone_flag(verb):
    parsed = cli.build_parser().parse_args([verb, "opencode", ".", "--clone"])
    assert parsed.clone is True
    assert cli.build_parser().parse_args([verb, "opencode", "."]).clone is False


@pytest.mark.parametrize("value", ["1", *OFF_VALUES], ids=repr)
@pytest.mark.parametrize("verb", ["create", "run"])
def test_acq_clone_no_longer_refuses_create_or_run(monkeypatch, tmp_path, capsys, verb, value):
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
    # Bash reads ACQ_CLONE only on create/run.
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("ACQ_CLONE", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    cli.main(["--json", *argv])
    out = capsys.readouterr().out.strip()
    doc = json.loads(out.splitlines()[-1])
    assert "ACQ_CLONE" not in json.dumps(doc)


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
        assert common.clone_env() is (bash == "on"), repr(value)


def test_bash_reads_acq_clone_only_with_the_pinned_test():
    # If Bash ever widens what turns clone mode on (say, "true"), the predicate
    # above stops matching it; fail here so the Python predicate is widened too.
    reads = []
    for rel in ("acq", "acq.backends/sbx.sh", "acq.backends/msb.sh", "acq.backends/common.sh"):
        for line in (REPO_ROOT / rel).read_text(encoding="utf-8").splitlines():
            if re.search(r"\$\{?ACQ_CLONE\b", line) and not line.lstrip().startswith("#"):
                reads.append((rel, line.strip()))
    assert reads, "expected Bash to read ACQ_CLONE"
    for rel, line in reads:
        tests = re.findall(r"\[[^]]*\$\{?ACQ_CLONE\b[^]]*\]", line)
        assert tests == ['[ "${ACQ_CLONE:-0}" = "1" ]'], (rel, line)
