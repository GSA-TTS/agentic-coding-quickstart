"""Published ports: ``--publish HOST:GUEST`` at create and ``acq ports NAME --publish``.

A port of the Bash acq's port publishing (ADR-0014, ADR-0015, ADR-0034):

* :func:`validate_create_pairs` is ``extract_publish_flags`` /
  ``_acq_validate_publish_pair``: the create-time values, with the Bash rules and
  messages (both sides, digits only, no leading zero, 1..65535, one host port
  per guest port).
* :func:`create_port_flags` is the msb provision's port composition
  (``_acq_msb_port_records_dedupe`` and ``_acq_msb_port_flags_from_records``):
  every kit's ``publishedPorts`` records, then the ``--publish`` overrides, last
  wins by guest port, turned into ``msb create -p HOST:GUEST`` flags. A kit that
  leaves the host side open gets a free loopback port picked per sandbox; an
  explicit host port that is already in use fails the create rather than being
  replaced by another one.
* :func:`publish_posthoc`, :func:`teardown` and :func:`posthoc_ports` are the
  msb post-hoc publish (``acq_backend_ports`` and its helpers): an acq-managed
  ed25519 key, ``msb ssh serve`` on a loopback port and an OpenSSH ``-L``
  forward, both left running in the background, with their process ids recorded
  in ``ACQ_STATE_DIR/ports/NAME.pids`` in the Bash line format, so either
  implementation can list and tear down what the other opened.

The test seams are Bash's (``ACQ_MSB_HOST_PORTS_BUSY``,
``ACQ_MSB_HOST_PROBE_STUB``, ``ACQ_MSB_HOST_PROBE_UNKNOWN``,
``ACQ_MSB_FORCE_SERVE_PORT``). They only steer which host port is chosen or
reported busy; none of them reaches a secret or widens what is published.
"""

from __future__ import annotations

import itertools
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

from . import errors, hostexec, state, userdirs

# The Bash picker's range: 20000..59999, loopback only.
_PICK_FLOOR, _PICK_WIDTH = 20000, 40000
_PICK_TRIES = 12
_PICK_BASE = secrets.randbelow(_PICK_WIDTH)
_PICK_SEQ = itertools.count(1)

# Bash's ``_acq_msb_ports_pidfile`` charset: the names acq itself produces.
_PIDFILE_NAME = re.compile(r"[A-Za-z0-9_-]+")
_SSH_USER = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]*")

NOTE_PREFIX = "acq(msb): note: "


class PublishError(Exception):
    """A port could not be published; ``message``/``remediation`` are acq prose only."""

    def __init__(self, code: str, message: str, remediation: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.remediation = remediation


def _note(text: str) -> None:
    print(f"{NOTE_PREFIX}{text}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Create-time values (extract_publish_flags / _acq_validate_publish_pair).
# ---------------------------------------------------------------------------

PUBLISH_EXAMPLE = (
    "e.g. --publish 6868:6767 reaches the sandbox's guest port 6767 on host port 6868; "
    "the guest port is the one the kit publishes"
)


def _pair_problem(pair: str, earlier: list[str]) -> str | None:
    if ":" not in pair:
        return f"--publish '{pair}' is not HOST:GUEST: both sides are required"
    host, guest = pair.split(":", 1)
    for port in (host, guest):
        if not port or not (port.isascii() and port.isdigit()):
            return f"--publish '{pair}': '{port}' is not a port number (1..65535)"
        if port.startswith("0"):
            return f"--publish '{pair}': '{port}' has a leading zero; write it plainly"
        if len(port) > 5 or not 1 <= int(port) <= 65535:
            return f"--publish '{pair}': '{port}' is out of range (1..65535)"
    # A guest port is publishable once: two host ports for it is a mistake.
    for prev in earlier:
        if prev.split(":", 1)[-1] == guest:
            return (f"--publish: guest port {guest} is already mapped to host port "
                    f"{prev.split(':', 1)[0]}; drop one of the two --publish flags")
    return None


def validate_create_pairs(values: Iterable[str | None]) -> tuple[list[str], list[str]]:
    """The ``HOST:GUEST`` values given with ``--publish``, and the problems found.

    ``None`` is a ``--publish`` with no value. As in Bash every value is checked
    (a later duplicate is compared with every earlier value, valid or not), so
    all problems are reported at once.
    """
    pairs: list[str] = []
    problems: list[str] = []
    for value in values:
        if value is None:
            problems.append("--publish given with no value (expected HOST:GUEST)")
            continue
        problem = _pair_problem(value, pairs)
        if problem is not None:
            problems.append(problem)
        pairs.append(value)
    return pairs, problems


def reattach_note(name: str) -> str:
    """Bash ``note_publish_ignored_on_reattach``."""
    return (f"acq: note: --publish is ignored when re-attaching an existing sandbox ('{name}'); "
            f"the host port mapping is fixed at create. Use 'acq ports {name} --publish HOST:GUEST' "
            f"to add one now, or remove the sandbox first ('acq rm {name}') to recreate with it.")


SBX_REFUSAL = (
    "--publish is not supported on the sbx backend: sbx chooses the host port for a published guest "
    "port itself and offers no way to request one at create time"
)
SBX_REFUSAL_REMEDIATION = (
    "read the assigned mapping with 'acq ports NAME', or open a tunnel on a port you choose with "
    "'acq ports NAME --publish HOST:GUEST' after the sandbox is up"
)


# ---------------------------------------------------------------------------
# Host ports (_acq_msb_host_port_status / _acq_msb_pick_*).
# ---------------------------------------------------------------------------


def host_port_status(port: int) -> str:
    """``busy``, ``free`` or ``unknown`` for ``127.0.0.1:PORT``, as Bash's probe.

    It connects to the real listener: msb's inspect output reports the mapping
    msb was asked for even when another process owns the port. Only a refused
    connection proves the port free; a connect that neither succeeds nor is
    refused is ``unknown``, never optimistically ``free``. Always the IPv4
    loopback literal (a ``::1``-first ``localhost`` can hang on an IPv4-only
    listener).
    """
    if os.environ.get("ACQ_MSB_HOST_PROBE_UNKNOWN") == "1":
        return "unknown"
    busy = os.environ.get("ACQ_MSB_HOST_PORTS_BUSY", "").replace(",", " ").split()
    if str(port) in busy:
        return "busy"
    if os.environ.get("ACQ_MSB_HOST_PROBE_STUB") == "1":
        return "free"
    return _connect_status(port)


def _connect_status(port: int) -> str:
    # Windows retries a SYN to a closed loopback port for about two seconds
    # before it reports the refusal, so the bound is wider than that.
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=3):
            return "busy"
    except ConnectionRefusedError:
        return "free"
    except OSError:
        return "unknown"


def pick_ephemeral_port() -> int:
    """A loopback port in 20000..59999, distinct from the last one this process picked.

    ``ACQ_MSB_FORCE_SERVE_PORT`` (a valid port) pins it, as in Bash.
    """
    seq = next(_PICK_SEQ)
    forced = os.environ.get("ACQ_MSB_FORCE_SERVE_PORT", "")
    if forced.isascii() and forced.isdigit() and 1 <= int(forced) <= 65535:
        return int(forced)
    return _PICK_FLOOR + (_PICK_BASE + seq) % _PICK_WIDTH


def pick_free_host_port(taken: Iterable[int]) -> tuple[int | None, str]:
    """``(port, "free")``, ``(port, "unknown")`` (could not probe), or ``(None, "busy")``.

    Ports in ``taken`` (ones this create already maps, not bound yet) are skipped.
    """
    skip = set(taken)
    for _ in range(_PICK_TRIES):
        port = pick_ephemeral_port()
        if port in skip:
            continue
        status = host_port_status(port)
        if status != "busy":
            return port, status
    return None, "busy"


# ---------------------------------------------------------------------------
# Create-time -p flags (acq_backend_provision's port composition).
# ---------------------------------------------------------------------------


def _records(kits: Iterable, overrides: list[str]) -> list[tuple[str, str]]:
    """``(guest, host)`` records: every kit's, then the overrides; last wins by guest port."""
    records = [(p.guest, p.host) for kit in kits for p in kit.spec.published_ports]
    declared = {guest for guest, _ in records}
    for pair in overrides:
        host, guest = pair.split(":", 1)
        if guest not in declared:
            # Honoured, but a mistyped guest port would otherwise look like a working publish.
            _note(f"--publish {pair}: no applied kit declares guest port {guest}; publishing it anyway.")
        records.append((guest, host))
    last = {guest: i for i, (guest, _) in enumerate(records) if guest}
    return [rec for i, rec in enumerate(records) if rec[0] and last[rec[0]] == i]


@dataclass
class _Mapper:
    taken: list[int]
    problems: list[str]
    notice_shown: bool = False

    def unprobed(self) -> None:
        if not self.notice_shown:
            self.notice_shown = True
            _note("cannot probe host port availability on this host; publishing ports without a contention check.")

    def explicit(self, host: int, guest: str) -> bool:
        if host in self.taken:
            self.problems.append(f"host port {host} is requested for more than one guest port "
                                 f"(again for guest port {guest}); give each its own host port")
            return False
        status = host_port_status(host)
        if status == "busy":
            self.problems.append(f"host port {host} (for guest port {guest}) is already in use on 127.0.0.1; "
                                 "acq will not substitute a different port for an explicitly requested one")
            return False
        if status == "unknown":
            self.unprobed()
        return True

    def chosen(self, guest: str) -> int | None:
        port, status = pick_free_host_port(self.taken)
        if port is None:
            self.problems.append(f"could not find a free host port for guest port {guest}")
            return None
        if status == "unknown":
            self.unprobed()
        return port


def create_port_flags(name: str, kits: Iterable, overrides: list[str]) -> tuple[list[str], list[dict]]:
    """``msb create`` ``-p HOST:GUEST`` flags and the mappings they declare.

    Raises :class:`PublishError` when a port cannot be mapped; the create must
    not go ahead without a mapping the kit or the user asked for.
    """
    mapper = _Mapper([], [])
    records = []
    for guest, host in _records(kits, overrides):
        if not (guest.isascii() and guest.isdigit()) or (host and not (host.isascii() and host.isdigit())):
            print(f"acq(msb): warning: skipping non-integer published port: {host}:{guest}", file=sys.stderr)
            continue
        records.append((guest, host))
    # Explicit host ports are claimed before any is chosen, so a chosen port can
    # never take one a later record pins (Bash maps in record order, where that
    # collision fails the create).
    hosts: dict[str, int] = {}
    for guest, host in records:
        if host and mapper.explicit(int(host), guest):
            hosts[guest] = int(host)
            mapper.taken.append(int(host))
    for guest, host in records:
        port = None if host else mapper.chosen(guest)
        if port is not None:
            hosts[guest] = port
            mapper.taken.append(port)
    flags: list[str] = []
    mappings: list[dict] = []
    for guest, _host in records:
        if guest in hosts:
            flags += ["-p", f"{hosts[guest]}:{guest}"]
            mappings.append({"host_port": hosts[guest], "guest_port": int(guest), "origin": "create"})
    if mapper.problems:
        raise PublishError(
            errors.FAILURE,
            f"a published port of sandbox '{name}' could not be mapped: {'; '.join(mapper.problems)}",
            "free the host port, or request another one with --publish HOST:GUEST, then retry",
        )
    return flags, mappings


# ---------------------------------------------------------------------------
# Post-hoc publish on msb (acq_backend_ports, ADR-0015).
# ---------------------------------------------------------------------------


def _ssh_dir() -> Path:
    return userdirs.path_override("ACQ_MSB_SSH_DIR") or state.state_dir() / "ssh"


def ssh_key() -> Path:
    return userdirs.path_override("ACQ_MSB_SSH_KEY") or _ssh_dir() / "msb_id_ed25519"


def _known_hosts() -> Path:
    return userdirs.path_override("ACQ_MSB_SSH_KNOWN_HOSTS") or _ssh_dir() / "known_hosts"


def ports_dir() -> Path:
    return userdirs.path_override("ACQ_MSB_PORTS_DIR") or state.state_dir() / "ports"


def pidfile(name: str) -> Path | None:
    """The sandbox's tunnel record, or ``None`` (with a note) for a name that could escape the directory."""
    if not _PIDFILE_NAME.fullmatch(name) or name.startswith("-"):
        print(f"acq(msb): ports: refusing unsafe sandbox name '{name}' for state path.", file=sys.stderr)
        return None
    return ports_dir() / f"{name}.pids"


def posthoc_problem(mapping: str) -> str | None:
    """Bash ``_acq_msb_valid_publish``: ``HOST:GUEST``, two integers 1..65535."""
    if ":" not in mapping:
        return f"ports: --publish must be HOST:GUEST, got '{mapping}'"
    for port in mapping.split(":", 1):
        if not port or not (port.isascii() and port.isdigit()):
            return f"ports: invalid port '{port}' in '{mapping}' (want integer 1..65535)"
        if not 1 <= int(port) <= 65535:
            return f"ports: port '{port}' out of range in '{mapping}' (want 1..65535)"
    return None


def _settle(var: str, default: float) -> float:
    raw = os.environ.get(var, "")
    try:
        value = float(raw) if raw else default
    except ValueError:
        value = default
    return min(max(value, 0.0), 30.0)


def _spawn(argv: list[str]) -> subprocess.Popen:
    """Start a background process that outlives acq, with no stdio of its own."""
    kwargs: dict = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    if os.name == "nt":
        kwargs["creationflags"] = (getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
                                   | getattr(subprocess, "DETACHED_PROCESS", 0))
    else:
        kwargs["start_new_session"] = True
    return subprocess.Popen(argv, **kwargs)  # nosec B603 # argv list, no shell


def _kill(pid: int) -> None:
    """Signal a recorded process (best-effort; never pid 0 or 1, which mean a group or init)."""
    if pid <= 1:
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except (OSError, ValueError):
        pass


def _stop(proc: subprocess.Popen) -> None:
    _kill(proc.pid)
    try:
        proc.wait(timeout=5)
    except (subprocess.TimeoutExpired, OSError):
        pass


def _ensure_key(run: Callable[[list[str]], int]) -> None:
    key = ssh_key()
    if key.is_file():
        return
    key.parent.mkdir(parents=True, exist_ok=True)
    try:
        key.parent.chmod(0o700)
    except OSError:
        pass
    try:
        keygen = hostexec.command("ssh-keygen")
    except FileNotFoundError:
        raise PublishError(errors.FAILURE, "ports: ssh-keygen not found on PATH (needed for the tunnel key)",
                           "install the OpenSSH client, then retry") from None
    # No passphrase (non-interactive); the key material is never printed.
    if run([*keygen, "-q", "-t", "ed25519", "-N", "", "-f", str(key)]) != 0:
        raise PublishError(errors.FAILURE, "ports: ssh-keygen failed to create the acq tunnel key",
                           "check that the acq state directory is writable, then retry")
    try:
        key.chmod(0o600)
    except OSError:
        pass


def _ssh_argv(sport: int, host: int, guest: int) -> list[str]:
    user = os.environ.get("ACQ_MSB_SSH_USER") or "root"
    if not _SSH_USER.fullmatch(user):
        raise PublishError(errors.VALIDATION_FAILED, f"ports: ACQ_MSB_SSH_USER {user!r} is not a user name",
                           "unset ACQ_MSB_SSH_USER, or set it to a plain account name")
    try:
        ssh = hostexec.command("ssh")
    except FileNotFoundError:
        raise PublishError(errors.FAILURE, "ports: ssh not found on PATH (needed for -L forwarding)",
                           "install the OpenSSH client, then retry") from None
    # Only the acq key (IdentitiesOnly), no user ssh config (-F none), and no
    # interactive auth on a backgrounded tunnel: it fails closed instead of hanging.
    return [*ssh, "-p", str(sport), "-N", "-n", "-F", "none", "-i", str(ssh_key()),
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0",
            "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={_known_hosts()}",
            "-o", "ExitOnForwardFailure=yes", "-L", f"127.0.0.1:{host}:127.0.0.1:{guest}", f"{user}@127.0.0.1"]


def _listener_ready(port: int) -> bool:
    attempts = int(_settle("ACQ_MSB_FORWARD_PROBE_ATTEMPTS", 20))
    delay = _settle("ACQ_MSB_FORWARD_PROBE_DELAY", 0.1)
    for _ in range(max(attempts, 1)):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(delay)
    return False


@dataclass(frozen=True)
class Tunnel:
    serve_pid: int
    ssh_pid: int
    serve_port: int
    host: int
    guest: int

    def line(self) -> str:
        return f"{self.serve_pid} {self.ssh_pid} {self.serve_port} {self.host}:{self.guest}\n"

    def mapping(self) -> dict:
        return {"host_port": self.host, "guest_port": self.guest, "origin": "post-hoc"}


def _open_tunnel(name: str, serve_cmd: list[str], host: int, guest: int) -> Tunnel:
    sport = pick_ephemeral_port()
    serve = _spawn([*serve_cmd, "ssh", "serve", name, "--host", "127.0.0.1", "--port", str(sport)])
    time.sleep(_settle("ACQ_MSB_SERVE_SETTLE", 1.0))
    if serve.poll() is not None:
        raise PublishError(errors.FAILURE,
                           f"ports: 'msb ssh serve' on 127.0.0.1:{sport} exited immediately (could not start listener)",
                           f"check that sandbox '{name}' is running ('acq ls'), then retry")
    try:
        forward = _spawn(_ssh_argv(sport, host, guest))
    except BaseException:
        _stop(serve)
        raise
    time.sleep(_settle("ACQ_MSB_FORWARD_SETTLE", 1.0))
    problem = None
    if forward.poll() is not None:
        problem = (f"ports: ssh -L 127.0.0.1:{host} -> 127.0.0.1:{guest} failed to establish "
                   "(forward rejected, auth failed, or bind in use)")
    elif not _listener_ready(host):
        problem = f"ports: ssh -L did not open host listener 127.0.0.1:{host}"
    if problem is not None:
        _stop(forward)
        _stop(serve)
        raise PublishError(errors.FAILURE, problem, f"check that host port {host} is free, then retry")
    return Tunnel(serve.pid, forward.pid, sport, host, guest)


def publish_posthoc(name: str, mappings: list[str], serve_cmd: list[str],
                    authorize: Callable[[Path], bool], run: Callable[[list[str]], int]) -> list[Tunnel]:
    """Open one tunnel per ``HOST:GUEST`` (already validated) and record them all.

    All or nothing: if one cannot be opened, the ones this call opened are
    stopped and nothing is recorded. ``authorize`` seats the public key with
    ``msb ssh authorize`` (on every publish: msb's authorized keys can vanish
    independently of acq's state); ``run`` runs a host command for its status.
    """
    path = pidfile(name)
    if path is None:
        raise PublishError(errors.VALIDATION_FAILED, f"ports: refusing unsafe sandbox name '{name}' for state path",
                           "use a sandbox name of letters, digits, '_' and '-'")
    _ensure_key(run)
    if not authorize(Path(f"{ssh_key()}.pub")):
        raise PublishError(errors.FAILURE, "ports: 'msb ssh authorize' failed for the acq tunnel key",
                           "check msb logs and retry")
    opened: list[Tunnel] = []
    try:
        for mapping in mappings:
            host, guest = (int(p) for p in mapping.split(":", 1))
            opened.append(_open_tunnel(name, serve_cmd, host, guest))
        _record(path, opened)
    except BaseException:
        for tunnel in opened:
            _kill(tunnel.ssh_pid)
            _kill(tunnel.serve_pid)
        raise
    return opened


def _record(path: Path, tunnels: list[Tunnel]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8", newline="\n") as fh:
        fh.write("".join(t.line() for t in tunnels))


def _lines(name: str, *, quiet: bool = False) -> tuple[Path | None, list[list[str]]]:
    if quiet and (not _PIDFILE_NAME.fullmatch(name) or name.startswith("-")):
        return None, []
    path = pidfile(name)
    if path is None:
        return None, []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return path, []
    return path, [line.split(None, 3) for line in text.splitlines() if line.strip()]


def posthoc_ports(name: str) -> list[dict]:
    """The recorded post-hoc mappings (``origin: "post-hoc"``); never their health."""
    out = []
    for fields in _lines(name, quiet=True)[1]:
        if len(fields) < 4:
            continue
        host, sep, guest = fields[3].strip().partition(":")
        if sep and host.isascii() and host.isdigit() and guest.isascii() and guest.isdigit():
            out.append({"host_port": int(host), "guest_port": int(guest), "origin": "post-hoc"})
    return out


def teardown(name: str) -> None:
    """Stop the sandbox's recorded tunnels and drop the record (Bash ``_acq_msb_ports_teardown``).

    Best-effort: a dead process or a missing record is not an error.
    """
    path, lines = _lines(name, quiet=True)
    if path is None:
        return
    for fields in lines:
        for token in fields[:2]:
            if token.isascii() and token.isdigit():
                _kill(int(token))
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        print(f"acq(msb): warning: could not remove the port record {path}", file=sys.stderr)
