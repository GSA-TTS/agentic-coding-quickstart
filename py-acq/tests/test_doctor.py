"""Tier-2 implementation tests for the ``doctor`` command shape.

Non-contract evidence (ADR-0039m): these reach into the package and the
subprocess boundary, but the contract evidence lives in the vector corpus
(``test/vectors/cli/doctor-*.json``). Here we assert the full per-check shape the
vectors deliberately do not pin: every check carries a non-empty ``message``, and
every non-``ok`` check carries actionable ``remediation``.
"""

from __future__ import annotations

import json
import subprocess
import sys

import acq_py.doctor as doctor
from acq_py import envelope, errors


def run_cli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "acq_py", *args],
        capture_output=True,
        text=True,
    )


def test_doctor_data_shape():
    data = doctor.doctor_data()
    assert data["status"] in ("ok", "degraded", "failed")
    checks = data["checks"]
    assert checks, "doctor produced no checks"

    for check in checks:
        assert check["id"], "check missing stable id"
        assert check["status"] in ("ok", "warn", "fail")
        assert check["message"], "check missing message"
        if check["status"] != "ok":
            assert check.get("remediation"), "non-ok check missing remediation"


def test_overall_status_derivation():
    ok = [{"id": "a", "status": "ok"}]
    warn = [{"id": "a", "status": "warn"}]
    fail = [{"id": "a", "status": "fail"}]
    assert doctor.overall_status(ok) == "ok"
    assert doctor.overall_status(ok + warn) == "degraded"
    assert doctor.overall_status(ok + warn + fail) == "failed"


def test_doctor_json_subprocess():
    proc = run_cli("doctor", "--json")
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["schema_version"] == envelope.SCHEMA_VERSION
    assert doc["command"] == "doctor"
    assert doc["data"]["status"] in ("ok", "degraded", "failed")
    assert isinstance(doc["data"]["checks"], list)


def test_doctor_sandbox_operational_failure_exit_1():
    proc = run_cli("doctor", "mysandbox", "--json")
    assert proc.returncode == 1
    doc = json.loads(proc.stdout)
    assert doc["error"]["code"] == errors.UNSUPPORTED
    assert doc["error"]["message"]
    assert doc["error"]["remediation"]
