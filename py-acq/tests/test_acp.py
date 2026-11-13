"""Tier-2 implementation tests for ``acq acp`` (ADR-0053m).

Non-contract evidence (ADR-0039m): these drive ``cli.main`` in-process against the
deterministic ``__stub__`` backends and look at file descriptors directly, because
the contract here is about fd 1 and fd 0, not about Python objects. Contract
evidence lives in the vector corpus (``test/vectors/cli/acp-*.json``).
"""

from __future__ import annotations

import json
import os
import pty
import select
import signal
import sys

import pytest

from acq_py import cli, hostexec, msb, sbx
from acq_py.commands import acp, common, configure, lifecycle

pytestmark = pytest.mark.provider_key  # a new msb sandbox needs a stored provider key
posix_only = pytest.mark.skipif(sys.platform == "win32", reason="POSIX terminals")


def _fail_on_alarm(_signum, _frame):
    # A prompt that reads the terminal would otherwise hang the run.
    raise AssertionError("acq acp blocked reading the terminal")

STUB_MARKER = "[stub exec]"


def _env(monkeypatch, tmp_path, *, catalog=None):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in ("ACQ_BACKEND", "ACQ_MSB_STUB_CATALOG", "ACQ_IMAGE", "ACQ_MSB_IMAGE", "ACQ_MSB_STUB_FAIL"):
        monkeypatch.delenv(name, raising=False)
    if catalog is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps(catalog))


def _workspace(tmp_path):
    ws = tmp_path / "ws"
    ws.mkdir()
    return str(ws)


# ---------------------------------------------------------------------------
# Invariant 4: ACP entrypoint resolution.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("agent", "args", "expected"),
    [
        ("opencode", [], ["opencode", "acp"]),
        ("opencode", ["--print-logs"], ["opencode", "acp", "--print-logs"]),
        ("opencode", ["custom-acp", "--stdio"], ["custom-acp", "--stdio"]),
        ("gemini", [], ["gemini", "acp"]),
        ("shell", [], None),
        ("shell", ["--x"], None),
        ("not-an-agent", [], None),
        ("", [], None),
    ],
)
def test_acp_argv(agent, args, expected):
    assert acp.acp_argv(agent, args) == expected


def test_shell_is_refused_with_usage_exit_and_no_stdout(monkeypatch, tmp_path, capfd):
    _env(monkeypatch, tmp_path)
    assert cli.main(["--backend", "msb", "acp", "shell", _workspace(tmp_path)]) == 2
    captured = capfd.readouterr()
    assert captured.out == ""
    assert "not an ACP-capable agent" in captured.err


def test_unknown_target_is_a_usage_error(monkeypatch, tmp_path, capfd):
    _env(monkeypatch, tmp_path)
    assert cli.main(["--backend", "msb", "acp", "nosuch"]) == 2
    captured = capfd.readouterr()
    assert captured.out == ""
    assert "not a known agent or an existing sandbox" in captured.err


def test_json_is_refused_because_stdout_is_the_protocol(monkeypatch, tmp_path, capfd):
    _env(monkeypatch, tmp_path)
    assert cli.main(["--backend", "msb", "--json", "acp", "opencode", _workspace(tmp_path)]) == 2
    doc = json.loads(capfd.readouterr().out)
    assert doc["error"]["code"] == "usage"


def test_a_sandbox_recorded_with_the_shell_agent_is_refused(monkeypatch, tmp_path, capfd):
    from acq_py import state

    _env(monkeypatch, tmp_path, catalog={"sh": "running"})
    state.record_write("msb", "sh", agent="shell", workspace=_workspace(tmp_path), image=None)
    assert cli.main(["--backend", "msb", "acp", "sh"]) == 2
    assert capfd.readouterr().out == ""


# ---------------------------------------------------------------------------
# Invariant 1: stdout purity, at the descriptor level.
# ---------------------------------------------------------------------------

def test_clean_stdio_sends_fd1_to_stderr_and_restores_it(capfd):
    with acp.CleanStdio():
        os.write(1, b"prologue noise\n")
    os.write(1, b"protocol frame\n")
    captured = capfd.readouterr()
    assert captured.out == "protocol frame\n"
    assert "prologue noise" in captured.err


def test_clean_stdio_binds_stdin_to_the_null_device_and_restores_it():
    read_end, write_end = os.pipe()
    saved = os.dup(0)
    try:
        os.dup2(read_end, 0)
        os.write(write_end, b"client frame\n")
        with acp.CleanStdio():
            assert os.read(0, 16) == b""  # the null device, not the client's pipe
        assert os.read(0, 16) == b"client frame\n"  # nothing was consumed
    finally:
        os.dup2(saved, 0)
        for fd in (saved, read_end, write_end):
            os.close(fd)


def test_clean_stdio_restore_is_idempotent(capfd):
    stdio = acp.CleanStdio()
    with stdio:
        stdio.restore()
        stdio.restore()
    os.write(1, b"after\n")
    assert capfd.readouterr().out == "after\n"


def test_clean_stdio_restores_on_an_exception(capfd):
    with pytest.raises(RuntimeError), acp.CleanStdio():
        raise RuntimeError("boom")
    os.write(1, b"after\n")
    assert capfd.readouterr().out == "after\n"


def test_create_then_stream_leaves_only_the_agent_on_stdout(monkeypatch, tmp_path, capfd):
    _env(monkeypatch, tmp_path)
    rc = cli.main(["--backend", "msb", "acp", "opencode", _workspace(tmp_path), "--name", "acp-box",
                   "--no-provider-kits"])
    captured = capfd.readouterr()
    assert rc == 0
    assert captured.out == f"{STUB_MARKER} opencode acp\n"


def test_reattach_by_name_streams_the_recorded_agent(monkeypatch, tmp_path, capfd):
    _env(monkeypatch, tmp_path)
    ws = _workspace(tmp_path)
    assert cli.main(["--backend", "msb", "acp", "opencode", ws, "--name", "again", "--no-provider-kits"]) == 0
    capfd.readouterr()
    assert cli.main(["--backend", "msb", "acp", "again"]) == 0
    assert capfd.readouterr().out == f"{STUB_MARKER} opencode acp\n"


def test_arguments_after_the_separator_reach_the_guest(monkeypatch, tmp_path, capfd):
    _env(monkeypatch, tmp_path)
    ws = _workspace(tmp_path)
    assert cli.main(["--backend", "msb", "acp", "opencode", ws, "--name", "args", "--no-provider-kits"]) == 0
    capfd.readouterr()
    assert cli.main(["--backend", "msb", "acp", "args", "--", "--print-logs"]) == 0
    assert capfd.readouterr().out == f"{STUB_MARKER} opencode acp --print-logs\n"
    assert cli.main(["--backend", "msb", "acp", "args", "--", "custom-acp", "--stdio"]) == 0
    assert capfd.readouterr().out == f"{STUB_MARKER} custom-acp --stdio\n"


# ---------------------------------------------------------------------------
# Invariant 2: non-interactive and fail closed.
# ---------------------------------------------------------------------------

def test_prologue_runs_with_prompts_off_and_the_environment_is_put_back(monkeypatch, tmp_path, capfd):
    _env(monkeypatch, tmp_path)
    monkeypatch.delenv("ACQ_NO_PROMPT", raising=False)
    monkeypatch.setenv("ACQ_UPDATE_CHECK", "1")
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: True)  # an IDE could front a terminal
    seen = {}

    def fake_run(parsed, emit_json, backend, launch=None):
        seen["no_prompt"] = os.environ.get("ACQ_NO_PROMPT")
        seen["update_check"] = os.environ.get("ACQ_UPDATE_CHECK")
        seen["interactive"] = configure.interactive(False)
        seen["stdin_is_null"] = os.read(0, 1) == b""
        return 0

    monkeypatch.setattr(lifecycle, "run_run", fake_run)
    assert cli.main(["--backend", "msb", "acp", "opencode", _workspace(tmp_path)]) == 0
    assert seen == {"no_prompt": "1", "update_check": "0", "interactive": False, "stdin_is_null": True}
    assert "ACQ_NO_PROMPT" not in os.environ
    assert os.environ["ACQ_UPDATE_CHECK"] == "1"
    capfd.readouterr()


@posix_only
def test_a_missing_credential_fails_closed_even_with_a_terminal_on_stdin(monkeypatch, tmp_path, capfd):
    # A real terminal on fd 0 holding a pending "y": were the credential prompt
    # reached it would read the answer and go on. acq acp must not touch it.
    _env(monkeypatch, tmp_path)
    monkeypatch.delenv("USAI_API_KEY", raising=False)
    monkeypatch.setenv("ACQ_SECRET_STORE_DIR", str(tmp_path / "empty-store"))
    master, slave = pty.openpty()
    saved = os.dup(0)
    previous_alarm = signal.signal(signal.SIGALRM, _fail_on_alarm)
    signal.alarm(20)
    try:
        os.dup2(slave, 0)
        monkeypatch.setattr(sys, "stdin", open(0, closefd=False))  # noqa: SIM115 # closed with fd 0 below
        assert common._stdin_is_terminal()
        os.write(master, b"y\n")
        rc = cli.main(["--backend", "msb", "acp", "opencode", _workspace(tmp_path), "--name", "nokey"])
        captured = capfd.readouterr()
        assert rc == 1
        assert captured.out == ""
        assert "acq secret set" in captured.err
        assert "Store it now?" not in captured.err
        assert select.select([0], [], [], 1)[0], "the pending answer was consumed"
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous_alarm)
        os.dup2(saved, 0)
        for fd in (saved, master, slave):
            os.close(fd)


def test_a_launch_failure_is_reported_on_stderr_with_exit_one(monkeypatch, tmp_path, capfd):
    _env(monkeypatch, tmp_path)

    def vanished(*_a, **_k):
        raise msb.cli_unavailable()

    monkeypatch.setattr(msb, "stream_command", vanished)
    rc = cli.main(["--backend", "msb", "acp", "opencode", _workspace(tmp_path), "--name", "gone",
                   "--no-provider-kits"])
    captured = capfd.readouterr()
    assert rc == 1
    assert captured.out == ""


# ---------------------------------------------------------------------------
# Invariant 3: pipe-clean streaming, no PTY.
# ---------------------------------------------------------------------------

def _capture_argv(monkeypatch):
    seen = []
    monkeypatch.setattr(hostexec, "run_foreground", lambda argv, stdout=None: seen.append(list(argv)) or 0)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    return seen


def test_msb_streams_with_stream_and_never_a_pty(monkeypatch):
    seen = _capture_argv(monkeypatch)
    assert msb.stream_command("box", ["opencode", "acp"], workspace="/w", env=["X=1"]) == 0
    argv = seen[0]
    assert "--stream" in argv
    assert "-t" not in argv
    assert argv[argv.index("exec") + 1] == "--stream"
    assert argv[argv.index("--") + 1 :] == ["opencode", "acp"]
    assert "HOME=/home/agent" in argv and "X=1" in argv


def test_sbx_streams_with_i_and_never_a_pty(monkeypatch):
    seen = _capture_argv(monkeypatch)
    assert sbx.stream_command("box", ["opencode", "acp"], env=["X=1"]) == 0
    argv = seen[0]
    assert "-i" in argv
    assert "-it" not in argv and "-t" not in argv
    assert argv[argv.index("--") + 1 :] == ["opencode", "acp"]


@pytest.mark.parametrize("adapter", [msb, sbx])
def test_the_ordinary_exec_does_not_stream(monkeypatch, adapter):
    seen = _capture_argv(monkeypatch)
    adapter.exec_command("box", ["true"])
    assert "--stream" not in seen[0]
    assert "-i" not in seen[0]


def test_streaming_is_not_used_by_the_interactive_launch(monkeypatch):
    seen = _capture_argv(monkeypatch)
    msb.launch("box", "/w", "opencode", tty=True)
    assert "--stream" not in seen[0]
    assert "-t" in seen[0]


# ---------------------------------------------------------------------------
# Wiring: the verb is registered at every dispatch point.
# ---------------------------------------------------------------------------

def test_acp_is_registered_with_the_dispatch_and_mutating_set():
    assert "acp" in cli.KNOWN_COMMANDS
    parsed = cli.build_parser().parse_args(["acp", "opencode", "."])
    assert cli._is_mutating(parsed)


def test_run_still_launches_in_the_foreground_by_default(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    launched = {}
    monkeypatch.setattr(msb, "launch", lambda name, workspace, agent, **kw: launched.update(agent=agent) or 0)
    rc = cli.main(["--backend", "msb", "run", "opencode", _workspace(tmp_path), "--name", "plain",
                   "--no-provider-kits", "--json"])
    assert rc == 0
    assert launched["agent"] == "opencode"
    capsys.readouterr()
