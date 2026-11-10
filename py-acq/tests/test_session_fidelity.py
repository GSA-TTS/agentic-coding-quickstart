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
import threading
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
    if mode == "trap-term":
        def on_end(signum, _frame):
            time.sleep(0.5)  # a short cleanup: acq must still be waiting when it finishes
            record(event="ended", signum=signum)
            sys.exit(9)

        signal.signal(signal.SIGTERM, on_end)
        signal.signal(signal.SIGHUP, on_end)
        record(event="ready", pid=os.getpid())
        time.sleep(20)
        record(event="timed-out")
        sys.exit(3)
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


def _is_git_config_exec(entry: dict) -> bool:
    return any("git config --global" in token for token in entry["argv"])


def _sessions(entries: list[dict]) -> list[dict]:
    """The logged session execs (the version/list/passwd probes are not logged).

    The msb guest git-config write is an exec too; it is not a session.
    """
    return [e for e in entries if "event" not in e and not _is_git_config_exec(e)]


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


@pytest.mark.skipif(hostexec.which("git") is None, reason="needs git on the host")
def test_global_git_config_read_ignores_inherited_repo_redirects(fake, monkeypatch, tmp_path):
    # An inherited GIT_CONFIG makes `git config --global` fail ("only one config
    # file at a time"); the read clears it and the other repository redirects,
    # but keeps the variables that locate the user's own global file.
    home = Path(os.environ["HOME"])
    (home / ".gitconfig").write_text("[user]\n\temail = grace@example.gov\n", encoding="utf-8")
    other = tmp_path / "other.gitconfig"
    other.write_text("[user]\n\temail = mallory@example.gov\n", encoding="utf-8")
    monkeypatch.delenv("GIT_CONFIG_GLOBAL", raising=False)
    monkeypatch.delenv("EMAIL", raising=False)
    monkeypatch.setenv("GIT_CONFIG", str(other))
    monkeypatch.setenv("GIT_DIR", str(tmp_path / "missing" / ".git"))
    from acq_py.commands import session

    assert session._host_git_config("user.email") == "grace@example.gov"
    assert "EMAIL=grace@example.gov" in session.host_git_identity_env()
    # GIT_CONFIG_GLOBAL still names the global file.
    named = tmp_path / "named.gitconfig"
    named.write_text("[user]\n\temail = named@example.gov\n", encoding="utf-8")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(named))
    assert session._host_git_config("user.email") == "named@example.gov"


def test_keep_command_scope_env_drops_only_repo_redirects(monkeypatch):
    from acq_py import gitrepos

    for name, value in (("GIT_CONFIG", "/x"), ("GIT_DIR", "/y"), ("GIT_CONFIG_COUNT", "1"),
                        ("GIT_CONFIG_KEY_0", "a.b"), ("GIT_CONFIG_VALUE_0", "c"),
                        ("GIT_CONFIG_PARAMETERS", "'a.b'='c'"), ("GIT_CONFIG_GLOBAL", "/g"),
                        ("GIT_CONFIG_NOSYSTEM", "1"), ("XDG_CONFIG_HOME", "/xdg")):
        monkeypatch.setenv(name, value)
    env = gitrepos.git_env(keep_command_scope=True)
    assert "GIT_CONFIG" not in env and "GIT_DIR" not in env
    for kept in ("GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_PARAMETERS",
                 "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "XDG_CONFIG_HOME", "HOME"):
        assert kept in env


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


def _persist_kit_env(lines: list[str]) -> None:
    """Write the msb ``kit-env`` host-config key, as applying the kits does."""
    from acq_py import security

    directory = security.host_config_dir("box")
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "kit-env").write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")


def _env_pairs(argv: list[str]) -> list[str]:
    """The ``-e`` values before the sandbox name, in argv order."""
    head = argv[: argv.index("--")]
    return [head[i + 1] for i, token in enumerate(head[:-1]) if token == "-e"]


@posix_only
@pytest.mark.parametrize("verb", [["exec", "box", "--", "true"], ["attach", "box"], ["shell", "box"]])
def test_msb_session_replays_the_persisted_kit_env(fake, monkeypatch, verb):
    # Bash _acq_msb_kit_env_flags_into: the last value wins, the first occurrence
    # fixes the order, a malformed name is dropped, and the kit env follows
    # acq's own entries.
    monkeypatch.setenv("EMAIL", "ada@example.gov")
    _record("msb")
    _persist_kit_env(["OPENCODE_CONFIG=/a.json", "BAD-NAME=x", "XDG_X=1", "OPENCODE_CONFIG=/b.json"])
    proc = _run_no_tty(["--backend", "msb", *verb])
    assert proc.returncode == 0, proc.stderr
    [session] = _sessions(fake())
    pairs = _env_pairs(session["argv"])
    assert pairs[-2:] == ["OPENCODE_CONFIG=/b.json", "XDG_X=1"]
    assert not any(p.startswith("BAD-NAME") for p in pairs)
    assert "EMAIL=ada@example.gov" in pairs
    assert "HOME=/home/agent" in pairs


def test_run_session_env_carries_the_msb_kit_env_only(fake, monkeypatch):
    # `acq run` re-attach builds its session through session_env_for. sbx
    # applies a kit's environment itself, so nothing is replayed there.
    from acq_py.commands import session

    _record("msb")
    _record("sbx")
    _persist_kit_env(["OPENCODE_CONFIG=/a.json"])
    assert session.session_env_for("msb", "box")[-1] == "OPENCODE_CONFIG=/a.json"
    assert "OPENCODE_CONFIG=/a.json" not in session.session_env_for("sbx", "box")


@posix_only
@pytest.mark.skipif(hostexec.which("git") is None, reason="needs git on the host")
@pytest.mark.parametrize("backend", ["msb", "sbx"])
@pytest.mark.parametrize("verb", [["exec", "box", "--", "true"], ["shell", "box"]])
def test_msb_session_writes_the_host_git_config_into_the_guest(fake, monkeypatch, backend, verb):
    home = Path(os.environ["HOME"])
    (home / ".gitconfig").write_text("[user]\n\tname = Ada Lovelace\n\temail = ada@example.gov\n", encoding="utf-8")
    monkeypatch.delenv("GIT_CONFIG_GLOBAL", raising=False)
    _record(backend)
    assert _run_no_tty(["--backend", backend, *verb]).returncode == 0
    execs = [e for e in fake() if "event" not in e]
    if backend == "sbx":
        # The sbx git identity kit sets the config; no extra exec.
        assert not any(_is_git_config_exec(e) for e in execs)
        return
    config, session_exec = execs
    assert _is_git_config_exec(config) and not _is_git_config_exec(session_exec)
    argv = config["argv"]
    assert argv[:3] == ["exec", "-u", "agent"]
    assert _env_flags(argv) == {
        "HOME": "/home/agent",
        "ACQ_GIT_USER_NAME": "Ada Lovelace",
        "ACQ_GIT_USER_EMAIL": "ada@example.gov",
    }
    command = argv[argv.index("--") + 1 :]
    assert command[:2] == ["sh", "-c"]
    assert "Ada" not in command[2]  # values travel as variables, never in the script


@pytest.mark.skipif(hostexec.which("git") is None, reason="needs git on the host")
@pytest.mark.parametrize("name", ["Łukasz Nowak", "José García"])
def test_host_git_config_is_read_as_utf8_on_an_ansi_code_page(fake, monkeypatch, name):
    # git prints its config as UTF-8. Read through cp1252, "Łukasz" (C5 81)
    # fails to decode, a traceback in every msb session, and "José" turns
    # into "JosÃ©".
    import locale

    from acq_py import kit_sbx
    from acq_py.commands import session

    home = Path(os.environ["HOME"])
    (home / ".gitconfig").write_text(f"[user]\n\tname = {name}\n\temail = l@example.gov\n", encoding="utf-8")
    monkeypatch.delenv("GIT_CONFIG_GLOBAL", raising=False)
    monkeypatch.delenv("EMAIL", raising=False)
    monkeypatch.setattr(locale, "getencoding", lambda: "cp1252")
    monkeypatch.setattr(locale, "getpreferredencoding", lambda do_setlocale=True: "cp1252")
    assert session._host_git_config("user.name") == name
    assert kit_sbx.git_global_config_env()[0] == f"ACQ_GIT_USER_NAME={name}"


def test_guest_git_config_is_best_effort(monkeypatch):
    calls = []

    def failing_run(argv, **_kwargs):
        calls.append(argv)
        raise msb.MsbError("failure", "boom")

    monkeypatch.setattr(msb, "_run", failing_run)
    msb.apply_git_global_config("box", [])
    assert calls == []  # nothing to write: no guest exec
    msb.apply_git_global_config("box", ["ACQ_GIT_USER_NAME=Ada"])
    assert len(calls) == 1  # the failure is swallowed


def test_windows_nul_stdin_gets_no_pty(monkeypatch):
    # `acq attach box < NUL` on Windows: isatty() is true for the NUL device but
    # there is no console, so neither -t nor -it may be passed (msb or sbx would
    # wait on a terminal that is not there). With a real console both are.
    monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
    monkeypatch.setattr(hostexec.os, "isatty", lambda _fd: True)
    seen: list[list[str]] = []
    monkeypatch.setattr(msb, "_run_stream", lambda argv, json_mode: seen.append(argv) or 0)
    monkeypatch.setattr(sbx, "_run_stream", lambda argv, json_mode: seen.append(argv) or 0)
    monkeypatch.setattr(msb, "agent_shell", lambda _name: "/bin/sh")
    for console in (False, True):
        monkeypatch.setattr(hostexec, "_windows_console", lambda _fd, c=console: c)
        msb.launch("box", None, "opencode")
        sbx.launch("box", None, "opencode")
    no_console_msb, no_console_sbx, console_msb, console_sbx = (argv[:2] for argv in seen)
    assert no_console_msb == ["exec", "-u"]
    assert no_console_sbx == ["exec", "-e"]
    assert console_msb == ["exec", "-t"]
    assert console_sbx == ["exec", "-it"]


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


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


@posix_only
@pytest.mark.parametrize("name", ["SIGTERM", "SIGHUP"])
def test_a_signal_for_acq_alone_ends_the_session_child_before_acq_exits(fake, monkeypatch, name):
    # kill <acq pid> during a session: acq passes the signal on, waits for the
    # child, then exits 128+N; the child no longer runs or holds the terminal.
    sig = getattr(signal, name)
    monkeypatch.setenv("FAKE_MODE", "trap-term")
    _record("msb")
    proc = subprocess.Popen(_acq("--backend", "msb", "--json", "exec", "box", "--", "agent"),
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 20
        while not any(e.get("event") == "ready" for e in fake()) and time.monotonic() < deadline:
            time.sleep(0.05)
        [ready] = [e for e in fake() if e.get("event") == "ready"]
        proc.send_signal(sig)
        out, err = proc.communicate(timeout=30)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    assert proc.returncode == 128 + sig, err
    assert [e["signum"] for e in fake() if e.get("event") == "ended"] == [sig]
    assert not _pid_alive(ready["pid"])
    assert out == "" and "Traceback" not in err


@posix_only
def test_a_child_that_ignores_the_signal_is_killed_after_the_grace_period(monkeypatch, tmp_path):
    monkeypatch.setattr(hostexec, "_SESSION_SIGNAL_GRACE_S", 0.5)
    ready = tmp_path / "ready"
    child = [sys.executable, "-c",
             "import os, signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
             f"open({str(ready)!r}, 'w').write(str(os.getpid())); time.sleep(30)"]

    class Ended(BaseException):
        pass

    def acq_handler(signum, _frame):  # stands in for cli's own SIGTERM handler
        raise Ended(signum)

    def signal_acq():
        deadline = time.monotonic() + 20
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        time.sleep(0.1)
        os.kill(os.getpid(), signal.SIGTERM)

    previous = signal.signal(signal.SIGTERM, acq_handler)
    started = time.monotonic()
    try:
        threading.Thread(target=signal_acq, daemon=True).start()
        with pytest.raises(Ended) as caught:
            hostexec.run_foreground(child)
        assert signal.getsignal(signal.SIGTERM) is acq_handler  # restored before it ran
    finally:
        signal.signal(signal.SIGTERM, previous)
    assert caught.value.args == (signal.SIGTERM,)
    assert time.monotonic() - started < 15
    assert not _pid_alive(int(ready.read_text()))


def test_run_foreground_returns_128_plus_n_when_the_prior_handler_returns(monkeypatch, tmp_path):
    # A handler that does not raise leaves acq running: the session still ends
    # with the shell's status for the signal. Runs on Windows too, with the
    # signal raised from another thread as a console Ctrl-Break would be.
    monkeypatch.setattr(hostexec, "_SESSION_SIGNAL_GRACE_S", 0.5)
    signum = signal.SIGBREAK if sys.platform == "win32" else signal.SIGTERM  # type: ignore[attr-defined,unused-ignore]
    ready = tmp_path / "ready"
    child = [sys.executable, "-c",
             "import signal, sys, time\n"
             "for name in ('SIGTERM', 'SIGBREAK'):\n"
             "    if hasattr(signal, name): signal.signal(getattr(signal, name), signal.SIG_IGN)\n"
             f"open({str(ready)!r}, 'w').close(); time.sleep(30)"]
    seen: list[int] = []

    def raise_later():
        deadline = time.monotonic() + 20
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        time.sleep(0.1)
        if sys.platform == "win32":
            signal.raise_signal(signum)  # handled by the main thread at its next poll
        else:
            os.kill(os.getpid(), signum)  # process-directed, so it interrupts the main thread's wait

    previous = signal.signal(signum, lambda n, _f: seen.append(n))
    started = time.monotonic()
    try:
        threading.Thread(target=raise_later, daemon=True).start()
        assert hostexec.run_foreground(child) == 128 + signum
    finally:
        signal.signal(signum, previous)
    assert seen == [signum]
    assert time.monotonic() - started < 15  # the child was killed, not waited out


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
