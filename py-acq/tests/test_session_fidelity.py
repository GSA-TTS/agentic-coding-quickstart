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
    print("agent:x:1000:1000::/home/agent:/bin/bash")
elif args[:1] == ["exec"]:
    record(tty=os.isatty(0))
    mode = os.environ.get("FAKE_MODE", "")
    if mode == "sigterm":
        os.kill(os.getpid(), signal.SIGTERM)
        time.sleep(5)
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
    for var in ("TERM", "COLORTERM", "EMAIL", "SSH_AUTH_SOCK", "FAKE_MODE"):
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


def _run_in_pty(argv: list[str], *, interrupt_when=None, timeout: float = 30.0) -> tuple[int, bytes]:
    """Run ``python -m acq_py ARGV`` with a PTY as its controlling terminal.

    ``interrupt_when`` is polled while the child runs; once it returns true,
    Ctrl-C is typed on the terminal, so the line discipline sends SIGINT to the
    foreground process group (acq and its backend child), as a real one does.
    """
    import pty  # POSIX only; imported here so the module still collects on Windows

    pid, fd = pty.fork()
    if pid == 0:  # child: become acq
        try:
            os.execv(sys.executable, [sys.executable, "-m", "acq_py", *argv])
        finally:
            os._exit(127)
    output = b""
    interrupted = False
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            if interrupt_when is not None and not interrupted and interrupt_when():
                os.write(fd, b"\x03")
                interrupted = True
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:  # EIO: the child closed the terminal
                    break
                if not chunk:
                    break
                output += chunk
        else:
            os.kill(pid, signal.SIGKILL)
    finally:
        _, status = os.waitpid(pid, 0)
        os.close(fd)
    return os.waitstatus_to_exitcode(status), output


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
    rc, out = _run_in_pty(["--backend", "msb", "shell", "box"])
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
    rc, out = _run_in_pty(["--backend", "sbx", "attach", "box"])
    assert rc == 0, out
    [session] = _sessions(fake())
    argv = session["argv"]
    assert argv[:2] == ["exec", "-it"]
    assert session["tty"] is True
    env = _env_flags(argv)
    assert env["TERM"] == "xterm-256color"
    assert env["HOME"] == "/home/agent"
    assert env["SHELL"] == "/bin/sh"
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
    assert second["argv"][second["argv"].index("--") + 1 :] == ["/bin/sh", "-l"]


def test_agent_shell_falls_back_on_an_unexpected_passwd_entry(monkeypatch):
    def fake_run(_argv, **_kwargs):
        return subprocess.CompletedProcess([], 0, stdout="agent:x:1000:1000::/home/agent:/bin/ba sh\n", stderr="")

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

    rc, out = _run_in_pty(["--backend", "msb", "exec", "box", "--", "agent"], interrupt_when=child_ready)
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
