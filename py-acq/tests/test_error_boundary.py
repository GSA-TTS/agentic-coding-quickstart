"""Tier-2 tests for the command error boundary (ADR-0038m §1/§2, ADR-0040m).

Non-contract evidence (ADR-0039m): these drive ``cli.main`` in-process against
the deterministic ``__stub__`` backends, or call adapter helpers directly, to
prove that failures acq cannot avoid (a backend CLI that cannot be started, a
host write that fails, a malformed timeout override) leave through the error
contract (stable code, envelope, exit code) instead of a traceback. The
subprocess-level contract lives in the ``cli/*-backend-missing`` and
``cli/passthrough-*`` vectors.
"""

from __future__ import annotations

import errno
import json
import os
import subprocess
import sys
import time

import pytest

from acq_py import backends, cli, errors, hostexec, lock, migration, msb, sbx, state
from acq_py.commands import lifecycle

pytestmark = pytest.mark.provider_key  # creates msb sandboxes: needs a stored provider key

MISSING_BIN = "/nonexistent/acq-test/backend"


def _env(monkeypatch, tmp_path, *, catalog=None):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    if catalog is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps(catalog))


def _skip_floor(monkeypatch):
    """Let a verb past the version floor so the adapter's own mapping is exercised.

    The floor probes the same program the adapter runs, so a missing ``ACQ_*_BIN``
    is normally refused there first; these tests cover the later failure (the CLI
    vanishing or becoming unrunnable after the check).
    """
    monkeypatch.setattr(backends, "check_version", lambda spec: None)


def _invoke(capsys, *argv):
    """Run ``cli.main``; under ``--json`` stdout must hold at most ONE document."""
    rc = cli.main(list(argv))
    captured = capsys.readouterr()
    out = captured.out.strip()
    lines = out.splitlines()
    assert len(lines) <= 1, f"expected one JSON document on stdout, got {len(lines)}: {out!r}"
    doc = json.loads(lines[0]) if lines else None
    return rc, doc, captured.err


# ---------------------------------------------------------------------------
# Timeout overrides are read lazily and must stay finite and non-negative.
# ---------------------------------------------------------------------------

BAD_TIMEOUTS = ["30s", "abc", "nan", "NaN", "inf", "-inf", "-1"]

TIMEOUT_READERS = [
    (lock.TIMEOUT_ENV, lock.configured_timeout_s, lock.DEFAULT_TIMEOUT_S),
    (msb.READY_TIMEOUT_ENV, msb.ready_timeout_s, msb.DEFAULT_READY_TIMEOUT_S),
    (sbx.READY_TIMEOUT_ENV, sbx.ready_timeout_s, sbx.DEFAULT_READY_TIMEOUT_S),
]


@pytest.mark.parametrize("env_name,reader,default", TIMEOUT_READERS)
@pytest.mark.parametrize("raw", BAD_TIMEOUTS)
def test_bad_timeout_override_falls_back_with_warning(monkeypatch, capsys, env_name, reader, default, raw):
    monkeypatch.setenv(env_name, raw)
    assert reader() == default
    err = capsys.readouterr().err
    assert env_name in err and "ignoring" in err


@pytest.mark.parametrize("env_name,reader,default", TIMEOUT_READERS)
def test_valid_timeout_override_is_read_at_call_time(monkeypatch, capsys, env_name, reader, default):
    # Set AFTER import: an import-time read would miss it.
    monkeypatch.setenv(env_name, "0.25")
    assert reader() == 0.25
    monkeypatch.setenv(env_name, "0")
    assert reader() == 0.0
    monkeypatch.delenv(env_name)
    assert reader() == default
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize(
    "env_name", ["ACQ_MSB_READY_TIMEOUT", "ACQ_SBX_READY_TIMEOUT", "ACQ_MIGRATION_LOCK_TIMEOUT"]
)
def test_malformed_timeout_does_not_break_unrelated_commands(tmp_path, env_name):
    # A fresh interpreter, so the module imports themselves see the bad value.
    env = {**os.environ, env_name: "30s", "ACQ_VERSION": "0.1.0", "ACQ_STATE_DIR": str(tmp_path / "state")}
    proc = subprocess.run(
        [sys.executable, "-m", "acq_py", "version", "--json"],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["command"] == "version"
    assert "Traceback" not in proc.stderr


def test_lock_timeout_set_after_import_bounds_the_wait(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv(lock.TIMEOUT_ENV, "0.2")
    with lock.exclusive_lock(migration.lock_path(), timeout_s=5.0):
        start = time.monotonic()
        with pytest.raises(migration.MigrationError) as exc:
            migration.migrate_tree()
        elapsed = time.monotonic() - start
    assert exc.value.code == errors.MIGRATION_LOCKED
    assert elapsed < 2.0


# ---------------------------------------------------------------------------
# A backend CLI that cannot be started is backend_not_found, never a traceback.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("adapter,env_name", [(msb, "ACQ_MSB_BIN"), (sbx, "ACQ_SBX_BIN")])
def test_run_stream_maps_missing_cli(monkeypatch, adapter, env_name):
    monkeypatch.setenv(env_name, MISSING_BIN)
    with pytest.raises((msb.MsbError, sbx.SbxError)) as exc:
        adapter._run_stream(["exec", "box", "--", "true"], json_mode=False)
    assert exc.value.code == errors.BACKEND_NOT_FOUND


@pytest.mark.parametrize("adapter,env_name", [(msb, "ACQ_MSB_BIN"), (sbx, "ACQ_SBX_BIN")])
def test_run_maps_non_executable_cli(monkeypatch, tmp_path, adapter, env_name):
    # A PermissionError (not just FileNotFoundError) must map to the stable code.
    binary = tmp_path / "backend"
    binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    binary.chmod(0o644)
    if os.access(binary, os.X_OK):
        pytest.skip("cannot make a non-executable file here (running as root?)")
    monkeypatch.setenv(env_name, str(binary))
    with pytest.raises((msb.MsbError, sbx.SbxError)) as exc:
        adapter._run(["ls"])
    assert exc.value.code == errors.BACKEND_NOT_FOUND


def test_exec_streaming_with_missing_cli_gives_envelope(monkeypatch, tmp_path, capsys):
    # The sandbox lookup succeeds, then the streaming exec cannot start the CLI.
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(msb, "exists", lambda name: True)
    monkeypatch.setenv("ACQ_MSB_BIN", MISSING_BIN)
    _skip_floor(monkeypatch)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "--json", "exec", "box", "--", "true")
    assert rc == errors.EXIT_FAILURE
    assert doc["command"] == "exec"
    assert doc["error"]["code"] == errors.BACKEND_NOT_FOUND
    assert "Traceback" not in err


@pytest.mark.parametrize("verb", [["attach", "box"], ["shell", "box"], ["stop", "box"], ["ports", "box"]])
def test_session_verbs_with_missing_cli_give_envelope(monkeypatch, tmp_path, capsys, verb):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_BIN", MISSING_BIN)
    _skip_floor(monkeypatch)
    rc, doc, _err = _invoke(capsys, "--backend", "msb", "--json", *verb)
    assert rc == errors.EXIT_FAILURE
    assert doc["command"] == verb[0]
    assert doc["error"]["code"] == errors.BACKEND_NOT_FOUND


def test_ls_with_missing_cli_human_output(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_BIN", MISSING_BIN)
    _skip_floor(monkeypatch)
    rc = cli.main(["--backend", "msb", "ls"])
    captured = capsys.readouterr()
    assert rc == errors.EXIT_FAILURE
    assert captured.out == ""
    assert "could not be run" in captured.err


def _sbx_env(monkeypatch, tmp_path, *, catalog):
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setenv("ACQ_SBX_STUB_CATALOG", json.dumps(catalog))


@pytest.mark.parametrize("backend,knob,listing", [("msb", "list", "msb list"), ("sbx", "ls", "sbx ls")])
def test_ls_failed_listing_is_a_failure_not_empty(monkeypatch, tmp_path, capsys, backend, knob, listing):
    # A listing that exits non-zero proves nothing about the sandboxes, so ls
    # must fail rather than report "no sandboxes" (ADR-0038m).
    if backend == "msb":
        _env(monkeypatch, tmp_path, catalog={"alpha": "running"})
    else:
        _sbx_env(monkeypatch, tmp_path, catalog={"alpha": "running"})
    monkeypatch.setenv(f"ACQ_{backend.upper()}_STUB_FAIL", knob)
    rc, doc, err = _invoke(capsys, "--backend", backend, "--json", "ls")
    assert rc == errors.EXIT_FAILURE
    assert doc["command"] == "ls"
    assert doc["error"] == {
        "code": errors.FAILURE,
        "message": "could not list sandboxes",
        "remediation": f"check that {backend} works ('{listing}'), then retry",
    }
    assert "raw backend failure" not in err

    rc = cli.main(["--backend", backend, "ls"])
    captured = capsys.readouterr()
    assert rc == errors.EXIT_FAILURE
    assert captured.out == ""
    assert "no sandboxes" not in captured.err
    assert "could not list sandboxes" in captured.err


@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_ls_failed_running_query_is_a_failure(monkeypatch, tmp_path, capsys, backend):
    # Names listed but running state unknown: reporting every sandbox as
    # stopped would be as false as reporting none, so ls fails.
    if backend == "msb":
        _env(monkeypatch, tmp_path, catalog={"alpha": "running"})
    else:
        _sbx_env(monkeypatch, tmp_path, catalog={"alpha": "running"})
    adapter = msb if backend == "msb" else sbx
    monkeypatch.setattr(adapter, "running_names", lambda **_kw: None)
    rc, doc, _err = _invoke(capsys, "--backend", backend, "--json", "ls")
    assert rc == errors.EXIT_FAILURE
    assert doc["error"]["code"] == errors.FAILURE


@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_ls_successful_empty_listing_is_still_no_sandboxes(monkeypatch, tmp_path, capsys, backend):
    if backend == "msb":
        _env(monkeypatch, tmp_path, catalog={})
    else:
        _sbx_env(monkeypatch, tmp_path, catalog={})
    rc, doc, _err = _invoke(capsys, "--backend", backend, "--json", "ls")
    assert rc == errors.EXIT_SUCCESS
    assert doc["data"] == {"sandboxes": []}
    rc = cli.main(["--backend", backend, "ls"])
    assert rc == errors.EXIT_SUCCESS
    assert capsys.readouterr().out.strip() == "no sandboxes"


def test_passthrough_sbx_honours_bin_seam(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    seen: list[list[str]] = []
    real_run = hostexec.run_foreground

    def _spy(argv, *args, **kwargs):
        seen.append(list(argv))
        return real_run(argv, *args, **kwargs)

    monkeypatch.setattr(hostexec, "run_foreground", _spy)
    assert cli.main(["--backend", "sbx", "echo", "hi"]) == 0
    # Forwarded to the binary the sbx adapter itself runs, not a bare PATH `sbx`.
    assert seen[-1] == [*sbx.sbx_command(), "echo", "hi"]


@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_passthrough_with_an_unparseable_bin_override_gives_envelope(monkeypatch, capsys, backend):
    # Passthrough skips the version floor, so the override is first parsed here:
    # an unbalanced quote must not escape as shlex's ValueError.
    monkeypatch.setenv(f"ACQ_{backend.upper()}_BIN", '"/opt/backend --flag')
    rc, doc, err = _invoke(capsys, "--backend", backend, "--json", "notaverb")
    assert rc == errors.EXIT_FAILURE
    assert doc["command"] == "notaverb"
    assert doc["error"]["code"] == errors.BACKEND_NOT_FOUND
    assert "Traceback" not in err


def _ansi_code_page(monkeypatch):
    """Make text-mode subprocess streams default to cp1252, as on a Windows host."""
    import locale

    monkeypatch.setattr(locale, "getencoding", lambda: "cp1252")
    monkeypatch.setattr(locale, "getpreferredencoding", lambda do_setlocale=True: "cp1252")


def _printing_backend(tmp_path, octal: str):
    binary = tmp_path / "backend"
    binary.write_text(f"#!/bin/sh\nprintf '{octal}'\n", encoding="utf-8")
    binary.chmod(0o755)
    return binary


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX shell script as the backend")
@pytest.mark.parametrize("adapter,env_name", [(msb, "ACQ_MSB_BIN"), (sbx, "ACQ_SBX_BIN")])
def test_backend_output_is_read_as_utf8_whatever_the_code_page(monkeypatch, tmp_path, adapter, env_name):
    # "Łukasz" is C5 81 ...: 0x81 has no cp1252 mapping, so reading it with the
    # locale encoding would fail a call that succeeded. A byte that is not UTF-8
    # at all becomes U+FFFD instead of an error.
    _ansi_code_page(monkeypatch)
    monkeypatch.setenv(env_name, str(_printing_backend(tmp_path, "\\305\\201ukasz\\n\\377\\n")))
    proc = adapter._run(["ls"])
    assert proc.returncode == 0
    assert proc.stdout == "Łukasz\n�\n"


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX shell script as the backend")
@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_backend_output_that_is_not_utf8_never_gives_a_traceback(monkeypatch, tmp_path, capsys, backend):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv(f"ACQ_{backend.upper()}_BIN", str(_printing_backend(tmp_path, "\\377\\376box\\n")))
    _skip_floor(monkeypatch)
    _rc, doc, err = _invoke(capsys, "--backend", backend, "--json", "ls")
    assert doc is not None and doc["command"] == "ls"
    assert "Traceback" not in err


@pytest.mark.parametrize("adapter,error", [(msb, msb.MsbError), (sbx, sbx.SbxError)])
def test_input_that_is_not_utf8_is_refused_before_the_backend_runs(monkeypatch, adapter, error):
    # A lone surrogate is how Python carries undecodable environment bytes.
    # Replacing it would send the backend a different secret, so it is refused.
    calls = []
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: calls.append(a))
    with pytest.raises(error) as exc:
        adapter._run(["secret", "set"], input_text="tok\udcffen")
    assert exc.value.code == errors.VALIDATION_FAILED
    assert "tok" not in exc.value.message
    assert calls == []


# ---------------------------------------------------------------------------
# Host write failures keep the contract and do not strand a guest.
# ---------------------------------------------------------------------------

def _fail_write(*_args, **_kwargs):
    raise OSError(errno.ENOSPC, "No space left on device")


def test_record_write_failure_gives_envelope_and_removes_guest(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(state, "record_write", _fail_write)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc == errors.EXIT_FAILURE
    assert doc["command"] == "create"
    assert doc["error"]["code"] == errors.FAILURE
    assert "host state record" in doc["error"]["message"]
    assert "Traceback" not in err
    # The guest acq could not record was removed, so it cannot strand.
    assert not msb.exists("box")


def test_record_write_failure_on_run_removes_guest(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(state, "record_write", _fail_write)
    rc, doc, _err = _invoke(capsys, "--backend", "msb", "run", "shell", str(ws), "--name", "box", "--json")
    assert rc == errors.EXIT_FAILURE
    assert doc["command"] == "run"
    assert doc["error"]["code"] == errors.FAILURE
    assert not msb.exists("box")


def test_kit_record_write_failure_gives_envelope_and_discards(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(lifecycle.kits, "kit_applied_write", _fail_write)
    rc, doc, _err = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "oc", "--json")
    assert rc == errors.EXIT_FAILURE
    assert doc["error"]["code"] == errors.FAILURE
    assert "applied kit" in doc["error"]["message"]
    assert not msb.exists("oc")
    assert state.record_read("msb", "oc") is None


def test_unwritable_state_root_fails_migration_closed(monkeypatch, tmp_path, capsys):
    # A state root below a regular file cannot be created (NotADirectoryError),
    # whatever the user's privileges.
    blocker = tmp_path / "blocker"
    blocker.write_text("", encoding="utf-8")
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_STATE_DIR", str(blocker / "state"))
    with pytest.raises(migration.MigrationError) as exc:
        migration.migrate_tree()
    assert exc.value.code == errors.MIGRATION_FAILED

    rc, doc, err = _invoke(capsys, "--backend", "msb", "--json", "rm", "box")
    assert rc == errors.EXIT_FAILURE
    assert doc["command"] == "rm"
    assert doc["error"]["code"] == errors.MIGRATION_FAILED
    assert "Traceback" not in err


def test_boundary_maps_unhandled_oserror(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)

    def _boom(*_args, **_kwargs):
        raise PermissionError(errno.EACCES, "Permission denied", "/state/x.json")

    monkeypatch.setattr(lifecycle, "run_stop", _boom)
    rc, doc, _err = _invoke(capsys, "--backend", "msb", "--json", "stop", "box")
    assert rc == errors.EXIT_FAILURE
    assert doc["command"] == "stop"
    assert doc["error"]["code"] == errors.FAILURE
    assert "Permission denied" in doc["error"]["message"]


def test_boundary_keeps_secret_has_silent(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)

    def _boom(*_args, **_kwargs):
        raise msb.MsbError(errors.BACKEND_NOT_FOUND, "the msb backend CLI could not be run", "install msb and retry")

    monkeypatch.setattr(cli.secret, "run_secret_has", _boom)
    rc = cli.main(["--backend", "msb", "--json", "secret", "has", "-g", "usai"])
    captured = capsys.readouterr()
    assert rc == errors.EXIT_FAILURE
    assert captured.out == ""
    assert "could not be run" in captured.err


# ---------------------------------------------------------------------------
# stdout carries exactly one document even when run's launch fails late.
# ---------------------------------------------------------------------------

def _launch_cannot_start(*_args, **_kwargs):
    raise msb.cli_unavailable()


def test_run_create_then_launch_failure_keeps_one_document(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(msb, "launch", _launch_cannot_start)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "--json", "run", "shell", str(ws), "--name", "box")
    assert rc == errors.EXIT_FAILURE
    # The one document is run's success envelope; the launch failure is stderr.
    assert doc["command"] == "run" and doc["data"]["action"] == "created"
    assert "could not be run" in err


def test_run_reattach_by_name_launch_failure_keeps_one_document(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    assert _invoke(capsys, "--backend", "msb", "--json", "create", "shell", str(ws), "--name", "box")[0] == 0
    monkeypatch.setattr(msb, "launch", _launch_cannot_start)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "--json", "run", "box")
    assert rc == errors.EXIT_FAILURE
    assert doc["command"] == "run" and doc["data"]["action"] == "reattached"
    assert "could not be run" in err


def test_secret_has_user_dirs_refusal_stays_off_stdout(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_STATE_DIR", "relative/state")
    rc = cli.main(["--backend", "msb", "--json", "secret", "has", "-g", "usai"])
    captured = capsys.readouterr()
    assert rc == errors.EXIT_FAILURE
    assert captured.out == ""
    assert captured.err.strip() != ""
