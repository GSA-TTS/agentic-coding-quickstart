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

import ipaddress
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
from dataclasses import dataclass, field
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

    def kept(self, host: int, guest: str) -> bool:
        """Whether a recreate's preferred host port is still usable (never a hard failure)."""
        status = "busy" if host in self.taken else host_port_status(host)
        if status == "unknown":
            self.unprobed()
        if status == "busy":
            print(f"acq(msb): warning: host port {host}, which guest port {guest} had before the recreate, "
                  "is in use now; a free port is chosen instead.", file=sys.stderr)
            return False
        return True

    def chosen(self, guest: str) -> int | None:
        port, status = pick_free_host_port(self.taken)
        if port is None:
            self.problems.append(f"could not find a free host port for guest port {guest}")
            return None
        if status == "unknown":
            self.unprobed()
        return port


def create_port_flags(name: str, kits: Iterable, overrides: list[str],
                      preferred: dict[str, int] | None = None) -> tuple[list[str], list[dict]]:
    """``msb create`` ``-p HOST:GUEST`` flags and the mappings they declare.

    ``preferred`` maps a guest port to the host port a recreated sandbox had.
    It applies only where a kit still declares that guest port and leaves the
    host side open, so a host port a kit pins is never overridden; when the
    preferred port is busy, a free one is chosen with a warning. Raises
    :class:`PublishError` when a port cannot be mapped; the create must not go
    ahead without a mapping the kit or the user asked for.
    """
    preferred = preferred or {}
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
        if host or guest not in preferred:
            continue
        if mapper.kept(preferred[guest], guest):
            hosts[guest] = preferred[guest]
            mapper.taken.append(preferred[guest])
    for guest, host in records:
        port = None if host or guest in hosts else mapper.chosen(guest)
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


_LOOPBACK_NAMES = frozenset({"localhost"})


def sbx_bind_problem(value: str) -> str | None:
    """A reason to refuse an sbx ``--publish`` value that binds a non-loopback host address.

    sbx's values may name the host address (``IP:HOST:GUEST``, IPv6 in brackets).
    acq publishes on loopback only, as Bash's msb path does, so any other
    address is refused before sbx sees it. Values without an address are sbx's
    to judge.
    """
    if value.startswith("["):
        addr, sep, _rest = value[1:].partition("]")
        if not sep:
            return f"ports: --publish '{value}' has an unterminated IPv6 address"
    else:
        parts = value.split(":")
        if len(parts) < 3:
            return None
        addr = ":".join(parts[:-2])
    if addr.lower() in _LOOPBACK_NAMES:
        return None
    try:
        if ipaddress.ip_address(addr).is_loopback:
            return None
    except ValueError:
        pass
    return f"ports: --publish '{value}' binds host address '{addr}'; acq publishes on loopback only"


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


# The programs a recorded tunnel process can be: ``msb ssh serve`` and ``ssh -L``.
_TUNNEL_PROGRAMS = frozenset({"msb", "ssh"})


def _program(path: str) -> str:
    base = path.replace("\\", "/").rsplit("/", 1)[-1].lower()
    return base[:-4] if base.endswith(".exe") else base


def _linux_identity(pid: int) -> bool | None:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except FileNotFoundError:
        return False  # no such process: nothing to stop
    except OSError:
        return None
    return any(_program(token.decode("utf-8", "replace")) in _TUNNEL_PROGRAMS for token in raw.split(b"\0") if token)


def _macos_identity(pid: int) -> bool | None:
    try:
        proc = subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(pid)],  # nosec B603 # fixed argv, no shell
                              capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    comm = proc.stdout.strip()
    if proc.returncode != 0 and not comm:
        return False  # ps lists nothing: no such process
    return _program(comm) in _TUNNEL_PROGRAMS if comm else None


def _windows_identity(pid: int) -> bool | None:  # pragma: no cover - Windows only
    if sys.platform != "win32":
        return None
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    kernel32.QueryFullProcessImageNameW.argtypes = (wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                                    ctypes.POINTER(wintypes.DWORD))
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        # ERROR_INVALID_PARAMETER: no process has that id.
        return False if ctypes.get_last_error() == 87 else None
    try:
        size = wintypes.DWORD(32768)
        buf = ctypes.create_unicode_buffer(size.value)
        if not kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            return None
        return _program(buf.value) in _TUNNEL_PROGRAMS
    finally:
        kernel32.CloseHandle(handle)


def process_is_tunnel(pid: int) -> bool | None:
    """Whether ``pid`` is an ``msb`` or ``ssh`` process now; ``None`` when that cannot be told.

    A recorded process id can be reused by an unrelated process once the
    tunnel is gone, so it is checked before it is signalled: on Linux the
    command line (``/proc/PID/cmdline``), on macOS ``ps -o comm=``, on Windows
    the image name (``QueryFullProcessImageNameW``). ``False`` also covers a
    process that no longer exists.
    """
    if sys.platform.startswith("linux"):
        return _linux_identity(pid)
    if sys.platform == "darwin":
        return _macos_identity(pid)
    if os.name == "nt":
        try:
            return _windows_identity(pid)
        except (OSError, AttributeError, ValueError):
            return None
    return None


def _signal(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGTERM)
    except (OSError, ValueError):
        pass


def _kill_recorded(name: str, pid: int) -> None:
    """Stop a process the tunnel record names, once it is confirmed to be a tunnel process.

    Never pid 0 or 1 (a process group or init). On Windows ``os.kill`` is
    TerminateProcess, so the identity check matters as much there.
    """
    if pid <= 1:
        return
    verdict = process_is_tunnel(pid)
    if verdict is None:
        print(f"acq(msb): note: not stopping process {pid} from the port record of '{name}': "
              "acq could not confirm it is an msb or ssh process.", file=sys.stderr)
    elif verdict:
        _signal(pid)


def _stop(proc: subprocess.Popen) -> None:
    """Stop a process this acq started (its own child, so its id cannot have been reused)."""
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except (subprocess.TimeoutExpired, OSError):
        pass


def _ensure_key(run: Callable[[list[str]], int]) -> None:
    key = ssh_key()
    if key.is_file():
        return
    # As Bash: the acq ssh directory is made 0700, wherever ACQ_MSB_SSH_KEY points.
    ssh_dir = _ssh_dir()
    ssh_dir.mkdir(parents=True, exist_ok=True)
    try:
        ssh_dir.chmod(0o700)
    except OSError:
        pass
    key.parent.mkdir(parents=True, exist_ok=True)
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


def _ssh_path_value(path: Path, *, quoted: bool) -> str:
    """A path as ssh reads it from an option: ``%`` doubled (ssh expands ``%`` tokens) and,
    for a ``-o`` value, double-quoted with ``\\`` and ``"`` escaped, so a space or a UNC
    path survives ssh's option tokenizer."""
    text = str(path).replace("%", "%%")
    if not quoted:
        return text
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _ssh_argv(name: str, sport: int, host: int, guest: int) -> list[str]:
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
    # The host key is pinned per sandbox (HostKeyAlias), not per ephemeral serve port.
    return [*ssh, "-p", str(sport), "-N", "-n", "-F", "none", "-i", _ssh_path_value(ssh_key(), quoted=False),
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0",
            "-o", "StrictHostKeyChecking=accept-new", "-o", f"HostKeyAlias=acq-msb-{name}",
            "-o", f"UserKnownHostsFile={_ssh_path_value(_known_hosts(), quoted=True)}",
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
    procs: tuple = field(default=(), compare=False, repr=False)  # this acq's own children

    def line(self) -> str:
        return f"{self.serve_pid} {self.ssh_pid} {self.serve_port} {self.host}:{self.guest}\n"

    def mapping(self) -> dict:
        return {"host_port": self.host, "guest_port": self.guest, "origin": "post-hoc"}


def _open_tunnel(name: str, serve_cmd: list[str], host: int, guest: int) -> Tunnel:
    """Start the serve and the forward; on any failure, Ctrl-C in a settle sleep
    included, stop whatever this call already started."""
    spawned: list[subprocess.Popen] = []
    try:
        sport = pick_ephemeral_port()
        spawned.append(_spawn([*serve_cmd, "ssh", "serve", name, "--host", "127.0.0.1", "--port", str(sport)]))
        time.sleep(_settle("ACQ_MSB_SERVE_SETTLE", 1.0))
        if spawned[0].poll() is not None:
            raise PublishError(
                errors.FAILURE,
                f"ports: 'msb ssh serve' on 127.0.0.1:{sport} exited immediately (could not start listener)",
                f"check that sandbox '{name}' is running ('acq ls'), then retry")
        spawned.append(_spawn(_ssh_argv(name, sport, host, guest)))
        time.sleep(_settle("ACQ_MSB_FORWARD_SETTLE", 1.0))
        if spawned[1].poll() is not None:
            raise PublishError(errors.FAILURE, f"ports: ssh -L 127.0.0.1:{host} -> 127.0.0.1:{guest} failed to "
                               "establish (forward rejected, auth failed, or bind in use)",
                               f"check that host port {host} is free, then retry")
        if not _listener_ready(host):
            raise PublishError(errors.FAILURE, f"ports: ssh -L did not open host listener 127.0.0.1:{host}",
                               f"check that host port {host} is free, then retry")
    except BaseException:
        for proc in reversed(spawned):
            _stop(proc)
        raise
    serve, forward = spawned
    return Tunnel(serve.pid, forward.pid, sport, host, guest, (serve, forward))


def _free_host_ports(pairs: list[tuple[int, int]]) -> None:
    """Refuse a host port that is in use, or asked for twice, before anything is started.

    Without this an occupied port would pass the listener check (something
    answers there) while ssh's own bind failed.
    """
    seen: set[int] = set()
    for host, _guest in pairs:
        if host in seen:
            raise PublishError(errors.VALIDATION_FAILED, f"ports: host port {host} is requested more than once",
                               "give each --publish its own host port")
        seen.add(host)
        if host_port_status(host) == "busy":
            raise PublishError(errors.FAILURE, f"ports: host port {host} is already in use on 127.0.0.1",
                               "free it, or publish on another host port")


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
    pairs = [(int(h), int(g)) for h, g in (m.split(":", 1) for m in mappings)]
    _free_host_ports(pairs)
    _ensure_key(run)
    if not authorize(Path(f"{ssh_key()}.pub")):
        raise PublishError(errors.FAILURE, "ports: 'msb ssh authorize' failed for the acq tunnel key",
                           "check msb logs and retry")
    opened: list[Tunnel] = []
    try:
        for host, guest in pairs:
            opened.append(_open_tunnel(name, serve_cmd, host, guest))
        _record(path, opened)
    except BaseException:
        for tunnel in opened:
            for proc in reversed(tunnel.procs):
                _stop(proc)
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
                _kill_recorded(name, int(token))
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        print(f"acq(msb): warning: could not remove the port record {path}", file=sys.stderr)
