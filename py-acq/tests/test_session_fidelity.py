"""Session fidelity: PTY allocation, session environment and foreground signals.

``acq attach`` and ``acq shell`` hand the terminal to the backend: with a TTY on
stdin the session gets ``msb exec -t`` / ``sbx exec -it``; without one it gets
neither. Every session carries HOME, SHELL (interactive), TERM/COLORTERM
(interactive) and the host git identity, and SSH_AUTH_SOCK only when the
sandbox records a forwarded ssh-agent socket. A child killed by signal N gives
acq status 128+N, and Ctrl-C reaches the child instead of killing it.

The backend is a small fake CLI written per test: it answers the version and
list probes, prints a passwd line for the agent-shell probe, and logs every
other ``exec`` with its argv and whether its stdin is a terminal. The PTY cases
run acq under ``pty.fork`` so stdin really is a terminal, as it is for a user.
"""

from __future__ import annotations

import json
import os
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

from acq_py import hostexec, msb, sbx, state

posix_only = pytest.mark.skipif(sys.platform == "win32", reason="POSIX terminals and signals")

FAKE_BACKEND = r'''
import json, os, signal, sys, time

args = sys.argv[1:]
log = os.environ["FAKE_LOG"]


def record(**fields):
    with open(log, "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"argv": args, **fields}) + "\n")


if args[:1] == ["--version"]:
    print("msb 0.7.11")
elif args[:1] == ["version"]:
    print("sbx version 0.51.0")
elif args[:1] in (["list"], ["ls"]):
    print("box")
elif args[:1] == ["exec"] and "getent passwd agent" in " ".join(args):
    raw = os.environ.get("FAKE_SHELL_STDOUT_HEX")
    getent_dir = os.environ.get("FAKE_GETENT_DIR")
    if raw is not None:
        # A guest whose output is not text at all.
        sys.stdout.buffer.write(bytes.fromhex(raw))
    elif getent_dir is not None:
        # Run acq's real guest script, with getent answering from a fixture.
        import subprocess
        env = dict(os.environ, PATH=getent_dir + os.pathsep + os.environ.get("PATH", ""))
        sys.exit(subprocess.run(args[args.index("--") + 1 :], env=env).returncode)
    else:
        print("/bin/bash")
elif args[:1] == ["exec"]:
    record(tty=os.isatty(0))
    mode = os.environ.get("FAKE_MODE", "")
    if mode == "sigterm":
        os.kill(os.getpid(), signal.SIGTERM)
        time.sleep(5)
    if mode == "die-on-int":
        signal.signal(signal.SIGINT, signal.SIG_DFL)
        record(event="ready", pid=os.getpid())
        time.sleep(20)
        sys.exit(3)
    if mode == "trap":
        def on_interrupt(_signum, _frame):
            # Take a while to clean up: a parent that SIGKILLs on Ctrl-C (after
            # subprocess.run's 0.25 s grace) never sees "cleaned-up".
            time.sleep(1.0)
            record(event="cleaned-up")
            sys.exit(7)

        signal.signal(signal.SIGINT, on_interrupt)
        record(event="ready")
        time.sleep(20)
        sys.exit(3)
else:
    sys.exit(0)
'''


@pytest.fixture
def fake(tmp_path, monkeypatch):
    """A fake msb/sbx CLI wired into both adapters; returns its log reader."""
    script = tmp_path / "fake-backend"
    script.write_text(f"#!{sys.executable}\n{FAKE_BACKEND}", encoding="utf-8")
    script.chmod(0o755)
    log = tmp_path / "fake.log"
    monkeypatch.setenv("FAKE_LOG", str(log))
    monkeypatch.setenv("ACQ_MSB_BIN", str(script))
    monkeypatch.setenv("ACQ_SBX_BIN", str(script))
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    for var in ("TERM", "COLORTERM", "EMAIL", "SSH_AUTH_SOCK", "FAKE_MODE", "FAKE_GETENT_DIR", "FAKE_SHELL_STDOUT_HEX"):
        monkeypatch.delenv(var, raising=False)
    for var in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"):
        monkeypatch.delenv(var, raising=False)

    def entries() -> list[dict]:
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]

    return entries


def _sessions(entries: list[dict]) -> list[dict]:
    """The logged session execs (the version/list/passwd probes are not logged)."""
    return [e for e in entries if "event" not in e]


def _env_flags(argv: list[str]) -> dict[str, str]:
    """The ``-e NAME=value`` pairs before the sandbox name, as a dict."""
    head = argv[: argv.index("--")]
    pairs = [head[i + 1] for i, token in enumerate(head[:-1]) if token == "-e"]
    return dict(pair.split("=", 1) for pair in pairs)


def _acq(*argv: str) -> list[str]:
    return [sys.executable, "-m", "acq_py", *argv]


def _run_in_pty(argv: list[str], *, interrupt_when=None, timeout: float = 30.0) -> tuple[int, bytes]:
    """Run ``argv`` (e.g. :func:`_acq`) with a PTY as its controlling terminal.

    ``interrupt_when`` is polled while the child runs; once it returns true,
    Ctrl-C is typed on the terminal, so the line discipline sends SIGINT to the
    foreground process group (acq and its backend child), as a real one does.
    The child is reaped as soon as it exits, whatever the terminal does, and is
    killed if it outlives ``timeout``.
    """
    import pty  # POSIX only; imported here so the module still collects on Windows

    pid, fd = pty.fork()
    if pid == 0:  # child: become the program
        try:
            os.execv(argv[0], argv)
        finally:
            os._exit(127)
    output = b""
    interrupted = False
    status = None
    deadline = time.monotonic() + timeout
    try:
        while status is None and time.monotonic() < deadline:
            if interrupt_when is not None and not interrupted and interrupt_when():
                os.write(fd, b"\x03")
                interrupted = True
            output += _read_ready(fd, 0.05)
            reaped, raw = os.waitpid(pid, os.WNOHANG)
            if reaped:
                status = raw
        if status is None:
            os.kill(pid, signal.SIGKILL)
            _, status = os.waitpid(pid, 0)
        output += _read_ready(fd, 0)
    finally:
        os.close(fd)
    return os.waitstatus_to_exitcode(status), output


def _read_ready(fd: int, wait: float) -> bytes:
    """Read whatever the terminal has buffered, waiting up to ``wait`` for it."""
    data = b""
    while select.select([fd], [], [], wait)[0]:
        try:
            chunk = os.read(fd, 4096)
        except OSError:  # EIO: no process has the terminal open any more
            break
        if not chunk:
            break
        data += chunk
        wait = 0
    return data


def _run_no_tty(argv: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "acq_py", *argv],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _record(backend: str, *, agent: str = "opencode", ssh_auth_sock: str | None = None) -> None:
    state.record_write(backend, "box", agent=agent, workspace="/work")
    if ssh_auth_sock is not None:
        path = state.record_path(backend, "box")
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["ssh_auth_sock"] = ssh_auth_sock
        path.write_text(json.dumps(doc), encoding="utf-8")


# ---------------------------------------------------------------------------
# PTY allocation follows stdin.
# ---------------------------------------------------------------------------

@posix_only
def test_msb_shell_with_a_tty_gets_a_pty_and_terminal_env(fake, monkeypatch):
    monkeypatch.setenv("TERM", "xterm-256color")
    monkeypatch.setenv("COLORTERM", "truecolor")
    _record("msb", agent="shell")
    rc, out = _run_in_pty(_acq("--backend", "msb", "shell", "box"))
    assert rc == 0, out
    [session] = _sessions(fake())
    argv = session["argv"]
    assert argv[:2] == ["exec", "-t"]
    assert session["tty"] is True
    env = _env_flags(argv)
    assert env["TERM"] == "xterm-256color"
    assert env["COLORTERM"] == "truecolor"
    assert env["HOME"] == "/home/agent"
    # The agent's passwd shell, run as a login shell and exported as SHELL.
    assert env["SHELL"] == "/bin/bash"
    assert argv[argv.index("--") + 1 :] == ["/bin/bash", "-l"]


@posix_only
def test_sbx_attach_with_a_tty_gets_exec_it(fake, monkeypatch):
    monkeypatch.setenv("TERM", "xterm-256color")
    _record("sbx")
    rc, out = _run_in_pty(_acq("--backend", "sbx", "attach", "box"))
    assert rc == 0, out
    [session] = _sessions(fake())
    argv = session["argv"]
    assert argv[:2] == ["exec", "-it"]
    assert session["tty"] is True
    env = _env_flags(argv)
    assert env["TERM"] == "xterm-256color"
    assert env["HOME"] == "/home/agent"
    assert "SHELL" not in env  # the sbx template's own value applies
    assert argv[argv.index("--") + 1 :] == ["opencode"]


@posix_only
@pytest.mark.parametrize("backend", ["msb", "sbx"])
@pytest.mark.parametrize("verb", ["attach", "shell"])
def test_session_without_a_tty_gets_no_pty_flag(fake, monkeypatch, backend, verb):
    monkeypatch.setenv("TERM", "xterm-256color")
    _record(backend)
    proc = _run_no_tty(["--backend", backend, verb, "box"])
    assert proc.returncode == 0, proc.stderr
    [session] = _sessions(fake())
    argv = session["argv"]
    head = argv[: argv.index("box")]
    assert "-t" not in head and "-it" not in head
    assert session["tty"] is False
    env = _env_flags(argv)
    assert "TERM" not in env  # no terminal to describe
    assert env["HOME"] == "/home/agent"


# ---------------------------------------------------------------------------
# Session environment.
# ---------------------------------------------------------------------------

@posix_only
@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_session_env_carries_the_git_identity(fake, monkeypatch, backend):
    monkeypatch.setenv("GIT_AUTHOR_NAME", "Ada Lovelace")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "ada@example.gov")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "bad\nvalue")  # skipped: would split the entry
    monkeypatch.setenv("EMAIL", "ada@example.gov")
    _record(backend)
    proc = _run_no_tty(["--backend", backend, "exec", "box", "--", "git", "commit"])
    assert proc.returncode == 0, proc.stderr
    [session] = _sessions(fake())
    env = _env_flags(session["argv"])
    assert env["GIT_AUTHOR_NAME"] == "Ada Lovelace"
    assert env["GIT_COMMITTER_EMAIL"] == "ada@example.gov"
    assert env["EMAIL"] == "ada@example.gov"
    assert "GIT_AUTHOR_EMAIL" not in env
    assert env["HOME"] == "/home/agent"


@pytest.mark.skipif(hostexec.which("git") is None, reason="needs git on the host")
def test_email_falls_back_to_the_global_git_config(fake, monkeypatch):
    home = Path(os.environ["HOME"])
    (home / ".gitconfig").write_text("[user]\n\temail = grace@example.gov\n", encoding="utf-8")
    monkeypatch.delenv("GIT_CONFIG_GLOBAL", raising=False)
    from acq_py.commands import session

    assert "EMAIL=grace@example.gov" in session.host_git_identity_env()


@posix_only
@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_ssh_auth_sock_is_passed_only_with_recorded_forwarding(fake, monkeypatch, backend):
    # The host's own socket is a host path: never forwarded on its own.
    monkeypatch.setenv("SSH_AUTH_SOCK", "/tmp/host-agent.sock")
    _record(backend)
    assert _run_no_tty(["--backend", backend, "shell", "box"]).returncode == 0
    _record(backend, ssh_auth_sock="/home/agent/.acq/ssh-agent.sock")
    assert _run_no_tty(["--backend", backend, "shell", "box"]).returncode == 0
    _record(backend, ssh_auth_sock="/home/agent/x;rm -rf ~")  # unsafe: refused
    assert _run_no_tty(["--backend", backend, "shell", "box"]).returncode == 0
    without, forwarded, unsafe = (_env_flags(s["argv"]) for s in _sessions(fake()))
    assert "SSH_AUTH_SOCK" not in without
    assert forwarded["SSH_AUTH_SOCK"] == "/home/agent/.acq/ssh-agent.sock"
    assert "SSH_AUTH_SOCK" not in unsafe


@posix_only
def test_launch_in_process_builds_the_session(fake, monkeypatch):
    # In-process twin of the PTY cases (for coverage): tty=True forces -t.
    monkeypatch.setenv("TERM", "screen")
    assert msb.launch("box", "/work", "opencode", tty=True, env=["EMAIL=a@b.gov"]) == 0
    assert sbx.launch("box", "/work", "shell", tty=False, env=None) == 0
    first, second = _sessions(fake())
    assert first["argv"][:2] == ["exec", "-t"]
    assert _env_flags(first["argv"]) == {
        "HOME": "/home/agent",
        "SHELL": "/bin/bash",
        "TERM": "screen",
        "EMAIL": "a@b.gov",
    }
    assert first["argv"][first["argv"].index("--") + 1 :] == ["opencode"]
    assert second["argv"][:2] == ["exec", "-e"]
    assert "SHELL" not in _env_flags(second["argv"])
    # Bash's acq_backend_shell runs `sbx exec -it NAME bash`.
    assert second["argv"][second["argv"].index("--") + 1 :] == ["bash"]


def test_agent_shell_falls_back_on_an_unexpected_passwd_entry(monkeypatch):
    def fake_run(_argv, **_kwargs):
        return subprocess.CompletedProcess([], 0, stdout="/bin/ba sh\n", stderr="")

    monkeypatch.setattr(msb, "_run", fake_run)
    assert msb.agent_shell("box") == "/bin/sh"

    def timed_out(_argv, **_kwargs):
        raise subprocess.TimeoutExpired("msb", 10)

    monkeypatch.setattr(msb, "_run", timed_out)
    assert msb.agent_shell("box") == "/bin/sh"


# ---------------------------------------------------------------------------
# Foreground signals.
# ---------------------------------------------------------------------------

@posix_only
@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_child_killed_by_sigterm_gives_143(fake, monkeypatch, backend):
    monkeypatch.setenv("FAKE_MODE", "sigterm")
    proc = _run_no_tty(["--backend", backend, "exec", "box", "--", "true"])
    assert proc.returncode == 143
    json_proc = _run_no_tty(["--backend", backend, "--json", "exec", "box", "--", "true"])
    assert json_proc.returncode == 143
    assert json.loads(json_proc.stdout)["data"]["exit_code"] == 143


@posix_only
def test_ctrl_c_reaches_the_child_and_is_not_turned_into_sigkill(fake, monkeypatch, tmp_path):
    monkeypatch.setenv("FAKE_MODE", "trap")

    def child_ready() -> bool:
        return any(e.get("event") == "ready" for e in fake())

    rc, out = _run_in_pty(_acq("--backend", "msb", "exec", "box", "--", "agent"), interrupt_when=child_ready)
    events = [e.get("event") for e in fake()]
    # The child handled SIGINT itself, finished its cleanup and chose its status.
    assert "cleaned-up" in events, out
    assert rc == 7, out
    assert b"Traceback" not in out


@posix_only
def test_run_foreground_maps_signals_and_restores_sigint():
    before = signal.getsignal(signal.SIGINT)
    killed = [sys.executable, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"]
    assert hostexec.run_foreground(killed) == 143
    # The child interrupts acq (its parent) while it runs: acq keeps waiting and
    # returns the child's own status instead of raising KeyboardInterrupt.
    interrupts_parent = [
        sys.executable,
        "-c",
        "import os, signal, time; os.kill(os.getppid(), signal.SIGINT); time.sleep(0.5); raise SystemExit(5)",
    ]
    assert hostexec.run_foreground(interrupts_parent) == 5
    assert signal.getsignal(signal.SIGINT) is before


def test_exit_status_maps_negative_return_codes():
    assert hostexec.exit_status(-15) == 143
    assert hostexec.exit_status(-2) == 130
    assert hostexec.exit_status(0) == 0
    assert hostexec.exit_status(42) == 42


def test_run_foreground_leaves_an_ignored_sigint_alone(monkeypatch):
    seen = []
    monkeypatch.setattr(signal, "getsignal", lambda _sig: signal.SIG_IGN)
    monkeypatch.setattr(signal, "signal", lambda *a: seen.append(a))
    assert hostexec.run_foreground([sys.executable, "-c", "pass"]) == 0
    assert seen == []


@posix_only
def test_exec_never_gets_a_pty_even_with_a_terminal(fake, monkeypatch):
    monkeypatch.setenv("TERM", "xterm-256color")
    _record("msb")
    rc, out = _run_in_pty(_acq("--backend", "msb", "exec", "box", "--", "make"))
    assert rc == 0, out
    [session] = _sessions(fake())
    argv = session["argv"]
    assert "-t" not in argv[: argv.index("box")]
    assert "TERM" not in _env_flags(argv)
    assert session["tty"] is True  # stdin was a terminal; exec still gets no PTY


@posix_only
def test_ctrl_c_in_a_shell_loop_stops_the_loop(fake, monkeypatch):
    # The child dies of SIGINT, so acq must die of SIGINT too: a calling shell
    # that also got the interrupt then stops its loop. An ordinary exit 130
    # tells the shell the child handled it, and the loop would carry on.
    bash = hostexec.which("bash")
    if bash is None:
        pytest.skip("needs bash")
    monkeypatch.setenv("FAKE_MODE", "die-on-int")
    monkeypatch.setenv("FAKE_PY", sys.executable)
    script = (
        'for i in 1 2; do "$FAKE_PY" -m acq_py --backend msb exec box -- agent; echo "after $?"; done; '
        "echo finished"
    )

    def child_ready() -> bool:
        return any(e.get("event") == "ready" for e in fake())

    rc, out = _run_in_pty([bash, "-c", script], interrupt_when=child_ready, timeout=15)
    assert b"after" not in out and b"finished" not in out, out
    assert rc == -signal.SIGINT, out
    assert b"Traceback" not in out


def test_sigint_handler_is_restored_when_the_program_cannot_start(tmp_path):
    before = signal.getsignal(signal.SIGINT)
    with pytest.raises(OSError):
        hostexec.run_foreground([str(tmp_path / "no-such-program")])
    assert signal.getsignal(signal.SIGINT) is before


@posix_only
def test_agent_shell_survives_non_utf8_passwd_entries(fake, monkeypatch, tmp_path):
    # The comment field holds a byte that is not UTF-8. The guest script keeps
    # only the shell field, so the probe still finds the real shell.
    getent_dir = tmp_path / "getent-bin"
    getent_dir.mkdir()
    entry = tmp_path / "passwd-entry"
    entry.write_bytes(b"agent:x:1000:1000:Ada \xff Lovelace:/home/agent:/bin/bash\n")
    getent = getent_dir / "getent"
    getent.write_text(f"#!/bin/sh\ncat '{entry}'\n", encoding="utf-8")
    getent.chmod(0o755)
    monkeypatch.setenv("FAKE_GETENT_DIR", str(getent_dir))
    assert msb.agent_shell("box") == "/bin/bash"
    # A guest whose output is not text at all falls back instead of crashing.
    monkeypatch.delenv("FAKE_GETENT_DIR")
    monkeypatch.setenv("FAKE_SHELL_STDOUT_HEX", b"/bin/\xffsh\n".hex())
    assert msb.agent_shell("box") == "/bin/sh"


def _stub_msb(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps({"box": "running"}))


def _main(capsys, *argv: str) -> tuple[int, dict | None, str]:
    from acq_py import cli

    rc = cli.main(list(argv))
    captured = capsys.readouterr()
    out = captured.out.strip()
    return rc, (json.loads(out.splitlines()[-1]) if out.startswith("{") else None), captured.out + captured.err


@pytest.mark.parametrize("argv", [["--backend"], ["--json", "--backend"], ["--json", "ls", "--backend"]])
def test_backend_flag_without_a_value_is_a_usage_error(capsys, argv):
    rc, doc, output = _main(capsys, *argv)
    assert rc == 2
    assert "--backend requires a value" in output
    if "--json" in argv:
        assert doc is not None and doc["error"]["code"] == "usage"


@pytest.mark.parametrize(
    "flags",
    [["--json"], ["--backend", "sbx"], ["--json", "--backend", "msb"], ["--backend"], ["--json", "--backend"]],
)
def test_acq_flags_between_exec_name_and_separator_are_refused(monkeypatch, tmp_path, capfd, flags):
    _stub_msb(monkeypatch, tmp_path)
    rc, doc, output = _main(capfd, "--backend", "msb", "exec", "box", *flags, "--", "echo", "hi")
    assert rc == 2
    assert "[stub exec]" not in output  # nothing reached the guest
    assert "before the verb" in output
    if "--json" in flags:  # the misplaced --json still shapes the error
        assert doc is not None and doc["command"] == "exec" and doc["error"]["code"] == "usage"


def test_guest_command_flags_before_separator_still_pass_through(monkeypatch, tmp_path, capfd):
    # Only a run of acq flags is refused: once the command has started, a later
    # --json belongs to it. (capfd: the backend child writes to fd 1 directly.)
    _stub_msb(monkeypatch, tmp_path)
    rc, doc, output = _main(capfd, "--backend", "msb", "exec", "box", "grep", "--json", "--", "x")
    assert rc == 0
    assert doc is None
    assert "[stub exec] grep --json -- x" in output


@posix_only
def test_sigint_aimed_only_at_the_child_gives_130_with_the_envelope(fake, monkeypatch):
    # acq itself was not interrupted, so it must not die of SIGINT: it reports
    # the child's 130 and, under --json, still prints its one envelope.
    monkeypatch.setenv("FAKE_MODE", "die-on-int")
    acq = subprocess.Popen(
        _acq("--backend", "msb", "--json", "exec", "box", "--", "agent"),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        deadline = time.monotonic() + 15
        ready = []
        while not ready and time.monotonic() < deadline:
            ready = [e for e in fake() if e.get("event") == "ready"]
            time.sleep(0.05)
        assert ready, "the backend child never started"
        os.kill(ready[0]["pid"], signal.SIGINT)
        out, err = acq.communicate(timeout=15)
    finally:
        if acq.poll() is None:
            acq.kill()
    assert acq.returncode == 130, err
    assert json.loads(out)["data"]["exit_code"] == 130
