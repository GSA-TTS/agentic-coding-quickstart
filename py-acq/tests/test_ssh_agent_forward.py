"""Tier-2 tests for the host ssh-agent forward into an msb guest (ADR-0021).

The Python port of ``test/bats/115-ssh-agent-forward.bats``: the neutral
forward emitter, the msb ``--vsock`` route and its managed link, the in-guest
socat bridge, the liveness probe, the re-attach re-drive, the session
``SSH_AUTH_SOCK`` and teardown, driven through the deterministic ``__stub__``
msb with the exact ``msb`` argv checked. Where the Bash adapter can produce the
same artifact (the guest argv, the link path, the emitted routes and warnings)
the two are compared directly.

Real AF_UNIX sockets are bound (never listened on) under ``tmp_path``. The
temporary directory is usually too long for a socket address, so each one is
bound by a relative name from inside its directory; the link-path budget
(:data:`ssh_agent.SUN_PATH_MAX`) is widened where a test is about the link
rather than the budget.
"""

from __future__ import annotations

import json
import os
import stat
import shutil
import socket
import subprocess
from pathlib import Path

import pytest

from acq_py import cli, kit_msb, msb, security, ssh_agent, state

pytestmark = pytest.mark.provider_key  # creates msb sandboxes: needs a stored provider key

REPO_ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")
GUEST_SOCK = ssh_agent.DEFAULT_GUEST_SOCK

needs_unix_sockets = pytest.mark.skipif(not hasattr(socket, "AF_UNIX") or os.name == "nt",
                                        reason="needs AF_UNIX sockets")
needs_bash = pytest.mark.skipif(BASH is None or os.name == "nt" or shutil.which("realpath") is None,
                                reason="the Bash parity check needs bash and realpath")



def _target(link) -> str:
    """The link's target, without the ``\\\\?\\`` prefix Windows' readlink adds."""
    target = os.readlink(link)
    return target[4:] if target.startswith("\\\\?\\") else target

def _sock(path: Path) -> str:
    """Bind (and close) a unix socket at ``path``; the socket file stays."""
    here = os.getcwd()
    os.chdir(path.parent)
    try:
        s = socket.socket(socket.AF_UNIX)
        try:
            s.bind(path.name)
        finally:
            s.close()
    finally:
        os.chdir(here)
    return str(path)


def _env(monkeypatch, tmp_path, *, version="0.7.7", catalog=None):
    monkeypatch.setattr(security, "WINDOWS", False)
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", version)
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_MSB_RO_INSPECT_RETRY_SLEEP", "0")
    if catalog is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps(catalog))
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    return ws


@pytest.fixture
def roomy(monkeypatch):
    """Widen the link-path budget: these tests are about the link, not the temp dir's length."""
    monkeypatch.setattr(ssh_agent, "SUN_PATH_MAX", 4096)


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    captured = capsys.readouterr()
    out = captured.out.strip()
    return rc, (json.loads(out.splitlines()[-1]) if out else None), captured.err


def _spy(monkeypatch) -> list[list[str]]:
    seen: list[list[str]] = []
    real = msb._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(msb, "_run", spy)
    return seen


def _bridges(seen) -> list[list[str]]:
    return [a for a in seen if a[0] == "exec" and a[-1].lstrip().startswith("mkdir -p") and "socat" in a[-1]]


def _create_argv(seen):
    (argv,) = [a for a in seen if a[0] == "create"]
    return argv


def _vsock(argv) -> list[str]:
    return [argv[i + 1] for i, a in enumerate(argv) if a == "--vsock"]


def _link(tmp_path, name) -> Path:
    return tmp_path / "state" / "msb" / "ssh-agent" / f"{name}.sock"


def _recorded(name):
    path = security.host_config_dir(name) / "ssh-auth-sock"
    return path.read_text(encoding="utf-8") if path.exists() else None


def _seed_recorded(name, value=GUEST_SOCK):
    kit_msb.hc_write(name, "ssh-auth-sock", value)


# ---------------------------------------------------------------------------
# The neutral emitter (common.sh acq_host_socket_forwards).
# ---------------------------------------------------------------------------


def test_no_forward_without_ssh_auth_sock_or_host_sockets(capsys):
    assert ssh_agent.host_socket_forwards() == []
    assert capsys.readouterr().err == ""


@needs_unix_sockets
def test_a_real_agent_socket_is_forwarded_on_the_default_port(tmp_path, monkeypatch):
    agent = _sock(tmp_path / "agent.sock")
    monkeypatch.setenv("SSH_AUTH_SOCK", agent)
    assert ssh_agent.host_socket_forwards() == [ssh_agent.Forward(os.path.realpath(agent), "3552", "stream", "ssh-agent")]


@needs_unix_sockets
def test_a_symlinked_agent_socket_is_forwarded_by_its_real_path(tmp_path, monkeypatch):
    agent = _sock(tmp_path / "agent.sock")
    (tmp_path / "alias.sock").symlink_to(agent)
    monkeypatch.setenv("SSH_AUTH_SOCK", str(tmp_path / "alias.sock"))
    (fwd,) = ssh_agent.host_socket_forwards()
    assert fwd.path == os.path.realpath(agent) and "alias" not in fwd.path


@pytest.mark.parametrize("make", ["file", "missing", "dir"])
def test_an_agent_path_that_is_not_a_socket_is_skipped_with_the_bash_warning(tmp_path, monkeypatch, capsys, make):
    path = tmp_path / "not-a-socket"
    if make == "file":
        path.write_text("x", encoding="utf-8")
    elif make == "dir":
        path.mkdir()
    monkeypatch.setenv("SSH_AUTH_SOCK", str(path))
    assert ssh_agent.host_socket_forwards() == []
    assert capsys.readouterr().err == "acq: SSH_AUTH_SOCK is set but not a socket; skipping ssh-agent forwarding\n"


@needs_unix_sockets
def test_nothing_is_forwarded_from_a_windows_host(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    monkeypatch.setenv("ACQ_FORWARD_HOST_SOCKETS", f"{tmp_path / 'agent.sock'}:6000")
    monkeypatch.setattr(ssh_agent, "WINDOWS", True)
    assert ssh_agent.host_socket_forwards() == []
    err = capsys.readouterr().err
    assert "acq: SSH_AUTH_SOCK is set but not a socket; skipping ssh-agent forwarding" in err
    assert "is not an existing socket; skipping" in err


@needs_unix_sockets
@pytest.mark.parametrize("port", ["123", "0", "4294967295", "abc", "", "35٥"])
def test_an_invalid_agent_port_override_is_refused(tmp_path, monkeypatch, capsys, port):
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    monkeypatch.setenv("ACQ_SSH_AGENT_VSOCK_PORT", port)
    forwards = ssh_agent.host_socket_forwards()
    if port == "":  # an empty override is unset: the default applies
        assert [f.port for f in forwards] == ["3552"]
        return
    assert forwards == []
    assert capsys.readouterr().err == (f"acq: ACQ_SSH_AGENT_VSOCK_PORT {port} is invalid (need 1..4294967294, "
                                       "!= 123); skipping ssh-agent forwarding\n")


@needs_unix_sockets
def test_a_valid_agent_port_override_is_honored_by_route_and_bridge(tmp_path, monkeypatch):
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    monkeypatch.setenv("ACQ_SSH_AGENT_VSOCK_PORT", "9000")
    assert [f.port for f in ssh_agent.host_socket_forwards()] == ["9000"]
    assert ssh_agent.bridge_port() == "9000"
    monkeypatch.delenv("ACQ_SSH_AGENT_VSOCK_PORT")
    monkeypatch.setenv("ACQ_MSB_SSH_AGENT_VSOCK_PORT", "9001")
    assert (ssh_agent.route_port(), ssh_agent.bridge_port()) == ("9001", "9001")


@needs_unix_sockets
def test_an_agent_path_with_a_newline_is_refused(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "a\nb.sock"))
    assert ssh_agent.host_socket_forwards() == []
    assert capsys.readouterr().err == "acq: SSH_AUTH_SOCK path contains a tab/newline; skipping ssh-agent forwarding\n"


def test_a_vsock_port_is_valid_only_in_range_and_not_reserved():
    table = {"0": False, "1": True, "123": False, "3552": True, "4294967294": True, "4294967295": False,
             "abc": False, "-1": False, "03552": True, "٣٥٥٢": False}
    assert {p: ssh_agent.valid_vsock_port(p) for p in table} == table


@needs_unix_sockets
def test_a_host_socket_entry_emits_its_port_and_kind(tmp_path, monkeypatch):
    custom = _sock(tmp_path / "custom.sock")
    monkeypatch.setenv("ACQ_FORWARD_HOST_SOCKETS", f"{custom}:6000/stream,{custom}:6001/dgram,,{custom}:6002")
    assert [(f.port, f.kind, f.label) for f in ssh_agent.host_socket_forwards()] == [
        ("6000", "stream", "custom"), ("6001", "dgram", "custom"), ("6002", "stream", "custom")]


@needs_unix_sockets
def test_invalid_host_socket_entries_are_skipped_with_the_bash_warnings(tmp_path, monkeypatch, capsys):
    real = _sock(tmp_path / "real.sock")
    cases = {
        "rel.sock:6000": "acq: host-socket path rel.sock is not absolute; skipping",
        f"{real}:123": "acq: host-socket port 123 is invalid (need 1..4294967294, != 123); skipping",
        "/nonexistent/x.sock:6000": "acq: host-socket path /nonexistent/x.sock is not an existing socket; skipping",
        f"{real}": f"acq: malformed host-socket forward {real} (expected PATH:PORT); skipping",
    }
    for entry, warning in cases.items():
        monkeypatch.setenv("ACQ_FORWARD_HOST_SOCKETS", entry)
        assert ssh_agent.host_socket_forwards() == [], entry
        assert capsys.readouterr().err == warning + "\n"


def test_quiet_suppresses_the_emitter_warnings(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("SSH_AUTH_SOCK", str(tmp_path / "missing"))
    assert ssh_agent.host_socket_forwards(quiet=True) == []
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize("value,want,warning", [
    ("/home/agent/.acq/custom-agent.sock", "/home/agent/.acq/custom-agent.sock", ""),
    ("relative/agent.sock", GUEST_SOCK, "non-absolute"),
    ("/x'; touch /tmp/PWNED; :'", GUEST_SOCK, "unsafe"),
])
def test_a_guest_socket_override_must_be_absolute_and_word_safe(monkeypatch, capsys, value, want, warning):
    monkeypatch.setenv("ACQ_MSB_SSH_AGENT_GUEST_SOCK", value)
    assert ssh_agent.guest_sock() == want
    assert ssh_agent.guest_sock() == want  # warned once per process
    err = capsys.readouterr().err
    if warning:
        assert err == f"acq(msb): warning: ignoring {warning} ACQ_MSB_SSH_AGENT_GUEST_SOCK='{value}'; using default.\n"
    else:
        assert err == ""


# ---------------------------------------------------------------------------
# The create-time route and its managed link.
# ---------------------------------------------------------------------------


@needs_unix_sockets
def test_the_route_names_the_managed_link_and_the_link_resolves_to_the_agent(tmp_path, monkeypatch, capsys, roomy):
    _env(monkeypatch, tmp_path)
    agent = _sock(tmp_path / "agent.sock")
    monkeypatch.setenv("SSH_AUTH_SOCK", agent)
    flags = ssh_agent.vsock_flags("linkbox", [])
    link = _link(tmp_path, "linkbox")
    assert flags == ["--vsock", f"{link}:3552/stream"]
    assert _target(link) == os.path.realpath(agent)
    assert ssh_agent.forwarding_sock("linkbox") == GUEST_SOCK
    err = capsys.readouterr().err
    assert "forwarding your host ssh-agent into the guest" in err
    assert "unset SSH_AUTH_SOCK to opt out" in err and "ssh-add -c" in err
    # The notice prints once per process.
    ssh_agent.vsock_flags("linkbox2", [])
    assert "forwarding your host ssh-agent" not in capsys.readouterr().err


def test_no_route_and_no_forwarding_without_a_request(tmp_path, monkeypatch, capsys):
    _env(monkeypatch, tmp_path)
    assert ssh_agent.vsock_flags("box", []) == []
    assert ssh_agent.forwarding_sock("box") is None
    assert capsys.readouterr().err == ""


@needs_unix_sockets
@pytest.mark.parametrize("version", ["0.6.8", "garbage"])
def test_an_msb_without_vsock_warns_and_emits_nothing(tmp_path, monkeypatch, capsys, version):
    _env(monkeypatch, tmp_path, version=version)
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    assert ssh_agent.vsock_flags("box", []) == []
    assert ssh_agent.forwarding_sock("box") is None
    found = "0.6.8" if version == "0.6.8" else "unknown"
    assert f"host ssh-agent/socket forwarding needs msb >= 0.6.9 (found {found}); skipping" in capsys.readouterr().err


@needs_unix_sockets
def test_a_host_socket_forward_keeps_its_canonical_path_and_gets_no_link(tmp_path, monkeypatch, roomy):
    _env(monkeypatch, tmp_path)
    custom = _sock(tmp_path / "custom.sock")
    (tmp_path / "custom.link").symlink_to(custom)
    monkeypatch.setenv("ACQ_FORWARD_HOST_SOCKETS", f"{tmp_path / 'custom.link'}:6000/stream")
    assert ssh_agent.vsock_flags("custombox", []) == ["--vsock", f"{os.path.realpath(custom)}:6000/stream"]
    assert not os.path.lexists(_link(tmp_path, "custombox"))
    assert ssh_agent.forwarding_sock("custombox") is None  # a custom forward starts no agent bridge


@needs_unix_sockets
def test_a_link_path_that_would_overflow_falls_back_to_the_hashed_name(tmp_path, monkeypatch):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    name = "a-rather-long-sandbox-name-for-the-sun-path-overflow-case-x"
    hashed = f"{tmp_path / 'state'}/msb/ssh-agent/h{_cksum(name)}.sock"
    monkeypatch.setattr(ssh_agent, "SUN_PATH_MAX", len(hashed))
    assert ssh_agent.link_path(name) == hashed
    flags = ssh_agent.vsock_flags(name, [])
    assert flags == ["--vsock", f"{hashed}:3552/stream"] and os.path.islink(hashed)
    monkeypatch.setattr(ssh_agent, "SUN_PATH_MAX", len(hashed) - 1)
    assert ssh_agent.link_path(name) is None


def _cksum(text: str) -> str:
    if shutil.which("cksum") is None:
        from acq_py import lock

        return str(lock.posix_cksum(text.encode("utf-8")))
    out = subprocess.run(["cksum"], input=text.encode("utf-8"), capture_output=True, check=True).stdout
    return out.decode("ascii").split()[0]


@needs_unix_sockets
@pytest.mark.parametrize("name", ["../escape", "my.app", "-lead", ""])
def test_an_unsafe_name_never_becomes_a_link_and_the_raw_route_is_announced(tmp_path, monkeypatch, capsys, roomy, name):
    _env(monkeypatch, tmp_path)
    agent = _sock(tmp_path / "agent.sock")
    monkeypatch.setenv("SSH_AUTH_SOCK", agent)
    assert ssh_agent.vsock_flags(name, []) == ["--vsock", f"{os.path.realpath(agent)}:3552/stream"]
    err = capsys.readouterr().err
    assert f"cannot manage the ssh-agent route for sandbox '{name}'" in err
    assert "letters, digits, '_' and '-'" in err
    link_dir = tmp_path / "state" / "msb" / "ssh-agent"
    assert not link_dir.exists() or not any(link_dir.iterdir())


@needs_unix_sockets
def test_a_link_that_cannot_be_created_names_the_link_not_the_name(tmp_path, monkeypatch, capsys, roomy):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    # The link directory is itself a symlink, which acq refuses to write through.
    (tmp_path / "elsewhere").mkdir()
    (tmp_path / "state" / "msb").mkdir(parents=True)
    (tmp_path / "state" / "msb" / "ssh-agent").symlink_to(tmp_path / "elsewhere")
    ssh_agent.vsock_flags("okname", [])
    err = capsys.readouterr().err
    assert "cannot manage the ssh-agent route" in err and "ssh-agent/okname.sock" in err
    assert "letters, digits" not in err


@needs_unix_sockets
def test_a_non_symlink_at_the_link_path_is_never_replaced(tmp_path, monkeypatch, roomy):
    _env(monkeypatch, tmp_path)
    agent = _sock(tmp_path / "agent.sock")
    link = _link(tmp_path, "box")
    link.parent.mkdir(parents=True)
    link.write_text("mine", encoding="utf-8")
    assert not ssh_agent.link_point(str(link), agent)
    assert link.read_text(encoding="utf-8") == "mine"
    assert not ssh_agent.link_point(str(tmp_path / "other.sock"), str(tmp_path / "not-a-socket"))


# ---------------------------------------------------------------------------
# The bridge, the recorded socket and the liveness probe.
# ---------------------------------------------------------------------------


def _bridge_argv(name, sock=GUEST_SOCK, port="3552"):
    return ["exec", name, "-u", "agent", "--", "sh", "-c", ssh_agent.bridge_script(sock, port)]


def test_the_bridge_starts_socat_and_records_the_guest_socket(tmp_path, monkeypatch, capsys):
    _env(monkeypatch, tmp_path, catalog={"sbox": "running"})
    seen = _spy(monkeypatch)
    ssh_agent._ACTIVE.add("sbox")
    ssh_agent.provision_bridge("sbox")
    assert seen == [
        ["exec", "sbox", "--", "sh", "-c", "command -v socat >/dev/null 2>&1"],
        _bridge_argv("sbox"),
        ["exec", "sbox", "-u", "agent", "--", "sh", "-c", "command -v ssh-add >/dev/null 2>&1"],
        ["exec", "sbox", "-u", "agent", "--", "sh", "-c", ssh_agent.probe_script(GUEST_SOCK)],
    ]
    assert "socat UNIX-LISTEN:'/home/agent/.acq/ssh-agent.sock',fork,reuseaddr VSOCK-CONNECT:2:'3552'" in seen[1][-1]
    assert _recorded("sbox") == GUEST_SOCK
    assert capsys.readouterr().err == ""


@needs_unix_sockets
def test_the_resume_path_uses_the_recorded_socket_and_none_without_it(tmp_path, monkeypatch):
    _env(monkeypatch, tmp_path, catalog={"sbox": "running", "sbox2": "running"})
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    seen = _spy(monkeypatch)
    _seed_recorded("sbox", "/home/agent/.acq/other.sock\n")
    ssh_agent.start_bridge("sbox")
    assert _bridges(seen) == [_bridge_argv("sbox", "/home/agent/.acq/other.sock")]
    seen.clear()
    ssh_agent.start_bridge("sbox2")
    assert seen == []
    _seed_recorded("sbox2", "/x'; rm -rf ~")  # never spliced into a guest command
    ssh_agent.start_bridge("sbox2")
    assert seen == []


def test_a_guest_without_socat_warns_and_gets_no_bridge(tmp_path, monkeypatch, capsys):
    _env(monkeypatch, tmp_path, catalog={"sbox": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_NO_SOCAT", "sbox")
    seen = _spy(monkeypatch)
    ssh_agent._ACTIVE.add("sbox")
    assert ssh_agent.check_socat("sbox") is False
    assert "socat not found in the guest" in capsys.readouterr().err
    seen.clear()
    ssh_agent.provision_bridge("sbox")
    assert _bridges(seen) == [] and _recorded("sbox") is None


def test_the_bridge_connects_to_the_overridden_port(tmp_path, monkeypatch):
    _env(monkeypatch, tmp_path, catalog={"sbox": "running"})
    monkeypatch.setenv("ACQ_MSB_SSH_AGENT_VSOCK_PORT", "9000")
    seen = _spy(monkeypatch)
    ssh_agent._ACTIVE.add("sbox")
    ssh_agent.start_bridge("sbox")
    assert "VSOCK-CONNECT:2:'9000'" in _bridges(seen)[0][-1]


def test_an_invalid_bridge_port_is_never_spliced_into_the_guest(tmp_path, monkeypatch, capsys):
    _env(monkeypatch, tmp_path, catalog={"sbox": "running"})
    monkeypatch.setenv("ACQ_MSB_SSH_AGENT_VSOCK_PORT", "1'; reboot; '")
    seen = _spy(monkeypatch)
    ssh_agent._ACTIVE.add("sbox")
    ssh_agent.start_bridge("sbox")
    assert seen == [] and "the ssh-agent bridge was not started in 'sbox'" in capsys.readouterr().err


def test_a_failed_bridge_start_warns_and_records_nothing(tmp_path, monkeypatch, capsys):
    _env(monkeypatch, tmp_path, catalog={"sbox": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_EXEC_EXIT", "1")
    ssh_agent._ACTIVE.add("sbox")
    ssh_agent.start_bridge("sbox")
    assert "failed to start the ssh-agent bridge in 'sbox'" in capsys.readouterr().err
    assert _recorded("sbox") is None


@pytest.mark.parametrize("answer,warns", [("keys", False), ("empty", False), ("unreachable", True), ("nosocket", True)])
def test_the_liveness_probe_warns_only_when_the_agent_does_not_answer(tmp_path, monkeypatch, capsys, answer, warns):
    _env(monkeypatch, tmp_path, catalog={"stalebox": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_AGENT", answer)
    ssh_agent._ACTIVE.add("stalebox")
    ssh_agent.start_bridge("stalebox")  # never raises, whatever the probe says
    err = capsys.readouterr().err
    assert ("UNREACHABLE" in err) is warns
    if warns:
        assert "HOST REBOOT" in err and "'acq rm stalebox'" in err


def test_the_liveness_probe_is_skipped_without_ssh_add_in_the_guest(tmp_path, monkeypatch, capsys):
    _env(monkeypatch, tmp_path, catalog={"skipbox": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_NO_SSH_ADD", "skipbox")
    monkeypatch.setenv("ACQ_MSB_STUB_AGENT", "unreachable")
    assert ssh_agent.warn_if_unreachable("skipbox", GUEST_SOCK) is True
    assert capsys.readouterr().err == ""


@needs_unix_sockets
def test_a_bridge_restart_re_points_an_existing_link_at_the_current_agent(tmp_path, monkeypatch, roomy):
    _env(monkeypatch, tmp_path, catalog={"rebootbox": "running", "legacybox": "running"})
    old, new = _sock(tmp_path / "old.sock"), _sock(tmp_path / "new.sock")
    link = _link(tmp_path, "rebootbox")
    link.parent.mkdir(parents=True)
    link.symlink_to(old)
    monkeypatch.setenv("SSH_AUTH_SOCK", new)
    _seed_recorded("rebootbox")
    ssh_agent.start_bridge("rebootbox")
    assert _target(link) == os.path.realpath(new)
    assert sorted(p.name for p in link.parent.iterdir()) == ["rebootbox.sock"]  # no temp link left
    _seed_recorded("legacybox")
    ssh_agent.start_bridge("legacybox")
    assert not os.path.lexists(_link(tmp_path, "legacybox"))  # none invented for a raw-path route


@needs_unix_sockets
def test_a_non_socket_agent_leaves_a_link_to_the_users_socket_alone(tmp_path, monkeypatch, capsys, roomy):
    _env(monkeypatch, tmp_path, catalog={"holdbox": "running"})
    held = _sock(tmp_path / "hold.sock")
    link = _link(tmp_path, "holdbox")
    link.parent.mkdir(parents=True)
    link.symlink_to(held)
    (tmp_path / "plain").write_text("x", encoding="utf-8")
    monkeypatch.setenv("SSH_AUTH_SOCK", str(tmp_path / "plain"))
    monkeypatch.setenv("ACQ_MSB_STUB_AGENT", "unreachable")
    _seed_recorded("holdbox")
    ssh_agent.start_bridge("holdbox")
    err = capsys.readouterr().err
    assert "UNREACHABLE" in err and "NOT re-pointed" in err and "just re-pointed" not in err
    assert "names your live agent" in err
    assert _target(link) == held


@pytest.mark.parametrize("target", ["missing", "file", "symlink"])
def test_a_link_whose_target_is_not_the_users_socket_is_removed_and_no_bridge_starts(
        tmp_path, monkeypatch, capsys, roomy, target):
    _env(monkeypatch, tmp_path, catalog={"stalebox": "running"})
    link = _link(tmp_path, "stalebox")
    link.parent.mkdir(parents=True)
    dest = tmp_path / "dest"
    if target == "file":
        dest.write_text("x", encoding="utf-8")
    elif target == "symlink":
        dest.symlink_to(tmp_path / "elsewhere.sock")
    link.symlink_to(dest)
    (tmp_path / "plain").write_text("x", encoding="utf-8")
    monkeypatch.setenv("SSH_AUTH_SOCK", str(tmp_path / "plain"))
    _seed_recorded("stalebox")
    seen = _spy(monkeypatch)
    ssh_agent.start_bridge("stalebox")
    err = capsys.readouterr().err
    assert "removed the ssh-agent route link" in err and "not a socket owned by you outside the workspace" in err
    assert not os.path.lexists(link) and _bridges(seen) == []


@pytest.mark.skipif(os.name == "nt", reason="POSIX socket paths (a Windows host never forwards)")
def test_the_opt_out_says_plainly_when_the_route_names_the_raw_agent_path(tmp_path, monkeypatch, capsys, roomy):
    _env(monkeypatch, tmp_path, catalog={"rawbox": "running", "linkgone": "running"})
    _seed_recorded("rawbox")
    _inspect(monkeypatch, {"active_config": _ROUTE})  # host_socket is the raw agent path
    ssh_agent.opt_out("rawbox")
    err = capsys.readouterr().err
    assert "names the raw agent socket path, not acq's managed link" in err and "'acq rm rawbox'" in err
    assert "was disconnected" not in err and _recorded("rawbox") is None
    # A managed route whose link is already gone is disconnected, and says so.
    _seed_recorded("linkgone")
    _inspect(monkeypatch, {"active_config": {"vsock": {"routes": [
        {"host_socket": str(_link(tmp_path, "linkgone")), "port": 3552}]}}})
    ssh_agent.opt_out("linkgone")
    err = capsys.readouterr().err
    assert "the forwarded ssh-agent was disconnected from 'linkgone'" in err and "raw agent socket path" not in err


@needs_unix_sockets
def test_a_link_whose_target_sits_in_a_symlinked_directory_is_removed(tmp_path, monkeypatch, capsys, roomy):
    _env(monkeypatch, tmp_path, catalog={"dirbox": "running"})
    (tmp_path / "realdir").mkdir()
    _sock(tmp_path / "realdir" / "a.sock")
    (tmp_path / "aliasdir").symlink_to(tmp_path / "realdir")
    link = _link(tmp_path, "dirbox")
    link.parent.mkdir(parents=True)
    link.symlink_to(tmp_path / "aliasdir" / "a.sock")
    (tmp_path / "plain").write_text("x", encoding="utf-8")
    monkeypatch.setenv("SSH_AUTH_SOCK", str(tmp_path / "plain"))
    _seed_recorded("dirbox")
    seen = _spy(monkeypatch)
    ssh_agent.start_bridge("dirbox")
    assert "removed the ssh-agent route link" in capsys.readouterr().err
    assert not os.path.lexists(link) and _bridges(seen) == []


@needs_unix_sockets
def test_re_pointing_the_link_at_another_users_socket_warns_as_create_does(tmp_path, monkeypatch, capsys, roomy):
    _env(monkeypatch, tmp_path)
    link = _link(tmp_path, "ownbox")
    link.parent.mkdir(parents=True)
    link.symlink_to(_sock(tmp_path / "own.sock"))
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "theirs.sock"))
    monkeypatch.setattr(ssh_agent, "_socket_owned_by_me", lambda p: False)
    assert ssh_agent.link_refresh("ownbox") == ("", False)
    assert "SSH_AUTH_SOCK names a socket owned by another user; forwarding it anyway" in capsys.readouterr().err
    assert _target(link) == os.path.realpath(tmp_path / "theirs.sock")


@needs_unix_sockets
def test_a_link_to_another_users_socket_is_removed(tmp_path, monkeypatch, capsys, roomy):
    _env(monkeypatch, tmp_path, catalog={"stalebox": "running"})
    link = _link(tmp_path, "stalebox")
    link.parent.mkdir(parents=True)
    link.symlink_to(_sock(tmp_path / "theirs.sock"))
    (tmp_path / "plain").write_text("x", encoding="utf-8")
    monkeypatch.setenv("SSH_AUTH_SOCK", str(tmp_path / "plain"))
    real_owned = ssh_agent._owned_by_me
    # Only the socket target belongs to someone else; acq's own directories stay ours.
    monkeypatch.setattr(ssh_agent, "_owned_by_me", lambda info: False if stat.S_ISSOCK(info.st_mode) else real_owned(info))
    _seed_recorded("stalebox")
    ssh_agent.start_bridge("stalebox")
    assert "removed the ssh-agent route link" in capsys.readouterr().err
    assert not os.path.lexists(link)


@needs_unix_sockets
def test_the_unreachable_warning_matches_the_route_kind(tmp_path, monkeypatch, capsys, roomy):
    _env(monkeypatch, tmp_path, catalog={"oldbox": "running", "newbox": "running", "my.app": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_AGENT", "unreachable")
    # A raw-path route: a one-time recreate, after which start heals it.
    ssh_agent._ACTIVE.update({"oldbox", "newbox", "my.app"})
    ssh_agent.start_bridge("oldbox")
    err = capsys.readouterr().err
    assert "'acq rm oldbox'" in err and "one-time recreate" in err
    # A managed route: the link was just re-pointed, so the host agent is at fault.
    agent = _sock(tmp_path / "agent.sock")
    link = _link(tmp_path, "newbox")
    link.parent.mkdir(parents=True)
    link.symlink_to(agent)
    monkeypatch.setenv("SSH_AUTH_SOCK", agent)
    ssh_agent.start_bridge("newbox")
    err = capsys.readouterr().err
    assert "acq rm newbox" not in err and "ssh-agent/newbox.sock" in err and "just re-pointed" in err
    # A name that cannot carry a link is never promised a self-healing recreate.
    ssh_agent.start_bridge("my.app")
    err = capsys.readouterr().err
    assert "'acq rm my.app'" in err and "one-time recreate" not in err and "letters, digits, '_' and '-'" in err


@needs_unix_sockets
def test_a_link_that_cannot_be_replaced_is_reported_as_such(tmp_path, monkeypatch, capsys, roomy):
    _env(monkeypatch, tmp_path, catalog={"rofs": "running"})
    # The link directory is itself a symlink, which acq refuses to write through;
    # leave the link untouched and skip the bridge.
    (tmp_path / "elsewhere").mkdir()
    (tmp_path / "state" / "msb").mkdir(parents=True)
    (tmp_path / "state" / "msb" / "ssh-agent").symlink_to(tmp_path / "elsewhere")
    link = _link(tmp_path, "rofs")
    link.symlink_to(_sock(tmp_path / "old.sock"))
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    monkeypatch.setenv("ACQ_MSB_STUB_AGENT", "unreachable")
    _seed_recorded("rofs")
    seen = _spy(monkeypatch)
    ssh_agent.start_bridge("rofs")
    err = capsys.readouterr().err
    assert f"Fix or remove '{link.parent}'" in err and "skipping the bridge" in err
    assert len(err.splitlines()) == 1
    assert link.is_symlink() and _target(link) == str(tmp_path / "old.sock")
    assert not any("nohup socat" in " ".join(argv) for argv in seen)
    assert "removed the ssh-agent route link" not in err and "UNREACHABLE" not in err
    assert "just re-pointed" not in err and "names your live agent" not in err


# ---------------------------------------------------------------------------
# The re-drive and its route probe.
# ---------------------------------------------------------------------------

_ROUTE = {"vsock": {"routes": [{"host_socket": "/private/var/run/x/Listeners", "port": 3552}]}}


def _inspect(monkeypatch, doc):
    monkeypatch.setenv("ACQ_MSB_STUB_INSPECT_RAW", doc if isinstance(doc, str) else json.dumps(doc))


@pytest.mark.parametrize("doc,want", [
    ({"active_config": _ROUTE}, ssh_agent.ROUTE_PRESENT),
    (_ROUTE, ssh_agent.ROUTE_PRESENT),
    ({"active_config": {"network": {}}}, ssh_agent.ROUTE_MISSING),
    ({"active_config": {"network": {"ports": [{"port": 3552}]}}}, ssh_agent.ROUTE_MISSING),
    ({"vsock": {"routes": [{"port": 35521}]}}, ssh_agent.ROUTE_MISSING),
    ({"vsock": {"routes": []}, "network": {"ports": [{"guest_port": 3552, "host_port": 3552}]}},
     ssh_agent.ROUTE_MISSING),
])
def test_the_route_probe_needs_a_vsock_key_and_the_agent_port(tmp_path, monkeypatch, doc, want):
    _env(monkeypatch, tmp_path, catalog={"pbox": "running"})
    _inspect(monkeypatch, doc)
    assert ssh_agent.has_route("pbox") == want


def test_the_route_probe_reads_a_large_document(tmp_path, monkeypatch):
    _env(monkeypatch, tmp_path, catalog={"pbox": "running"})
    # The stub reads it from one environment variable, which Windows caps at 32767 characters.
    doc = json.dumps({**_ROUTE, "pad": [f"x{i:06d}" for i in range(2500)]})
    _inspect(monkeypatch, doc)
    assert ssh_agent.has_route("pbox") == ssh_agent.ROUTE_PRESENT


def test_a_failing_inspect_is_unknown_after_two_tries(tmp_path, monkeypatch):
    _env(monkeypatch, tmp_path, catalog={"pbox": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_INSPECT_FAIL_TIMES", "2")
    seen = _spy(monkeypatch)
    assert ssh_agent.has_route("pbox") == ssh_agent.ROUTE_UNKNOWN
    assert [a for a in seen if a[0] == "inspect"] == [["inspect", "pbox", "--format", "json"]] * 2


def _stub_route(tmp_path, name, port=3552):
    path = tmp_path / "msb-home" / ".microsandbox" / "vsock.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({name: [{"host_socket": "/x/Listeners", "port": port}]}), encoding="utf-8")


@needs_unix_sockets
def test_the_re_drive_wires_a_running_sandbox_that_has_the_route(tmp_path, monkeypatch, capsys):
    _env(monkeypatch, tmp_path, catalog={"rbox": "running"})
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    _stub_route(tmp_path, "rbox")
    seen = _spy(monkeypatch)
    assert ssh_agent.ensure_forward("rbox") == GUEST_SOCK
    assert _bridges(seen) == [_bridge_argv("rbox")]
    assert not any(a[0] == "start" for a in seen)
    assert _recorded("rbox") == GUEST_SOCK
    assert ssh_agent.forwarding_sock("rbox") == GUEST_SOCK
    assert "ssh-agent --vsock route" not in capsys.readouterr().err


@needs_unix_sockets
def test_a_transient_inspect_failure_is_retried_and_the_forward_wired(tmp_path, monkeypatch, capsys):
    _env(monkeypatch, tmp_path, catalog={"rbox": "running"})
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    monkeypatch.setenv("ACQ_MSB_STUB_INSPECT_FAIL_TIMES", "1")
    _stub_route(tmp_path, "rbox")
    seen = _spy(monkeypatch)
    assert ssh_agent.ensure_forward("rbox") == GUEST_SOCK
    assert len(_bridges(seen)) == 1 and "route" not in capsys.readouterr().err


def test_the_re_drive_is_a_no_op_without_an_agent_forward(tmp_path, monkeypatch, capsys):
    _env(monkeypatch, tmp_path, catalog={"rbox": "running"})
    _stub_route(tmp_path, "rbox")
    seen = _spy(monkeypatch)
    assert ssh_agent.ensure_forward("rbox") is None
    assert seen == [] and capsys.readouterr().err == ""


@needs_unix_sockets
def test_a_host_socket_forward_alone_does_not_re_drive_the_agent(tmp_path, monkeypatch):
    _env(monkeypatch, tmp_path, catalog={"rbox": "running"})
    monkeypatch.setenv("ACQ_FORWARD_HOST_SOCKETS", f"{_sock(tmp_path / 'c.sock')}:6000")
    _stub_route(tmp_path, "rbox")
    seen = _spy(monkeypatch)
    assert ssh_agent.ensure_forward("rbox") is None and seen == []


@needs_unix_sockets
@pytest.mark.parametrize("doc", [{"active_config": {"network": {}}}, {"active_config": {"network": {"ports": [{"port": 3552}]}}}])
def test_the_re_drive_warns_when_the_sandbox_has_no_route(tmp_path, monkeypatch, capsys, doc):
    _env(monkeypatch, tmp_path, catalog={"rbox": "running"})
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    _inspect(monkeypatch, doc)
    seen = _spy(monkeypatch)
    assert ssh_agent.ensure_forward("rbox") is None
    err = capsys.readouterr().err
    assert "has no ssh-agent --vsock route" in err and "SSH_AUTH_SOCK will not be set in the guest" in err
    assert "same name after wiping msb state" in err
    assert _bridges(seen) == [] and ssh_agent.forwarding_sock("rbox") is None


@needs_unix_sockets
def test_the_re_drive_says_it_could_not_verify_when_inspect_keeps_failing(tmp_path, monkeypatch, capsys):
    _env(monkeypatch, tmp_path, catalog={"rbox": "running"})
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "inspect")
    seen = _spy(monkeypatch)
    assert ssh_agent.ensure_forward("rbox") is None
    err = capsys.readouterr().err
    assert "could not verify the ssh-agent --vsock route for 'rbox' (msb inspect failed)" in err
    assert "has no ssh-agent --vsock route" not in err
    assert "raw backend failure detail" not in err  # backend text is never surfaced (ADR-0040m)
    assert _bridges(seen) == []


# ---------------------------------------------------------------------------
# Through the CLI: create, sessions, start, re-attach, kit update, rm.
# ---------------------------------------------------------------------------


def _kit_agent_execs(seen):
    """Agent-user kit commands (not the bridge or its probes)."""
    return [a for a in seen if a[0] == "exec" and a[1:3] == ["-u", "agent"] and "HOME=/home/agent" in a]


@needs_unix_sockets
def test_create_routes_the_agent_wires_the_bridge_and_sessions_get_the_socket(tmp_path, monkeypatch, capsys, roomy):
    ws = _env(monkeypatch, tmp_path)
    agent = _sock(tmp_path / "agent.sock")
    monkeypatch.setenv("SSH_AUTH_SOCK", agent)
    seen = _spy(monkeypatch)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc == 0, doc
    link = _link(tmp_path, "box")
    assert _vsock(_create_argv(seen)) == [f"{link}:3552/stream"]
    assert _target(link) == os.path.realpath(agent)
    assert "forwarding your host ssh-agent" in err
    # Forwarding adds no envelope field (``ports`` comes from port publishing).
    assert set(doc["data"]) == {"name", "backend", "agent", "workspace", "state", "image", "secret_bindings",
                                "ro_host_config", "kit", "entrypoint", "kits", "ports"}
    # Agent-user kit commands see the guest socket right after HOME.
    execs = _kit_agent_execs(seen)
    assert execs and all(a[a.index("HOME=/home/agent") + 1:][:2] == ["-e", f"SSH_AUTH_SOCK={GUEST_SOCK}"] for a in execs)
    # The bridge runs once, after every kit command.
    bridge_at = [i for i, a in enumerate(seen) if a in _bridges(seen)]
    assert len(bridge_at) == 1 and bridge_at[0] > seen.index(execs[-1])
    assert _recorded("box") == GUEST_SOCK
    # Sessions get the guest socket, never the host's.
    monkeypatch.setattr(msb, "_run_stream", lambda argv, **k: seen.append(list(argv)) or 0)
    assert cli.main(["--backend", "msb", "exec", "box", "--", "true"]) == 0
    assert f"SSH_AUTH_SOCK={GUEST_SOCK}" in seen[-1] and f"SSH_AUTH_SOCK={agent}" not in seen[-1]


def test_create_without_an_agent_has_no_route_bridge_or_session_socket(tmp_path, monkeypatch, capsys):
    ws = _env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc == 0, doc
    assert _vsock(_create_argv(seen)) == [] and _bridges(seen) == []
    assert not any("SSH_AUTH_SOCK=" in t for a in seen for t in a)
    assert _recorded("box") is None and "ssh-agent" not in err
    monkeypatch.setattr(msb, "_run_stream", lambda argv, **k: seen.append(list(argv)) or 0)
    assert cli.main(["--backend", "msb", "exec", "box", "--", "true"]) == 0
    assert not any(t.startswith("SSH_AUTH_SOCK=") for t in seen[-1])


def test_create_with_a_non_socket_agent_path_skips_the_forward_and_succeeds(tmp_path, monkeypatch, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("SSH_AUTH_SOCK", str(tmp_path / "missing.sock"))
    seen = _spy(monkeypatch)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc == 0, doc
    assert "acq: SSH_AUTH_SOCK is set but not a socket; skipping ssh-agent forwarding" in err
    assert _vsock(_create_argv(seen)) == [] and _bridges(seen) == []


def _created(tmp_path, monkeypatch, capsys, name="box"):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(tmp_path / "agent.sock"))
    rc, doc, _err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", name, "--json")
    assert rc == 0, doc
    monkeypatch.setattr(ssh_agent, "_ACTIVE", set())  # the next command is a new process
    return ws


@needs_unix_sockets
@pytest.mark.parametrize("verb", ["start", "restart"])
def test_start_restarts_the_bridge_and_re_drives_the_forward(tmp_path, monkeypatch, capsys, roomy, verb):
    _created(tmp_path, monkeypatch, capsys)
    assert cli.main(["--backend", "msb", "stop", "box"]) == 0
    seen = _spy(monkeypatch)
    rc, doc, _err = _invoke(capsys, "--backend", "msb", verb, "box", "--json")
    assert rc == 0, doc
    started = seen.index(["start", "box"])
    bridges = [i for i, a in enumerate(seen) if a in _bridges(seen)]
    # The recorded-socket restart after the resume, then the heal's re-drive.
    assert len(bridges) == 2 and all(i > started for i in bridges)
    assert all(f"SSH_AUTH_SOCK={GUEST_SOCK}" in a for a in _kit_agent_execs(seen))


@needs_unix_sockets
def test_start_from_a_shell_without_an_agent_disconnects_the_forward(tmp_path, monkeypatch, capsys, roomy):
    _created(tmp_path, monkeypatch, capsys)
    link = _link(tmp_path, "box")
    assert link.is_symlink() and _recorded("box") == GUEST_SOCK
    assert cli.main(["--backend", "msb", "stop", "box"]) == 0
    monkeypatch.delenv("SSH_AUTH_SOCK")
    seen = _spy(monkeypatch)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "start", "box", "--json")
    assert rc == 0, doc
    assert _bridges(seen) == []
    assert not os.path.lexists(link) and (tmp_path / "agent.sock").is_socket()
    assert _recorded("box") is None
    assert err.count("the forwarded ssh-agent was disconnected from 'box'") == 1
    assert not any(t.startswith("SSH_AUTH_SOCK=") for a in _kit_agent_execs(seen) for t in a)
    monkeypatch.setattr(msb, "_run_stream", lambda argv, **k: seen.append(list(argv)) or 0)
    assert cli.main(["--backend", "msb", "exec", "box", "--", "true"]) == 0
    assert not any(t.startswith("SSH_AUTH_SOCK=") for t in seen[-1])


@needs_unix_sockets
def test_a_start_with_an_agent_after_the_opt_out_reconnects(tmp_path, monkeypatch, capsys, roomy):
    _created(tmp_path, monkeypatch, capsys)
    agent = os.environ["SSH_AUTH_SOCK"]
    monkeypatch.delenv("SSH_AUTH_SOCK")
    assert _invoke(capsys, "--backend", "msb", "start", "box", "--json")[0] == 0
    assert not os.path.lexists(_link(tmp_path, "box"))
    monkeypatch.setattr(ssh_agent, "_ACTIVE", set())
    monkeypatch.setenv("SSH_AUTH_SOCK", agent)
    seen = _spy(monkeypatch)
    rc, doc, _err = _invoke(capsys, "--backend", "msb", "start", "box", "--json")
    assert rc == 0, doc
    assert _target(_link(tmp_path, "box")) == os.path.realpath(agent)  # the route names the link
    assert len(_bridges(seen)) == 1 and _recorded("box") == GUEST_SOCK


@needs_unix_sockets
def test_run_re_attach_without_an_agent_disconnects_the_forward(tmp_path, monkeypatch, capsys, roomy):
    _created(tmp_path, monkeypatch, capsys)
    monkeypatch.delenv("SSH_AUTH_SOCK")
    launched = []
    monkeypatch.setattr(msb, "launch", lambda name, ws, agent, **k: launched.append(k.get("env")) or 0)
    seen = _spy(monkeypatch)
    assert cli.main(["--backend", "msb", "run", "box"]) == 0
    assert _bridges(seen) == [] and not os.path.lexists(_link(tmp_path, "box"))
    assert not any(e.startswith("SSH_AUTH_SOCK=") for e in launched[0])


@needs_unix_sockets
def test_a_socket_inside_the_workspace_is_refused_at_create(tmp_path, monkeypatch, capsys, roomy):
    ws = _env(monkeypatch, tmp_path)
    inside = _sock(ws / "agent.sock")
    monkeypatch.setenv("SSH_AUTH_SOCK", inside)
    monkeypatch.setenv("ACQ_FORWARD_HOST_SOCKETS", f"{inside}:6000")
    seen = _spy(monkeypatch)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc == 0, doc
    assert _vsock(_create_argv(seen)) == [] and _bridges(seen) == []
    assert f"refusing to forward the socket '{os.path.realpath(inside)}' (SSH_AUTH_SOCK): it is inside the workspace" in err
    assert "(ACQ_FORWARD_HOST_SOCKETS): it is inside the workspace" in err
    assert "forwarding your host ssh-agent" not in err and not os.path.lexists(_link(tmp_path, "box"))


@needs_unix_sockets
def test_a_socket_inside_the_recorded_workspace_is_refused_at_refresh(tmp_path, monkeypatch, capsys, roomy):
    ws = _created(tmp_path, monkeypatch, capsys)
    link = _link(tmp_path, "box")
    outside = _target(link)
    monkeypatch.setenv("SSH_AUTH_SOCK", _sock(ws / "inside.sock"))
    ssh_agent.start_bridge("box")
    err = capsys.readouterr().err
    assert "(SSH_AUTH_SOCK): it is inside the workspace" in err
    assert _target(link) == outside  # kept: still the user's socket outside the workspace


@pytest.mark.skipif(os.name == "nt", reason="POSIX socket paths (a Windows host never forwards)")
def test_the_owner_of_a_forwarded_socket_is_warned_about_not_refused(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(ssh_agent, "is_socket", lambda p: True)
    monkeypatch.setattr(ssh_agent, "_socket_owned_by_me", lambda p: False)
    monkeypatch.setenv("SSH_AUTH_SOCK", "/run/theirs.sock")
    monkeypatch.setenv("ACQ_FORWARD_HOST_SOCKETS", "/run/other.sock:6000")
    forwards = ssh_agent.host_socket_forwards()
    assert [f.label for f in forwards] == ["ssh-agent", "custom"]
    err = capsys.readouterr().err
    assert "acq: warning: SSH_AUTH_SOCK names a socket owned by another user; forwarding it anyway" in err
    assert "acq: warning: host-socket path /run/other.sock is a socket owned by another user; forwarding it anyway" in err


@needs_unix_sockets
def test_the_link_directory_is_private_and_never_a_symlink(tmp_path, monkeypatch, roomy):
    _env(monkeypatch, tmp_path)
    agent = _sock(tmp_path / "agent.sock")
    link = _link(tmp_path, "box")
    assert ssh_agent.link_point(str(link), agent)
    assert (os.lstat(link.parent).st_mode & 0o777) == 0o700
    link.parent.chmod(0o755)
    assert ssh_agent.link_point(str(_link(tmp_path, "box2")), agent)
    assert (os.lstat(link.parent).st_mode & 0o777) == 0o700
    other = tmp_path / "s2"
    monkeypatch.setenv("ACQ_STATE_DIR", str(other))
    (other / "msb").mkdir(parents=True)
    (other / "msb" / "ssh-agent").symlink_to(tmp_path / "elsewhere")
    (tmp_path / "elsewhere").mkdir()
    assert not ssh_agent.link_point(f"{other}/msb/ssh-agent/box.sock", agent)


@needs_unix_sockets
def test_start_of_a_running_sandbox_does_not_restart_from_the_record(tmp_path, monkeypatch, capsys, roomy):
    _created(tmp_path, monkeypatch, capsys)
    monkeypatch.delenv("SSH_AUTH_SOCK")
    seen = _spy(monkeypatch)
    rc, doc, _err = _invoke(capsys, "--backend", "msb", "start", "box", "--json")
    assert rc == 0 and doc["data"]["was_running"] is True
    assert _bridges(seen) == []


@needs_unix_sockets
def test_run_re_attach_to_a_running_sandbox_re_drives_the_forward(tmp_path, monkeypatch, capsys, roomy):
    _created(tmp_path, monkeypatch, capsys)
    kit_msb.hc_clear("box", "ssh-auth-sock")  # e.g. created before forwarding was configured
    launched = []
    monkeypatch.setattr(msb, "launch", lambda name, ws, agent, **k: launched.append(k.get("env")) or 0)
    seen = _spy(monkeypatch)
    assert cli.main(["--backend", "msb", "run", "box"]) == 0
    assert len(_bridges(seen)) == 1 and not any(a[0] == "start" for a in seen)
    assert f"SSH_AUTH_SOCK={GUEST_SOCK}" in launched[0]


@needs_unix_sockets
def test_kit_update_re_drives_the_forward(tmp_path, monkeypatch, capsys, roomy):
    _created(tmp_path, monkeypatch, capsys)
    from acq_py import kits

    path = kits._provenance_path("msb", "box")  # stale, so the update reapplies
    path.write_text(json.dumps({"schema": kits.KIT_SCHEMA, "backend": "msb", "sandbox": "box",
                                "applied_ref": "0" * 40}), encoding="utf-8")
    seen = _spy(monkeypatch)
    rc, doc, _err = _invoke(capsys, "--backend", "msb", "kit", "update", "box", "--yes", "--json")
    assert rc == 0, doc
    assert len(_bridges(seen)) == 1
    assert all(f"SSH_AUTH_SOCK={GUEST_SOCK}" in a for a in _kit_agent_execs(seen))


@needs_unix_sockets
def test_rm_removes_the_link_but_never_the_agent_socket(tmp_path, monkeypatch, capsys, roomy):
    _created(tmp_path, monkeypatch, capsys)
    link = _link(tmp_path, "box")
    assert link.is_symlink()
    rc, doc, _err = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 0, doc
    assert not os.path.lexists(link)
    assert (tmp_path / "agent.sock").is_socket()


def test_the_record_written_by_bash_reaches_python_sessions(tmp_path, monkeypatch):
    from acq_py.commands import session

    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    state.record_write("msb", "box", agent="shell", workspace=str(tmp_path / "ws"), image="img")
    _seed_recorded("box", "/home/agent/.acq/ssh-agent.sock\n")
    assert f"SSH_AUTH_SOCK={GUEST_SOCK}" in session.session_env_for("msb", "box")
    _seed_recorded("box", "relative.sock")
    assert not any(e.startswith("SSH_AUTH_SOCK=") for e in session.session_env_for("msb", "box"))


# ---------------------------------------------------------------------------
# sbx: the CLI forwards the agent itself; acq only says so.
# ---------------------------------------------------------------------------


def test_sbx_create_prints_the_trust_boundary_notice_once_when_an_agent_is_set(monkeypatch, capsys):
    from acq_py import sbx

    calls = []
    monkeypatch.setattr(sbx, "_run", lambda argv, **k: calls.append(argv) or subprocess.CompletedProcess(argv, 0, "", ""))
    sbx.create("box", "img", "/w")
    assert capsys.readouterr().err == ""
    monkeypatch.setenv("SSH_AUTH_SOCK", "/anything")
    sbx.create("box", "img", "/w")
    sbx.create("box2", "img", "/w")
    err = capsys.readouterr().err
    assert err == sbx.SSH_AGENT_NOTICE + "\n"
    assert "acq(sbx): sbx forwards your host ssh-agent" in err and "--vsock" not in " ".join(map(str, calls))


# ---------------------------------------------------------------------------
# Parity with the Bash adapter.
# ---------------------------------------------------------------------------

_BASH_PRELUDE = r"""
ACQ_SOURCE_ONLY=1 . "$REPO/acq"
type _acq_msb_start_ssh_agent_bridge >/dev/null 2>&1 || . "$REPO/acq.backends/msb.sh"
_acq_msb_version() { echo 0.7.7; }
acq_host_config_write() { :; }
_acq_msb_cli() { printf '%s\037' "$@" >>"$CALLS"; printf '\036' >>"$CALLS"; return 0; }
"""


def _bash(tmp_path, script: str, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    base = {k: v for k, v in os.environ.items() if not k.startswith("ACQ_") and k != "SSH_AUTH_SOCK"}
    base |= {"REPO": str(REPO_ROOT), "LC_ALL": "C", "ACQ_STATE_DIR": str(tmp_path / "state"),
             "CALLS": str(tmp_path / "calls")} | (env or {})
    assert BASH is not None
    return subprocess.run([BASH, "-c", _BASH_PRELUDE + script, "x", *args], env=base, capture_output=True,
                          cwd=tmp_path, text=True)


def _bash_calls(tmp_path) -> list[list[str]]:
    path = tmp_path / "calls"
    raw = path.read_text(encoding="utf-8") if path.exists() else ""
    return [rec.split("\x1f")[:-1] for rec in raw.split("\x1e")[:-1]]


@needs_bash
def test_the_guest_argv_matches_bash(tmp_path, monkeypatch):
    _bash(tmp_path, "_ACQ_MSB_SSH_AGENT_FORWARDING=1; _acq_msb_check_socat sbox && _acq_msb_start_ssh_agent_bridge sbox")
    calls: list[list[str]] = []
    monkeypatch.setattr(msb, "call", lambda argv, **k: calls.append(argv) or subprocess.CompletedProcess(argv, 0, "", ""))
    monkeypatch.setattr(kit_msb, "hc_write", lambda *a: None)
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    ssh_agent._ACTIVE.add("sbox")
    ssh_agent.provision_bridge("sbox")
    assert calls == _bash_calls(tmp_path)


@needs_bash
@pytest.mark.parametrize("name", ["box", "a-rather-long-sandbox-name-for-the-sun-path-overflow-case-x", "../x", "-x", "a.b"])
@pytest.mark.parametrize("budget", [103, 4096])
@pytest.mark.parametrize("slash", ["", "/"])
def test_the_link_path_matches_bash(tmp_path, monkeypatch, name, budget, slash):
    state_dir = f"{tmp_path / 'state'}{slash}"
    proc = _bash(tmp_path, f'ACQ_MSB_SUN_PATH_MAX={budget}; _acq_msb_ssh_agent_link_path "$1" || echo NONE', name,
                 env={"ACQ_STATE_DIR": state_dir})
    monkeypatch.setenv("ACQ_STATE_DIR", state_dir)
    monkeypatch.setattr(ssh_agent, "SUN_PATH_MAX", budget)
    assert (ssh_agent.link_path(name) or "NONE") == proc.stdout.strip()


@needs_bash
@needs_unix_sockets
def test_the_routes_and_warnings_match_bash(tmp_path, monkeypatch, capsys):
    agent = _sock(tmp_path / "agent.sock")
    custom = _sock(tmp_path / "custom.sock")
    (tmp_path / "custom.link").symlink_to(custom)
    hosts = ",".join([f"{tmp_path / 'custom.link'}:6000/dgram", "rel.sock:6001", f"{custom}:123", "/nope/x.sock:7",
                      f"{custom}"])
    env = {"SSH_AUTH_SOCK": agent, "ACQ_FORWARD_HOST_SOCKETS": hosts}
    proc = _bash(tmp_path, 'f=(); _acq_msb_vsock_flags_into f "../x"; printf "%s\\n" "${f[@]}"', env=env)
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    _env(monkeypatch, tmp_path)
    flags = ssh_agent.vsock_flags("../x", [])
    assert flags == proc.stdout.splitlines()
    assert capsys.readouterr().err == proc.stderr


@needs_unix_sockets
@pytest.mark.parametrize("old_inside", [False, True])
def test_refresh_checks_secondary_writable_mounts(tmp_path, monkeypatch, capsys, roomy, old_inside):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    extra = tmp_path / "extra"
    extra.mkdir()
    inside = _sock(extra / "agent.sock")
    outside = _sock(tmp_path / "old.sock")
    link = _link(tmp_path, "box")
    assert ssh_agent.link_point(str(link), inside if old_inside else outside)
    monkeypatch.setenv("SSH_AUTH_SOCK", inside)
    _inspect(monkeypatch, {"active_config": {"mounts": [
        {"host": str(extra), "options": {"readonly": False}}]}})
    _, removed = ssh_agent.link_refresh("box")
    assert removed == old_inside
    assert "inside the workspace" in capsys.readouterr().err
    assert not link.is_symlink() if old_inside else _target(link) == outside


def test_link_directory_refuses_symlinked_or_foreign_msb_parent(tmp_path, monkeypatch):
    parent = tmp_path / "msb"
    real = tmp_path / "real"
    real.mkdir()
    parent.symlink_to(real, target_is_directory=True)
    assert not ssh_agent._private_link_dir(str(parent / "ssh-agent"))
    assert not (real / "ssh-agent").exists()
    parent.unlink()
    parent.mkdir()
    owner = ssh_agent._owned_by_me
    ino = parent.stat().st_ino
    monkeypatch.setattr(ssh_agent, "_owned_by_me", lambda info: info.st_ino != ino and owner(info))
    assert not ssh_agent._private_link_dir(str(parent / "ssh-agent"))


@pytest.mark.parametrize("directory", ["link", "parent"])
@pytest.mark.parametrize("unsafe", ["symlink", "foreign"])
@pytest.mark.parametrize("action", ["start", "opt_out", "cleanup", "stale_target"])
def test_untrusted_route_directories_are_never_modified(
    tmp_path, monkeypatch, capsys, roomy, directory, unsafe, action,
):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    link = _link(tmp_path, "box")
    link.parent.mkdir(parents=True)
    link.symlink_to(tmp_path / "missing-agent.sock")
    bad = link.parent if directory == "link" else link.parent.parent
    if unsafe == "symlink":
        moved = bad.with_name("moved")
        bad.rename(moved)
        bad.symlink_to(moved, target_is_directory=True)
    else:
        owner = ssh_agent._owned_by_me
        ino = bad.stat().st_ino
        monkeypatch.setattr(ssh_agent, "_owned_by_me", lambda info: info.st_ino != ino and owner(info))
    _seed_recorded("box")
    seen = _spy(monkeypatch)
    monkeypatch.setenv("SSH_AUTH_SOCK", "/no-live-agent")
    if action == "start":
        ssh_agent.start_bridge("box")
    elif action == "opt_out":
        monkeypatch.delenv("SSH_AUTH_SOCK")
        ssh_agent.start_bridge("box")
    elif action == "cleanup":
        ssh_agent.link_remove("box")
    else:
        assert ssh_agent.link_refresh("box")[1]
    assert link.is_symlink() and _target(link) == str(tmp_path / "missing-agent.sock")
    assert not any("nohup socat" in " ".join(argv) for argv in seen)
    err = capsys.readouterr().err
    # The link path is joined with '/', so on Windows the message mixes separators.
    assert len(err.splitlines()) == 1 and f"Fix or remove '{bad}'" in err.replace("/", os.sep)
    # The low-level failed-attempt cleanup must honor the same boundary.
    ssh_agent._unlink_quietly(str(link))
    assert link.is_symlink()


@pytest.mark.parametrize("directory", ["link", "parent"])
def test_route_directory_guard_refuses_regular_files(tmp_path, monkeypatch, capsys, roomy, directory):
    _env(monkeypatch, tmp_path)
    parent = tmp_path / "state" / "msb"
    bad = parent if directory == "parent" else parent / "ssh-agent"
    bad.parent.mkdir(parents=True, exist_ok=True)
    bad.write_text("keep")
    assert ssh_agent._unsafe_link_dir(str(parent / "ssh-agent" / "box.sock")) == str(bad)
    monkeypatch.setenv("SSH_AUTH_SOCK", "/no-live-agent")
    monkeypatch.setattr(ssh_agent, "recorded_sock", lambda name: GUEST_SOCK)
    monkeypatch.setattr(msb, "call", lambda *a, **kw: pytest.fail("bridge must not start"))
    ssh_agent.start_bridge("box")
    assert f"Fix or remove '{bad}'" in capsys.readouterr().err
    assert bad.read_text() == "keep"


@needs_unix_sockets
def test_refresh_leaves_link_through_symlinked_msb_parent_untouched(tmp_path, monkeypatch, capsys, roomy):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    agent = _sock(tmp_path / "agent.sock")
    link = _link(tmp_path, "box")
    assert ssh_agent.link_point(str(link), agent)
    parent = link.parent.parent
    moved = parent.with_name("moved")
    parent.rename(moved)
    parent.symlink_to(moved, target_is_directory=True)
    monkeypatch.setenv("SSH_AUTH_SOCK", agent)
    _, skip_bridge = ssh_agent.link_refresh("box")
    assert skip_bridge and link.is_symlink() and _target(link) == agent
    assert f"Fix or remove '{parent}'" in capsys.readouterr().err
    assert Path(agent).exists()


def test_refresh_workspaces_include_inspected_and_recorded_extras(tmp_path, monkeypatch):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    monkeypatch.setattr(state, "record_read", lambda *a: {
        "workspace": "/primary", "extra_workspaces": ["/extra", "/readonly:ro"]})
    _inspect(monkeypatch, {"active_config": {"mounts": [
        {"host": "/mounted", "options": {"readonly": False}},
        {"host": "/mounted-ro", "options": {"readonly": True}}]}})
    assert ssh_agent.recorded_workspaces("box") == ["/primary", "/extra", "/mounted"]


def test_route_json_preserves_punctuation_and_binds_host_to_agent_port(tmp_path, monkeypatch):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / 's ,{}[]"'))
    monkeypatch.setattr(ssh_agent, "SUN_PATH_MAX", 4096)
    link = ssh_agent.link_path("box")
    doc = {"active_config": {"vsock": {"routes": [{"host_socket": link, "port": 3552}]}}}
    _inspect(monkeypatch, doc)
    parsed = ssh_agent._route_doc("box")
    assert ssh_agent._route_names_link(parsed, "box")
    assert ssh_agent.has_route("box") == ssh_agent.ROUTE_PRESENT
    doc["active_config"]["vsock"]["routes"][0]["port"] = 6000
    doc["active_config"]["network"] = {"ports": [{"port": 3552}]}
    _inspect(monkeypatch, doc)
    assert ssh_agent.has_route("box") == ssh_agent.ROUTE_MISSING
    assert not ssh_agent._route_names_link(ssh_agent._route_doc("box"), "box")


def test_bridge_stops_exact_old_listener_before_unlink_and_sets_private_umask():
    script = ssh_agent.bridge_script(GUEST_SOCK, "3552")
    stop = r"pkill -f -x 'socat UNIX-LISTEN:/home/agent/\.acq/ssh-agent\.sock,fork,reuseaddr VSOCK-CONNECT:2:3552'"
    assert script.index(stop) < script.index("rm -f") < script.index("nohup socat")
    assert script.index("umask 077") < script.index("nohup socat")


@needs_unix_sockets
def test_failed_create_removes_staged_agent_link(tmp_path, monkeypatch, capsys, roomy):
    ws = _env(monkeypatch, tmp_path)
    agent = _sock(tmp_path / "agent.sock")
    monkeypatch.setenv("SSH_AUTH_SOCK", agent)

    def fail(*args, **kwargs):
        assert _link(tmp_path, "box").is_symlink()
        raise msb.MsbError("failure", "create failed", "retry")

    monkeypatch.setattr(msb, "create", fail)
    rc, _, _ = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc != 0
    assert not _link(tmp_path, "box").is_symlink()
    assert Path(agent).exists()


@pytest.mark.parametrize("custom,published", [(True, []), (False, ["3552"])])
def test_collision_is_refused_before_staging_link(tmp_path, monkeypatch, custom, published):
    _env(monkeypatch, tmp_path)
    forwards = [ssh_agent.Forward("/agent", "3552", "stream", "ssh-agent")]
    if custom:
        forwards.append(ssh_agent.Forward("/custom", "03552", "stream", "custom"))
    monkeypatch.setattr(ssh_agent, "host_socket_forwards", lambda: forwards)
    with pytest.raises(msb.MsbError, match="vsock port .* collides"):
        ssh_agent.vsock_flags("box", [], published)
    assert not _link(tmp_path, "box").is_symlink()


def test_create_checks_published_guest_ports_before_calling_backend(tmp_path, monkeypatch):
    from acq_py import publish
    from acq_py.commands import lifecycle

    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setattr(publish, "create_port_flags", lambda *a: (
        ["-p", "5000:3552"], [{"host_port": 5000, "guest_port": 3552}]))
    monkeypatch.setattr(lifecycle, "_provider_prepare", lambda *a, **k: None)
    monkeypatch.setattr(kit_msb, "create_flags", lambda *a, **k: ([], []))
    monkeypatch.setattr(ssh_agent, "host_socket_forwards", lambda: [
        ssh_agent.Forward("/agent", "3552", "stream", "ssh-agent")])

    def unexpected(*a, **k):
        pytest.fail("colliding ports reached msb create")

    monkeypatch.setattr(msb, "create", unexpected)
    with pytest.raises(msb.MsbError, match="vsock port 3552 collides"):
        lifecycle._msb_create("box", "image", str(ws), [], ro_mount=False)
