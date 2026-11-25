"""Tier-2 implementation tests for backend detection and version floors.

Non-contract evidence (ADR-0039m): these reach into ``acq_py.backends`` directly.
Contract evidence lives only in the vector corpus (``test/vectors``).
"""

from __future__ import annotations

import json
import shlex
import subprocess
import sys

import pytest

import acq_py.backends as backends
from acq_py import cli, errors, msb, sbx


def test_parse_version_bare():
    v = backends.parse_version("0.39.0")
    assert v is not None
    assert (v.major, v.minor, v.patch) == (0, 39, 0)
    assert v.final is True
    assert v.string == "0.39.0"


def test_parse_version_strips_prefix_and_suffix():
    v = backends.parse_version("msb 0.7.7")
    assert v is not None and v.string == "0.7.7"

    v = backends.parse_version("v0.39.0")
    assert v is not None and v.string == "0.39.0"

    v = backends.parse_version("0.7.3-rc1")
    assert v is not None and v.string == "0.7.3" and v.final is False


def test_parse_version_unparseable():
    assert backends.parse_version("garbage") is None
    assert backends.parse_version("") is None
    assert backends.parse_version(None) is None  # type: ignore[arg-type]


def test_version_ge_ignores_final():
    final = backends.parse_version("0.7.3")
    rc = backends.parse_version("0.7.3-rc1")
    assert final is not None and rc is not None
    # Numeric core is equal, so >= holds regardless of the final flag.
    assert backends.version_ge(rc, final)
    assert backends.version_ge(final, rc)


def test_check_version_floor(monkeypatch):
    sbx = backends.BACKENDS["sbx"]
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")

    monkeypatch.setenv("ACQ_SBX_VERSION", "0.35.0")
    problem = backends.check_version(sbx)
    assert problem is not None and problem.code == "backend_version_unsupported"

    monkeypatch.setenv("ACQ_SBX_VERSION", "garbage")
    problem = backends.check_version(sbx)
    assert problem is not None and problem.code == "backend_version_unknown"

    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    assert backends.check_version(sbx) is None


def test_check_version_blocked(monkeypatch):
    msb = backends.BACKENDS["msb"]
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")

    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.1")
    problem = backends.check_version(msb)
    assert problem is not None and problem.code == "backend_version_unsupported"

    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.3")
    assert backends.check_version(msb) is None

    # Prerelease of a fixed version is still refused (final-release gate).
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.3-rc1")
    problem = backends.check_version(msb)
    assert problem is not None and problem.code == "backend_version_unsupported"


def test_check_version_not_found(monkeypatch):
    sbx = backends.BACKENDS["sbx"]
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    problem = backends.check_version(sbx)
    assert problem is not None and problem.code == "backend_not_found"


def test_check_capability_floor(monkeypatch):
    sbx = backends.BACKENDS["sbx"]
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")

    # A capability with no declared floor passes at the global floor.
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    assert backends.check_capability_floor(sbx, "secret-write") is None

    # provider-credential-set needs sbx >= 0.51.0 (`secret set-custom --value-stdin`).
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.50.1")
    problem = backends.check_capability_floor(sbx, "provider-credential-set")
    assert problem is not None and problem.code == "backend_version_unsupported"

    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    assert backends.check_capability_floor(sbx, "provider-credential-set") is None

    # An unknown version is the global floor's refusal, not this capability's.
    monkeypatch.setenv("ACQ_SBX_VERSION", "garbage")
    assert backends.check_capability_floor(sbx, "provider-credential-set") is None

    # msb declares no per-capability floors.
    msb = backends.BACKENDS["msb"]
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    assert backends.check_capability_floor(msb, "provider-credential-set") is None


# ---------------------------------------------------------------------------
# The floor is checked against the program the adapter runs (ACQ_*_BIN).
# ---------------------------------------------------------------------------

_FAKE_BACKEND = """\
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as log:
    log.write(json.dumps(sys.argv[3:]) + "\\n")
if sys.argv[3:] in (["--version"], ["version"]):
    print(sys.argv[2])
    raise SystemExit(0)
raise SystemExit(97)
"""


def _fake_backend(tmp_path, monkeypatch, name, reported):
    """Point ACQ_<NAME>_BIN at a fake CLI that reports ``reported`` and logs every call."""
    script = tmp_path / f"fake-{name}.py"
    script.write_text(_FAKE_BACKEND, encoding="utf-8")
    log = tmp_path / f"fake-{name}.log"
    if sys.platform == "win32":
        command = subprocess.list2cmdline([sys.executable, str(script), str(log), reported])
    else:
        command = shlex.join([sys.executable, str(script), str(log), reported])
    monkeypatch.setenv(f"ACQ_{name.upper()}_BIN", command)
    return log


def _calls(log):
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]


@pytest.mark.parametrize(
    "reported,code",
    [
        ("msb 0.7.1", errors.BACKEND_VERSION_UNSUPPORTED),  # blocked range
        ("msb 0.6.8", errors.BACKEND_VERSION_UNSUPPORTED),  # below the floor
        ("msb 0.7.11-rc1", errors.BACKEND_VERSION_UNSUPPORTED),  # not final
        ("msb dev build", errors.BACKEND_VERSION_UNKNOWN),
    ],
)
def test_msb_bin_override_is_version_checked(tmp_path, monkeypatch, reported, code):
    log = _fake_backend(tmp_path, monkeypatch, "msb", reported)
    problem = backends.check_version(backends.BACKENDS["msb"])
    assert problem is not None and problem.code == code
    assert _calls(log) == [["--version"]]


def test_sbx_bin_override_is_version_checked(tmp_path, monkeypatch):
    log = _fake_backend(tmp_path, monkeypatch, "sbx", "sbx version v0.35.0 (abc)")
    problem = backends.check_version(backends.BACKENDS["sbx"])
    assert problem is not None and problem.code == errors.BACKEND_VERSION_UNSUPPORTED
    assert _calls(log) == [["version"]]


def test_supported_bin_override_passes_and_reports_its_own_version(tmp_path, monkeypatch):
    # 0.7.8 is deliberately not a version any real msb on PATH is likely to be.
    _fake_backend(tmp_path, monkeypatch, "msb", "msb 0.7.8")
    assert backends.check_version(backends.BACKENDS["msb"]) is None
    status = backends.detect(backends.BACKENDS["msb"])
    assert (status.installed, status.version) == (True, "0.7.8")


@pytest.mark.parametrize("name,adapter_command", [("msb", msb.msb_command), ("sbx", sbx.sbx_command)])
def test_version_probe_runs_the_adapter_argv(tmp_path, monkeypatch, name, adapter_command):
    _fake_backend(tmp_path, monkeypatch, name, f"{name} 9.9.9")
    seen: list[list[str]] = []
    real_run = subprocess.run

    def _spy(argv, *args, **kwargs):
        seen.append(list(argv))
        return real_run(argv, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", _spy)
    spec = backends.BACKENDS[name]
    backends.detect(spec)
    assert seen == [[*adapter_command(), *spec.version_argv]]


def test_forced_version_does_not_rescue_a_real_override(tmp_path, monkeypatch):
    # ACQ_MSB_VERSION/INSTALLED are a stub-only seam: with a real program named
    # by ACQ_MSB_BIN, the program's own report is what the floor sees.
    log = _fake_backend(tmp_path, monkeypatch, "msb", "msb 0.7.1")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.11")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    problem = backends.check_version(backends.BACKENDS["msb"])
    assert problem is not None and problem.code == errors.BACKEND_VERSION_UNSUPPORTED
    assert _calls(log) == [["--version"]]
    # Forcing the backend absent can only refuse, so it is honoured for a real
    # program too, without running it.
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    assert backends.detect(backends.BACKENDS["msb"]).installed is False
    assert _calls(log) == [["--version"]]


def test_forced_installed_does_not_rescue_a_missing_override(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_BIN", "/nonexistent/acq-test/msb")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.11")
    problem = backends.check_version(backends.BACKENDS["msb"])
    assert problem is not None and problem.code == errors.BACKEND_NOT_FOUND
    assert "ACQ_MSB_BIN" in problem.message
    assert problem.remediation == "fix ACQ_MSB_BIN (or unset it) and retry"


def test_forced_absent_does_not_blame_the_override(tmp_path, monkeypatch):
    # INSTALLED=0 made the backend absent, not the override: say so plainly.
    _fake_backend(tmp_path, monkeypatch, "msb", "msb 0.7.11")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    problem = backends.check_version(backends.BACKENDS["msb"])
    assert problem is not None and problem.code == errors.BACKEND_NOT_FOUND
    assert "ACQ_MSB_BIN" not in problem.message
    assert "ACQ_MSB_BIN" not in (problem.remediation or "")


def test_blocked_bin_override_refuses_create_before_any_backend_mutation(tmp_path, monkeypatch, capsys):
    log = _fake_backend(tmp_path, monkeypatch, "msb", "msb 0.7.1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    workspace = tmp_path / "ws"
    workspace.mkdir()
    rc = cli.main(["--backend", "msb", "--json", "create", "opencode", str(workspace), "--name", "floor"])
    doc = json.loads(capsys.readouterr().out)
    assert rc == errors.EXIT_FAILURE
    assert doc["error"]["code"] == errors.BACKEND_VERSION_UNSUPPORTED
    # Only the version probe reached the backend: no create, list or exec.
    assert _calls(log) == [["--version"]]


def test_stub_sentinel_matches_the_adapters():
    # backends keeps its own copy to avoid importing the adapters at load time.
    assert backends.STUB_SENTINEL == msb.STUB_SENTINEL == sbx.STUB_SENTINEL
