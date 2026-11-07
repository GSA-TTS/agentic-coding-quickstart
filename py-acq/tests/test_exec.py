"""Tier-2 implementation tests for the exec/attach/shell/cp/ports/passthrough slice.

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly and drive
``cli.main`` in-process against the deterministic ``__stub__`` msb, plus unit-test
the pure host/guest path helpers. Contract evidence lives only in the vector
corpus (``test/vectors``); the stub is an internal test seam, never a secret.
"""

from __future__ import annotations

import json

from acq_py import cli, state


def _env(monkeypatch, tmp_path, *, catalog=None):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in (
        "ACQ_BACKEND",
        "ACQ_MSB_STUB_CATALOG",
        "ACQ_IMAGE",
        "ACQ_MSB_IMAGE",
        "ACQ_MSB_STUB_FAIL",
        "ACQ_MSB_STUB_EXEC_EXIT",
        "ACQ_MSB_STUB_COPY_EXIT",
        "ACQ_MSB_STUB_EXIT_CODE",
        "ACQ_MSB_STUB_PORTS",
        "ACQ_MSB_STUB_INSPECT_RAW",
    ):
        monkeypatch.delenv(name, raising=False)
    if catalog is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps(catalog))


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out.strip()
    doc = json.loads(out.splitlines()[-1]) if out else None
    return rc, doc


# ---------------------------------------------------------------------------
# Pure host/guest path typing (ADR-0038m §4).
# ---------------------------------------------------------------------------

def test_sandbox_ref_typing():
    # A bare NAME: followed by a POSIX-absolute path is a guest ref.
    assert cli._sandbox_ref("box:/tmp/dest.txt") == ("box", "/tmp/dest.txt")
    # Host paths (relative, absolute, backslash) are never guest refs.
    assert cli._sandbox_ref("./host.txt") is None
    assert cli._sandbox_ref("/abs/host.txt") is None
    assert cli._sandbox_ref("C:\\host\\file.txt") is None
    # A single-letter prefix on Windows is a drive letter, a host path.
    if __import__("os").name == "nt":
        assert cli._sandbox_ref("C:/host/file.txt") is None


def test_guest_path_translation():
    # ADR-0029: the adapter derives the POSIX guest form of a native host path.
    from acq_py import msb

    if __import__("os").name == "nt":
        assert msb._guest_path("C:\\Users\\me\\proj") == "/c/Users/me/proj"
        assert msb._guest_path("C:/Users/me/proj") == "/c/Users/me/proj"
    else:
        assert msb._guest_path("/Users/me/proj") == "/Users/me/proj"
    # A value that is already POSIX is unchanged on every platform.
    assert msb._guest_path("/home/agent") == "/home/agent"


def test_guest_path_unc_form(monkeypatch):
    # A mapped network drive resolves to a UNC path under ``os.path.realpath``
    # (e.g. ``Z:`` -> ``\\server\share\proj``); its guest form collapses the
    # leading double backslash to a single slash so the server name is the first
    # component — never a leading ``//``, whose meaning is implementation-defined
    # in the guest. The conversion is Windows-only, so patch ``os.name`` to "nt"
    # to assert it on every host, not just a Windows CI (the drive-form branch is
    # exercised by ``test_guest_path_translation`` under ``os.name == "nt"``).
    from acq_py import msb

    monkeypatch.setattr(msb.os, "name", "nt")
    assert msb._guest_path("\\\\server\\share\\proj") == "/server/share/proj"
    assert msb._guest_path("\\\\server\\share") == "/server/share"


# ---------------------------------------------------------------------------
# Host-authoritative record reads (ADR-0041m: guest-writable state is never
# authority; a missing record defaults the workspace, a newer schema refuses).
# ---------------------------------------------------------------------------

def test_workspace_from_record_and_default(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    state.record_write("msb", "box", agent="opencode", workspace="/home/agent/work")
    assert cli._workspace_from_record("msb", "box") == "/home/agent/work"
    # No record -> the legacy agent-home default.
    assert cli._workspace_from_record("msb", "nope") == cli.DEFAULT_GUEST_WORKSPACE


def test_attach_reads_agent_from_record_and_propagates_status(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    state.record_write("msb", "box", agent="opencode", workspace="/w")
    monkeypatch.setenv("ACQ_MSB_STUB_EXEC_EXIT", "9")

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "attach", "box")
    assert rc == 9
    assert doc["command"] == "attach"
    assert doc["data"]["agent"] == "opencode"
    assert doc["data"]["exit_code"] == 9


def test_attach_missing_record_fails_closed(monkeypatch, tmp_path, capsys):
    # ADR-0038m §48 drops agent-to-shell fallback: attach must not launch a bare
    # shell when the host record is absent.
    _env(monkeypatch, tmp_path, catalog={"box": "running"})

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "attach", "box")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_attach_missing_agent_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    state.record_write("msb", "box", agent=None, workspace="/w")

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "attach", "box")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_exec_requires_command(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "exec", "box")
    assert rc == 2
    assert doc["error"]["code"] == "usage"


def test_exec_preserves_child_status(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_EXEC_EXIT", "42")

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "exec", "box", "--", "false")
    assert rc == 42
    assert doc["data"]["exit_code"] == 42


def _write_raw_record(tmp_path, name, doc):
    path = state.record_path("msb", name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc), encoding="utf-8")


def test_exec_schema_mismatch_fails_closed(monkeypatch, tmp_path, capsys):
    # ADR-0041m: exec must refuse a newer/unknown-schema record, not run in a
    # guessed cwd.
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    _write_raw_record(tmp_path, "box", {"schema": 99, "name": "box", "backend": "msb", "agent": "opencode", "workspace": "/w"})

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "exec", "box", "--", "true")
    assert rc == 1
    assert doc["error"]["code"] == "state_schema_unsupported"


def test_shell_schema_mismatch_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    _write_raw_record(tmp_path, "box", {"schema": 99, "name": "box", "backend": "msb", "workspace": "/w"})

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "shell", "box")
    assert rc == 1
    assert doc["error"]["code"] == "state_schema_unsupported"


def test_ports_inspect_failure_fails_closed(monkeypatch, tmp_path, capsys):
    # ADR-0038m §48 drops inspection-failure-as-empty: a failed inspect is an
    # operational failure, not an empty ports list.
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "inspect")

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "ports", "box")
    assert rc == 1
    assert doc["error"]["code"] == "failure"


def test_ports_inspect_bad_shape_fails_closed(monkeypatch, tmp_path, capsys):
    # A valid-JSON-but-wrong-shape inspect (non-dict intermediate level) must
    # fail closed with a stable code, never raise an uncaught AttributeError.
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_INSPECT_RAW", '{"active_config":"x"}')

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "ports", "box")
    assert rc == 1
    assert doc["error"]["code"] == "failure"


def test_cp_direction_typing(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "cp", "./a.txt", "box:/tmp/d.txt")
    assert rc == 0
    assert doc["data"]["direction"] == "in"
    assert doc["data"]["host"] == "./a.txt"
    assert doc["data"]["guest"] == "/tmp/d.txt"

    rc, doc = _invoke(capsys, "--backend", "msb", "--json", "cp", "box:/tmp/s.txt", "./b.txt")
    assert rc == 0
    assert doc["data"]["direction"] == "out"


def test_passthrough_forwards_unknown_verb(monkeypatch, tmp_path, capfd):
    _env(monkeypatch, tmp_path)

    rc = cli.main(["--backend", "msb", "echo", "hello", "world"])
    assert rc == 0
    # capfd (not capsys): the forwarded backend writes its own stdout at the fd
    # level, which capsys does not observe.
    captured = capfd.readouterr()
    assert "hello world" in captured.out
    assert "forwarding to 'msb'" in captured.err
