"""Tier-2 implementation tests for the ``doctor`` command shape.

Non-contract evidence (ADR-0039m): these reach into the package and the
subprocess boundary, but the contract evidence lives in the vector corpus
(``test/vectors/cli/doctor-*.json``). Here we assert the full per-check shape the
vectors deliberately do not pin: every check carries a non-empty ``message``, and
every non-``pass`` check carries actionable ``remediation``.
"""

from __future__ import annotations

import json
import subprocess
import sys

import pytest

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
    assert data["status"] in ("pass", "warn", "fail")
    checks = data["checks"]
    assert checks, "doctor produced no checks"

    for check in checks:
        assert check["id"], "check missing stable id"
        assert check["status"] in ("pass", "warn", "fail")
        assert check["message"], "check missing message"
        if check["status"] != "pass":
            assert check.get("remediation"), "non-pass check missing remediation"


def test_overall_status_derivation():
    ok = [{"id": "a", "status": "pass"}]
    warn = [{"id": "a", "status": "warn"}]
    fail = [{"id": "a", "status": "fail"}]
    assert doctor.overall_status(ok) == "pass"
    assert doctor.overall_status(ok + warn) == "warn"
    assert doctor.overall_status(ok + warn + fail) == "fail"


def test_doctor_json_subprocess():
    proc = run_cli("doctor", "--json")
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["schema_version"] == envelope.SCHEMA_VERSION
    assert doc["command"] == "doctor"
    assert doc["data"]["status"] in ("pass", "warn", "fail")
    assert isinstance(doc["data"]["checks"], list)


def test_doctor_sandbox_operational_failure_exit_1(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    proc = run_cli("doctor", "mysandbox", "--json")
    assert proc.returncode == 1
    doc = json.loads(proc.stdout)
    assert doc["error"]["code"] == errors.UNSUPPORTED
    assert doc["error"]["message"]
    assert doc["error"]["remediation"]

import pytest
from acq_py import cli, config, hostexec, msb, sbx
from acq_py.commands import configure


def stub(monkeypatch, backend, version=None):
    monkeypatch.setenv(f"ACQ_{backend.upper()}_BIN", "__stub__")
    monkeypatch.setenv(f"ACQ_{backend.upper()}_VERSION",
                       version or ("0.7.7" if backend == "msb" else "0.51.0"))
    monkeypatch.setenv("ACQ_BACKEND", backend)


@pytest.mark.parametrize("backend,version,expected", [
    ("msb", "0.6.9", "pass"), ("msb", "0.7.7", "pass"),
    ("msb", "0.6.8", "fail"), ("msb", "0.7.0", "fail"),
    ("msb", "0.7.1", "fail"), ("msb", "0.7.2", "fail"),
    ("msb", "0.7.3-rc1", "fail"), ("msb", "garbage", "fail"),
    ("sbx", "0.39.0", "pass"), ("sbx", "0.38.0", "fail"),
    ("sbx", "garbage", "fail"),
])
def test_backend_versions(monkeypatch, backend, version, expected):
    stub(monkeypatch, backend, version)
    checks = {c["id"]: c for c in doctor.backend_checks()}
    assert checks[f"backend-{backend}"]["status"] == expected
    assert "installed" in checks[f"backend-{backend}"]["message"]
    if expected == "fail":
        assert checks[f"backend-{backend}"]["remediation"]


def test_readiness_skip_and_advice(monkeypatch):
    stub(monkeypatch, "msb")
    assert doctor.readiness_check("msb")[0]["status"] == "pass"
    monkeypatch.setenv("ACQ_MSB_STUB_DOCTOR_UNFIT", "1")
    check = doctor.readiness_check("msb")[0]
    assert check["status"] == "warn"
    assert "acq does not run it" in check["remediation"]
    monkeypatch.setenv("ACQ_SKIP_MSB_DOCTOR", "1")
    monkeypatch.setattr(hostexec, "run_captured", lambda *a, **k: pytest.fail("must not probe"))
    assert doctor.readiness_check("msb") == []
    assert doctor.readiness_check("sbx") == []


@pytest.mark.parametrize("backend", ["msb", "sbx"])
@pytest.mark.parametrize("missing", [False, True])
def test_named_diagnostics(monkeypatch, capsys, backend, missing):
    stub(monkeypatch, backend)
    adapter = msb if backend == "msb" else sbx
    monkeypatch.setattr(adapter, "exists", lambda name: name == "box")
    monkeypatch.setenv(f"ACQ_{backend.upper()}_STUB_CATALOG", '{"box": "running"}')
    if missing:
        monkeypatch.setenv(f"ACQ_{backend.upper()}_STUB_IMAGE_CONTRACT", "missing")
    assert cli.run_doctor(True, "box", backend) == 0
    data = json.loads(capsys.readouterr().out)["data"]
    assert data["status"] == ("warn" if missing else "pass")
    assert len(data["checks"]) == 11
    assert any(c["message"] == "passwordless sudo probe works" for c in data["checks"])
    if missing:
        assert sum(c["status"] == "warn" for c in data["checks"]) == 2


@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_named_missing_and_exec_failure(monkeypatch, capsys, backend):
    stub(monkeypatch, backend)
    adapter = msb if backend == "msb" else sbx
    assert cli.run_doctor(False, "missing", backend) == 1
    assert "doctor: no such sandbox 'missing'." in capsys.readouterr().err
    monkeypatch.setattr(adapter, "exists", lambda name: True)
    monkeypatch.setenv(f"ACQ_{backend.upper()}_STUB_CATALOG", '{"box": "running"}')
    monkeypatch.setenv(f"ACQ_{backend.upper()}_STUB_EXEC_EXIT", "7")
    assert cli.run_doctor(True, "box", backend) == 7
    assert "error" in json.loads(capsys.readouterr().out)


def test_guest_argv_and_no_secret_injection(monkeypatch, capsys):
    for backend in ("msb", "sbx"):
        stub(monkeypatch, backend)
        adapter = msb if backend == "msb" else sbx
        monkeypatch.setattr(adapter, "exists", lambda name: True)
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, "  ok: HOME is /home/agent\n", "")
        monkeypatch.setattr(adapter, "_run", run)
        assert cli.run_doctor(True, "box", backend) == 0
        argv = calls[0]
        expected = (["exec", "-u", "agent", "-e", "HOME=/home/agent", "box", "--", "sh", "-c"]
                    if backend == "msb" else ["exec", "box", "--", "env", "HOME=/home/agent", "sh", "-c"])
        assert argv[:-1] == expected
        assert "--secret" not in argv
        capsys.readouterr()


@pytest.mark.parametrize("json_mode,no_prompt,terminal,offer", [
    (True, False, True, False), (False, True, True, False),
    (False, False, False, False), (False, False, True, True),
])
def test_default_backend_offer(monkeypatch, capsys, json_mode, no_prompt, terminal, offer):
    stub(monkeypatch, "sbx")
    monkeypatch.setattr(cli.common, "_stdin_is_terminal", lambda: terminal)
    if no_prompt:
        monkeypatch.setenv("ACQ_NO_PROMPT", "1")
    calls = []
    monkeypatch.setattr(configure, "Terminal", lambda: object())
    def confirm(term, prompt, default):
        calls.append((prompt, default))
        return False
    monkeypatch.setattr(configure, "confirm", confirm)
    assert cli.run_doctor(json_mode, None, "sbx") == 0
    assert bool(calls) == offer
    if offer:
        assert calls[0][1] is False
    assert config.read_field("backend") is None


def test_extra_operands(monkeypatch, capsys):
    stub(monkeypatch, "sbx")
    assert cli.main(["doctor", "box", "extra"]) == 1
    assert "expected at most one sandbox name" in capsys.readouterr().err


def test_prompt_accepts_default_backend(monkeypatch, capsys):
    stub(monkeypatch, "sbx")
    monkeypatch.setattr(cli.common, "_stdin_is_terminal", lambda: True)
    monkeypatch.setattr(configure, "Terminal", lambda: object())
    monkeypatch.setattr(configure, "confirm", lambda *args: True)
    assert cli.run_doctor(False, None, "sbx") == 0
    assert config.read_field("backend") == "sbx"


def test_broken_pin_reports_but_named_refuses(monkeypatch, capsys):
    stub(monkeypatch, "msb")
    monkeypatch.delenv("ACQ_BACKEND")
    config.write_field("backend", "bogus")
    assert cli.run_doctor(True, None) == 0
    assert json.loads(capsys.readouterr().out)["data"]["status"] == "fail"
    assert cli.run_doctor(True, "box") == 1
    assert "unknown backend" in json.loads(capsys.readouterr().out)["error"]["message"]


def test_named_bad_directories_refuse(monkeypatch, capsys):
    stub(monkeypatch, "sbx")
    monkeypatch.setenv("ACQ_STATE_DIR", "relative")
    monkeypatch.setattr(sbx, "exists", lambda name: pytest.fail("must refuse before backend access"))
    assert cli.run_doctor(True, "box", "sbx") == 1
    assert "error" in json.loads(capsys.readouterr().out)


def test_readiness_probe_errors_are_best_effort(monkeypatch):
    stub(monkeypatch, "msb")
    def timeout(*args, **kwargs):
        raise subprocess.TimeoutExpired("msb doctor", 30)
    monkeypatch.setattr(hostexec, "run_captured", timeout)
    assert doctor.readiness_check("msb") == []


@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_named_human_warnings_are_nonfatal(monkeypatch, capsys, backend):
    stub(monkeypatch, backend)
    monkeypatch.setenv(f"ACQ_{backend.upper()}_STUB_CATALOG", '{"box":"running"}')
    monkeypatch.setenv(f"ACQ_{backend.upper()}_STUB_IMAGE_CONTRACT", "missing")
    assert cli.run_doctor(False, "box", backend) == 0
    out = capsys.readouterr().out
    assert f"ADR-0030 image contract diagnostics for box (backend: {backend})" in out
    assert "warning: devenv is not on PATH" in out
    assert "summary: 2 warning(s); diagnostics only, create/run are not blocked" in out


@pytest.mark.parametrize("source", ["flag", "environment"])
def test_unknown_backend_refused(monkeypatch, capsys, source):
    if source == "environment":
        monkeypatch.setenv("ACQ_BACKEND", "bogus")
    assert cli.run_doctor(True, None, "bogus" if source == "flag" else None) == 1
    assert "unknown backend 'bogus'" in json.loads(capsys.readouterr().out)["error"]["message"]


def test_image_check_ids_survive_missing_capabilities():
    complete = cli._image_doctor_checks("  ok: /nix exists\n  ok: /nix is writable\n  ok: nix is on PATH (nix 2.35.2)\n")
    missing = cli._image_doctor_checks("  warning: /nix is missing\n  fix: use a devenv-capable image\n  warning: nix is not on PATH\n  fix: install nix\n")
    assert complete[0]["id"] == missing[0]["id"] == "image-nix-store"
    assert complete[2]["id"] == missing[1]["id"] == "image-tool-nix"


@pytest.mark.parametrize("kind", ["missing", "directory", "relative"])
@pytest.mark.parametrize("emit_json", [False, True], ids=["human", "json"])
def test_doctor_reports_invalid_runtime(tmp_path, monkeypatch, kind, emit_json):
    override = tmp_path / "invalid-python"
    if kind == "directory":
        override.mkdir()
    value = "relative-python" if kind == "relative" else str(override)
    monkeypatch.setenv("ACQ_RUNTIME", value)
    proc = run_cli("doctor", *(["--json"] if emit_json else []))
    # Doctor diagnostics retain their successful command status; the failed
    # runtime check and overall status carry the misconfiguration.
    assert proc.returncode == 0, proc.stderr
    assert "Traceback" not in proc.stderr
    if emit_json:
        data = json.loads(proc.stdout)["data"]
        assert data["status"] == "fail"
        check = next(c for c in data["checks"] if c["id"] == "runtime")
        assert check["status"] == "fail"
        assert "ACQ_RUNTIME" in check["message"] and value in check["message"]
        assert "unset ACQ_RUNTIME" in check["remediation"]
    else:
        assert "[fail] runtime: ACQ_RUNTIME" in proc.stdout
        assert "unset ACQ_RUNTIME" in proc.stdout
        assert "overall: fail" in proc.stdout
