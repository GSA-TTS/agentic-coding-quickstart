"""Tier-2 implementation tests for the envelope and exit-code contract.

These are non-contract evidence (ADR-0039m): they may reach into the package
directly. Contract evidence lives only in the vector corpus (``test/vectors``).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys

import pytest

import acq_py
from acq_py import envelope, errors


def run_cli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "acq_py", *args],
        capture_output=True,
        text=True,
    )


def test_package_version_is_semver():
    assert re.fullmatch(r"\d+\.\d+\.\d+", acq_py.__version__), acq_py.__version__


def test_envelope_success_shape():
    doc = envelope.success("version", {"acq_version": "0.1.0"})
    assert doc == {
        "schema_version": envelope.SCHEMA_VERSION,
        "command": "version",
        "data": {"acq_version": "0.1.0"},
    }


def test_envelope_error_shape():
    doc = envelope.error("version", errors.USAGE, "bad", remediation="try again")
    assert doc["schema_version"] == envelope.SCHEMA_VERSION
    assert doc["command"] == "version"
    assert doc["error"] == {"code": "usage", "message": "bad", "remediation": "try again"}


def test_version_json_subprocess():
    proc = run_cli("version", "--json")
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["schema_version"] == envelope.SCHEMA_VERSION
    assert doc["command"] == "version"
    assert doc["data"]["acq_version"] == acq_py.__version__


def test_version_reports_python_impl():
    # ADR-0046m: version output marks the implementation so a bug report is
    # unambiguous about which implementation produced it.
    proc = run_cli("version", "--json")
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["data"]["impl"] == "python"

    human = run_cli("version")
    assert human.returncode == 0, human.stderr
    assert "impl:" in human.stdout


def test_usage_error_exit_code_2_human():
    proc = run_cli("--bad-flag")
    assert proc.returncode == 2
    assert proc.stdout == ""
    assert "bad-flag" in proc.stderr


def test_usage_error_json_envelope():
    proc = run_cli("--json", "--bad-flag")
    assert proc.returncode == 2
    doc = json.loads(proc.stdout)
    assert doc["schema_version"] == envelope.SCHEMA_VERSION
    assert doc["error"]["code"] == "usage"


def test_version_flag_alias():
    proc = run_cli("--version")
    assert proc.returncode == 0
    assert "acq version" in proc.stdout


@pytest.mark.parametrize("cmd", [["version"], ["help"], ["--help"]])
def test_success_paths_exit_zero(cmd):
    assert run_cli(*cmd).returncode == 0
