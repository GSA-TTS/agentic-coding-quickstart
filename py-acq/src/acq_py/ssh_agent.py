"""Host ssh-agent (and host socket) forwarding into an msb guest (ADR-0021).

A port of the Bash implementation: the neutral emitter ``acq_host_socket_forwards``
in ``acq.backends/common.sh`` and its msb consumer in ``acq.backends/msb.sh``.

* The opt-in is the host's ``SSH_AUTH_SOCK``: when it names an existing socket,
  the agent is forwarded; unsetting it is the opt-out (there is no flag, as on
  sbx, whose CLI forwards the agent itself). ``ACQ_FORWARD_HOST_SOCKETS`` adds
  arbitrary host sockets (``PATH:PORT[/stream|/dgram][,...]``).
* At create, each forward becomes ``msb create --vsock HOST:PORT/KIND``. The
  agent's route names a per-sandbox symlink acq owns
  (``$ACQ_STATE_DIR/msb/ssh-agent/<name>.sock``), pointed at the agent socket and
  re-pointed before every bridge (re)start, so the route survives a host reboot
  that moves the agent (the ADR-0021 amendment).
* git and ssh in the guest speak a unix socket, so an in-guest ``socat`` bridge
  re-exposes the vsock route at the guest socket path. The bridge dies when the
  sandbox stops, so it is restarted on ``start``/``restart`` and re-driven on a
  re-attach. The guest path is recorded host-side (the ``ssh-auth-sock``
  host-config key, ADR-0035), where every session reads it as
  ``SSH_AUTH_SOCK``.

Every message is the Bash adapter's text, so both implementations tell the user
the same thing. Every path and port that reaches an ``msb`` argument or an
in-guest ``sh -c`` string is validated first (SI-10).
"""

from __future__ import annotations

import os
import re
import stat
import sys
from dataclasses import dataclass

from . import backends, kit_msb, lock, msb, security, state, userdirs

DEFAULT_GUEST_SOCK = "/home/agent/.acq/ssh-agent.sock"
DEFAULT_VSOCK_PORT = "3552"
# --vsock first shipped in msb 0.6.9. The global floor is the same today; the
# feature keeps its own gate so a lower floor could never pass an unknown flag.
MIN_VSOCK_VERSION = backends.Version(0, 6, 9, True)
# msb connect()s to the route path, so it must fit a sockaddr_un: 104 bytes on
# macOS including the terminator (108 on Linux). Budget for the smaller one.
SUN_PATH_MAX = 103
# The guest timeout for each bridge step and probe. Bash has none; a bounded
# call keeps a wedged msb from hanging the verb.
GUEST_TIMEOUT_S = 60.0
HOST_CONFIG_KEY = "ssh-auth-sock"
LABEL_AGENT = "ssh-agent"
LABEL_CUSTOM = "custom"
# Module-local seam for the host OS class (as ``msb.WINDOWS``).
WINDOWS = os.name == "nt"

_SAFE_GUEST_SOCK = re.compile(r"/[A-Za-z0-9._/-]*")
_SAFE_NAME = re.compile(r"[A-Za-z0-9_-]+")
_ASCII_DIGITS = re.compile(r"[0-9]+")
_VSOCK_PORT_MAX = 4294967294  # u32 max minus one: msb's upper bound
_VSOCK_PORT_RESERVED = 123  # reserved by msb

_NOTICE = (
    "acq(msb): forwarding your host ssh-agent into the guest because SSH_AUTH_SOCK"
    " is set. Guest code can use every key the agent holds while the sandbox runs;"
    " unset SSH_AUTH_SOCK to opt out, or run 'ssh-add -c' to confirm each use. See ADR-0021."
)
_NAME_RULE = "the name must use only letters, digits, '_' and '-', not start with '-'"

# Process-scoped state, as the Bash adapter's module flags: one acq command is
# one process. ``_ACTIVE`` holds the sandboxes whose forward this process wired
# (an emitted create-time route, or a re-drive that found the route), so their
# bridge uses the guest socket constant and their agent-user kit commands get
# ``SSH_AUTH_SOCK``. The notice prints at most once per process.
_ACTIVE: set[str] = set()
_NOTICE_SHOWN = [False]


def _say(message: str) -> None:
    print(message, file=sys.stderr)


@dataclass(frozen=True)
class Forward:
    """One requested host->guest socket forward (``HOST_PATH<TAB>PORT<TAB>KIND<TAB>LABEL`` in Bash)."""

    path: str
    port: str
    kind: str
    label: str


# ---------------------------------------------------------------------------
# Tunables (msb.sh constants).
# ---------------------------------------------------------------------------


def route_port() -> str:
    """The guest vsock port the emitter routes the agent to (``ACQ_SSH_AGENT_VSOCK_PORT``)."""
    return (os.environ.get("ACQ_SSH_AGENT_VSOCK_PORT") or os.environ.get("ACQ_MSB_SSH_AGENT_VSOCK_PORT")
            or DEFAULT_VSOCK_PORT)


def bridge_port() -> str:
    """The port the bridge connects to and the route probe looks for (``ACQ_MSB_SSH_AGENT_VSOCK_PORT``).

    Each name falls back to the other, so a single override keeps the route
    and the bridge in lockstep, as in Bash.
    """
    return (os.environ.get("ACQ_MSB_SSH_AGENT_VSOCK_PORT") or os.environ.get("ACQ_SSH_AGENT_VSOCK_PORT")
            or DEFAULT_VSOCK_PORT)


def guest_sock() -> str:
    """The guest socket the bridge listens on (``ACQ_MSB_SSH_AGENT_GUEST_SOCK``).

    It is spliced into an in-guest ``sh -c`` string, so an override that is not
    an absolute path in a word-safe charset is refused with the Bash warning and
    the default is used.
    """
    value = os.environ.get("ACQ_MSB_SSH_AGENT_GUEST_SOCK") or DEFAULT_GUEST_SOCK
    if not value.startswith("/"):
        _say(f"acq(msb): warning: ignoring non-absolute ACQ_MSB_SSH_AGENT_GUEST_SOCK='{value}'; using default.")
        return DEFAULT_GUEST_SOCK
    if not _SAFE_GUEST_SOCK.fullmatch(value):
        _say(f"acq(msb): warning: ignoring unsafe ACQ_MSB_SSH_AGENT_GUEST_SOCK='{value}'; using default.")
        return DEFAULT_GUEST_SOCK
    return value


def valid_vsock_port(port: str) -> bool:
    """``_acq_valid_vsock_port``: ASCII digits, 1..4294967294, and not msb's reserved 123."""
    if not _ASCII_DIGITS.fullmatch(port):
        return False
    return 1 <= int(port) <= _VSOCK_PORT_MAX and int(port) != _VSOCK_PORT_RESERVED


def _has_ctl(path: str) -> bool:
    """A TAB or newline would corrupt Bash's TAB-separated forward records, so both refuse it."""
    return "\t" in path or "\n" in path


def is_socket(path: str) -> bool:
    """``[ -S PATH ]``: an existing socket, following symlinks.

    Always False on a Windows host, so nothing is forwarded from one: an MSYS
    ssh-agent's socket is an emulation file there, the OpenSSH agent is a named
    pipe, and neither can be a route msb dials (the managed link would also need
    a symlink privilege). The forward then takes the "not a socket" skip.
    """
    if WINDOWS:
        return False
    try:
        return stat.S_ISSOCK(os.stat(path).st_mode)
    except (OSError, ValueError):
        return False


def _canonical(path: str) -> str:
    """``canonicalize_path``: the real, symlink-free form, or the input when it cannot be resolved."""
    try:
        return os.path.realpath(path)
    except (OSError, ValueError):
        return path


# ---------------------------------------------------------------------------
# The neutral emitter (common.sh acq_host_socket_forwards).
# ---------------------------------------------------------------------------


def _agent_forward(say) -> Forward | None:
    sock = os.environ.get("SSH_AUTH_SOCK", "")
    if not sock:
        return None
    if not is_socket(sock):
        say("acq: SSH_AUTH_SOCK is set but not a socket; skipping ssh-agent forwarding")
        return None
    path, port = _canonical(sock), route_port()
    if not valid_vsock_port(port):
        say(f"acq: ACQ_SSH_AGENT_VSOCK_PORT {port} is invalid (need 1..4294967294, != 123); "
            "skipping ssh-agent forwarding")
    elif _has_ctl(path):
        say("acq: SSH_AUTH_SOCK path contains a tab/newline; skipping ssh-agent forwarding")
    elif not path.startswith("/"):
        say("acq: SSH_AUTH_SOCK path is not absolute; skipping ssh-agent forwarding")
    else:
        return Forward(path, port, "stream", LABEL_AGENT)
    return None


def _custom_forward(entry: str, say) -> Forward | None:
    kind, spec = "stream", entry
    for suffix in ("stream", "dgram"):
        if spec.endswith("/" + suffix):
            kind, spec = suffix, spec[: -len(suffix) - 1]
            break
    path, sep, port = spec.rpartition(":")
    if not sep:
        say(f"acq: malformed host-socket forward {entry} (expected PATH:PORT); skipping")
        return None
    # Checked as given, before canonicalizing: a relative path would resolve
    # against the current directory, normally the agent-writable workspace.
    if not userdirs.is_absolute(path):
        say(f"acq: host-socket path {path} is not absolute; skipping")
        return None
    path = _canonical(path)
    if not path.startswith("/"):
        say(f"acq: host-socket path {path} is not absolute; skipping")
    elif _has_ctl(path):
        say("acq: host-socket path contains a tab/newline; skipping")
    elif not is_socket(path):
        say(f"acq: host-socket path {path} is not an existing socket; skipping")
    elif not valid_vsock_port(port):
        say(f"acq: host-socket port {port} is invalid (need 1..4294967294, != 123); skipping")
    else:
        return Forward(path, port, kind, LABEL_CUSTOM)
    return None


def host_socket_forwards(*, quiet: bool = False) -> list[Forward]:
    """The requested forwards: the host agent first, then ``ACQ_FORWARD_HOST_SOCKETS``.

    An entry that fails validation is skipped with a warning (``quiet``
    suppresses them, as the Bash re-drive does) and never aborts the caller.
    """
    say = (lambda _message: None) if quiet else _say
    out = []
    agent = _agent_forward(say)
    if agent is not None:
        out.append(agent)
    for entry in os.environ.get("ACQ_FORWARD_HOST_SOCKETS", "").split(","):
        if entry:
            fwd = _custom_forward(entry, say)
            if fwd is not None:
                out.append(fwd)
    return out


# ---------------------------------------------------------------------------
# The managed route link (ADR-0021 amendment).
# ---------------------------------------------------------------------------


def link_path(name: str) -> str | None:
    """The managed route link for ``name``, or ``None`` when no safe, connectable path exists.

    The name reaches a host path acq links and removes, so only the charset acq
    itself gives sandbox names is accepted. When ``<dir>/<name>.sock`` would not
    fit a socket address, a short ``h<cksum>.sock`` (the POSIX ``cksum`` of the
    name, as Bash computes it) is used instead.
    """
    if not _SAFE_NAME.fullmatch(name) or name.startswith("-"):
        return None
    try:
        base = state.state_dir()
    except userdirs.UserDirError:
        return None
    link_dir = f"{base}/msb/ssh-agent"
    path = f"{link_dir}/{name}.sock"
    if len(path.encode("utf-8")) > SUN_PATH_MAX:
        path = f"{link_dir}/h{lock.posix_cksum(name.encode('utf-8'))}.sock"
        if len(path.encode("utf-8")) > SUN_PATH_MAX:
            return None
    return path


def link_point(link: str, target: str) -> bool:
    """Make ``link`` a symlink to the socket ``target``; True when it ends up there.

    Atomic: a fresh link is made beside it and renamed over it, so msb dialing
    the route mid-swap never finds it missing. Anything at ``link`` that is not
    a symlink is never replaced.
    """
    if not is_socket(target):
        return False
    if os.path.exists(link) and not os.path.islink(link):
        return False
    if os.path.islink(link) and os.readlink(link) == target:
        return True
    try:
        os.makedirs(os.path.dirname(link), exist_ok=True)
        if os.path.islink(link) and os.path.isdir(link):
            os.unlink(link)  # a rename would land inside the directory it resolves to
    except OSError:
        return False
    tmp = f"{link}.tmp.{os.getpid()}"
    _unlink_quietly(tmp)
    try:
        os.symlink(target, tmp)
        if os.path.islink(tmp):
            os.replace(tmp, link)
            return True
    except OSError:
        pass
    _unlink_quietly(tmp)
    return False


def _unlink_quietly(path: str) -> None:
    try:
        if os.path.islink(path) or os.path.isfile(path):
            os.unlink(path)
    except OSError:
        pass


def route_path(name: str, agent: str) -> str:
    """The host path the agent's ``--vsock`` route names: the managed link, else ``agent`` with a warning."""
    link = link_path(name)
    if link is not None:
        if link_point(link, agent):
            return link
        why = f"the link '{link}' could not be created (is its directory writable, and is nothing else at that path?)"
    else:
        why = f"{_NAME_RULE}, and the link path must fit a unix socket address"
    _say(f"acq(msb): warning: cannot manage the ssh-agent route for sandbox '{name}': {why}. Routing the raw "
         "agent socket path, which goes stale when the host agent moves (e.g. after a reboot). See ADR-0021.")
    return agent


def link_refresh(name: str) -> str:
    """Re-point an existing managed link at the current ``SSH_AUTH_SOCK``; why it was left alone, or "".

    A sandbox without a link (created before the link existed, or under a name
    that cannot carry one) is left as it is, and so is the link when
    ``SSH_AUTH_SOCK`` is not a socket here. Never fails the caller.
    """
    link = link_path(name)
    if link is None or not os.path.islink(link):
        return ""
    target = os.environ.get("SSH_AUTH_SOCK", "")
    if not target or not is_socket(target):
        return (f"SSH_AUTH_SOCK is unset or not a socket in this shell. Re-run 'acq start {name}' or "
                f"'acq run {name}' from a shell where SSH_AUTH_SOCK names your live agent (e.g. after "
                "'eval \"$(ssh-agent -s)\"; ssh-add').")
    target = _canonical(target)
    if link_point(link, target):
        return ""
    _say(f"acq(msb): warning: could not re-point the ssh-agent route link '{link}' at '{target}'; "
         f"the forwarded agent may be unreachable in '{name}'.")
    return (f"the link could not be replaced. Fix or remove '{link}' (is its directory writable, and is it "
            f"still a symlink?), then re-run 'acq start {name}' or 'acq run {name}'.")


def link_managed(name: str) -> bool:
    link = link_path(name)
    return link is not None and os.path.islink(link)


def link_remove(name: str) -> None:
    """Drop the sandbox's managed link (the link only, never the agent socket behind it)."""
    link = link_path(name)
    if link is not None and os.path.islink(link):
        _unlink_quietly(link)


# ---------------------------------------------------------------------------
# Create-time route (_acq_msb_vsock_flags_into).
# ---------------------------------------------------------------------------


def _vsock_supported() -> bool:
    status = backends.detect(backends.BACKENDS["msb"])
    if status.parsed is not None and backends.version_ge(status.parsed, MIN_VSOCK_VERSION):
        return True
    _say(f"acq(msb): host ssh-agent/socket forwarding needs msb >= {MIN_VSOCK_VERSION.string} "
         f"(found {status.version or 'unknown'}); skipping. Upgrade msb to forward the host ssh-agent "
         "into the guest.")
    return False


def vsock_flags(name: str) -> list[str]:
    """``msb create`` ``--vsock`` flags for the requested forwards, and mark ``name`` active.

    Called once per create. Nothing is emitted (with a warning) on an msb too
    old for ``--vsock``: forwarding is opt-in convenience and never fails a
    create.
    """
    _ACTIVE.discard(name)
    forwards = host_socket_forwards()
    if not forwards or not _vsock_supported():
        return []
    flags: list[str] = []
    for fwd in forwards:
        path = route_path(name, fwd.path) if fwd.label == LABEL_AGENT else fwd.path
        flags += ["--vsock", f"{path}:{fwd.port}/{fwd.kind}"]
        if fwd.label == LABEL_AGENT:
            _ACTIVE.add(name)
            if not _NOTICE_SHOWN[0]:
                _NOTICE_SHOWN[0] = True
                _say(_NOTICE)
    return flags


def forwarding_sock(name: str) -> str | None:
    """The guest socket agent-user kit commands get as ``SSH_AUTH_SOCK``, when this process wired the forward."""
    return guest_sock() if name in _ACTIVE else None


# ---------------------------------------------------------------------------
# The in-guest bridge (_acq_msb_check_socat, _acq_msb_start_ssh_agent_bridge).
# ---------------------------------------------------------------------------

_SOCAT_CHECK = "command -v socat >/dev/null 2>&1"
_SSH_ADD_CHECK = "command -v ssh-add >/dev/null 2>&1"


def bridge_script(sock: str, port: str) -> str:
    """The bridge's ``sh -c`` string, byte for byte the Bash adapter's.

    Both values are validated before they are spliced in. One detached socat,
    relaunched fresh on each (re)start; ``rm -f`` clears a stale socket first.
    """
    return (
        "\n"
        f"    mkdir -p \"$(dirname '{sock}')\" 2>/dev/null || true\n"
        f"    rm -f '{sock}' 2>/dev/null || true\n"
        f"    nohup socat UNIX-LISTEN:'{sock}',fork,reuseaddr VSOCK-CONNECT:2:'{port}' >/dev/null 2>&1 &\n"
        "  "
    )


def probe_script(sock: str) -> str:
    """The liveness probe's ``sh -c`` string (three tries 0.3s apart, then the last answer)."""
    return (f"for _i in 1 2 3; do SSH_AUTH_SOCK='{sock}' ssh-add -l 2>&1 && exit 0; sleep 0.3; done; "
            f"SSH_AUTH_SOCK='{sock}' ssh-add -l 2>&1")


def _ok(proc) -> bool:
    return proc is not None and proc.returncode == 0


def check_socat(name: str) -> bool:
    """True when socat is in the guest; otherwise warn (it is never installed: egress is locked)."""
    if _ok(msb.call(["exec", name, "--", "sh", "-c", _SOCAT_CHECK], timeout=GUEST_TIMEOUT_S)):
        return True
    _say("acq(msb): warning: socat not found in the guest; host ssh-agent forwarding needs socat to bridge "
         "the vsock route to a unix socket. Bake socat into ACQ_MSB_IMAGE. git signing will fail until then.")
    return False


def recorded_sock(name: str) -> str | None:
    """The guest socket recorded host-side for ``name`` (whitespace dropped, as Bash reads it), or ``None``.

    Only an absolute path in the word-safe charset is accepted: it is spliced
    into in-guest ``sh -c`` strings and session environments.
    """
    try:
        raw = (security.host_config_dir(name) / HOST_CONFIG_KEY).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    value = "".join(raw.split())
    return value if _SAFE_GUEST_SOCK.fullmatch(value) else None


def start_bridge(name: str) -> None:
    """(Re)start the bridge, record the guest socket, then probe the forwarded agent.

    The socket is the constant when this process wired the forward, else the
    one recorded host-side; with neither, forwarding was never set up and
    nothing runs. The host end of the route is healed first (:func:`link_refresh`).
    Fail-soft: every problem is a warning.
    """
    sock = guest_sock() if name in _ACTIVE else recorded_sock(name)
    if sock is None:
        return
    skipped = link_refresh(name)
    port = bridge_port()
    if not valid_vsock_port(port):
        _say(f"acq(msb): warning: ACQ_MSB_SSH_AGENT_VSOCK_PORT {port} is invalid (need 1..4294967294, != 123); "
             f"the ssh-agent bridge was not started in '{name}'.")
        return
    proc = msb.call(["exec", name, "-u", "agent", "--", "sh", "-c", bridge_script(sock, port)],
                    timeout=GUEST_TIMEOUT_S)
    if not _ok(proc):
        _say(f"acq(msb): warning: failed to start the ssh-agent bridge in '{name}'.")
        return
    try:
        kit_msb.hc_write(name, HOST_CONFIG_KEY, sock)
    except (OSError, ValueError):
        pass
    warn_if_unreachable(name, sock, skipped)


def provision_bridge(name: str) -> None:
    """After a create applied its kits: the socat check, then the bridge, when the forward was wired."""
    if name in _ACTIVE and check_socat(name):
        start_bridge(name)


# ---------------------------------------------------------------------------
# Liveness probe (_acq_msb_warn_if_agent_unreachable).
# ---------------------------------------------------------------------------


def warn_if_unreachable(name: str, sock: str, skipped: str = "") -> bool:
    """Probe the forwarded agent from the guest; warn with the matching remedy when it does not answer.

    Returns True when it is reachable or cannot be probed (no ``ssh-add`` in the
    guest), False when it warned. The exit status alone cannot tell a dead
    bridge from an empty agent (both exit 1), so the message decides: exit 0 or
    "no identities" is healthy, anything else is unreachable.
    """
    if not _ok(msb.call(["exec", name, "-u", "agent", "--", "sh", "-c", _SSH_ADD_CHECK], timeout=GUEST_TIMEOUT_S)):
        return True
    proc = msb.call(["exec", name, "-u", "agent", "--", "sh", "-c", probe_script(sock)], timeout=GUEST_TIMEOUT_S)
    if _ok(proc):
        return True
    if proc is not None and "no identities" in (proc.stdout or ""):
        return True
    if link_managed(name):
        _say(_managed_unreachable(name, skipped))
    else:
        _say(_raw_unreachable(name))
    return False


def _managed_unreachable(name: str, skipped: str) -> str:
    link = link_path(name) or ""
    try:
        target = os.readlink(link)
    except OSError:
        target = ""
    if skipped:
        state_text = f"was NOT re-pointed because {skipped}"
    else:
        state_text = ("was just re-pointed at the current SSH_AUTH_SOCK, so the host agent itself is probably not "
                      "answering (check 'ssh-add -l' on the host) or the in-guest socat bridge failed. Fix the host "
                      f"agent, then re-run 'acq start {name}' or 'acq run {name}'.")
    return (f"acq(msb): warning: the forwarded host ssh-agent is UNREACHABLE from the guest in '{name}'. Its "
            f"--vsock route follows acq's managed link '{link}' -> '{target}', which {state_text} "
            "See ADR-0021 / docs/KNOWN_FAILURE_MODES.md §35.")


def _raw_unreachable(name: str) -> str:
    if link_path(name) is not None:
        after = ("The recreated sandbox routes through a link acq re-points on every start, so this is a one-time "
                 "recreate: you only do it once.")
    else:
        after = (f"This sandbox cannot carry acq's managed route link ({_NAME_RULE}, and the link path under "
                 "ACQ_STATE_DIR must fit a unix socket address); recreate under a name and state dir that allow it "
                 "to get a route that survives reboots.")
    return (f"acq(msb): warning: the forwarded host ssh-agent is UNREACHABLE from the guest in '{name}' (the "
            "create-time --vsock route's host endpoint is stale — most commonly after a HOST REBOOT, which gives "
            "the host ssh-agent a new socket path while the sandbox keeps the old one). SSH_AUTH_SOCK is set but "
            "git signing will fail. This sandbox routes the raw agent path, which is create-time only, so recreate "
            f"it: 'acq rm {name}' then re-run your 'acq run …' (with SSH_AUTH_SOCK set). {after} "
            "See ADR-0021 / docs/KNOWN_FAILURE_MODES.md §35.")


# ---------------------------------------------------------------------------
# Re-attach re-drive (_acq_msb_ensure_ssh_agent_forward).
# ---------------------------------------------------------------------------

ROUTE_PRESENT, ROUTE_MISSING, ROUTE_UNKNOWN = 0, 1, 2
_FLATTEN = str.maketrans({",": "\n", "{": "\n", "}": "\n", "[": "\n", "]": "\n", '"': None, " ": None})


def has_route(name: str) -> int:
    """Whether the sandbox's persisted config carries the agent's ``--vsock`` route.

    Read from ``msb inspect NAME --format json`` (two tries). Both a ``vsock``
    key and the agent port must appear, so a published port that merely equals
    it is not mistaken for a route. :data:`ROUTE_UNKNOWN` when inspect failed or
    printed nothing twice: that says nothing about the route.
    """
    doc = ""
    for _try in range(2):
        proc = msb.call(["inspect", name, "--format", "json"], timeout=GUEST_TIMEOUT_S)
        doc = (proc.stdout or "").rstrip("\n") if _ok(proc) and proc is not None else ""
        if doc:
            break
    if not doc:
        return ROUTE_UNKNOWN
    flat = doc.translate(_FLATTEN)
    if not re.search(r"(^|:)vsock:?$", flat, re.MULTILINE):
        return ROUTE_MISSING
    pattern = rf"port[:=]{re.escape(bridge_port())}$"
    return ROUTE_PRESENT if re.search(pattern, flat, re.MULTILINE) else ROUTE_MISSING


def ensure_forward(name: str) -> str | None:
    """Re-establish the forward on a sandbox acq is healing; the guest socket when it is wired.

    A no-op unless the host requests an agent forward AND the sandbox carries
    the create-time route (it cannot be added later, and a bridge without it
    would advertise a dead agent). When both hold, the forward is active for
    this process (so kit commands get ``SSH_AUTH_SOCK``), then the socat check
    and the bridge run as on create. Fail-soft throughout.
    """
    if not any(f.label == LABEL_AGENT for f in host_socket_forwards(quiet=True)):
        return None
    route = has_route(name)
    if route == ROUTE_UNKNOWN:
        # Bash appends msb's own stderr here; acq-py never surfaces raw backend
        # text (ADR-0040m), so the warning names the failed call only.
        _say(f"acq(msb): warning: could not verify the ssh-agent --vsock route for '{name}' (msb inspect failed); "
             "continuing without ssh-agent forwarding for this run.")
        return None
    if route == ROUTE_MISSING:
        _say(f"acq(msb): warning: host SSH_AUTH_SOCK is set, but existing sandbox '{name}' has no ssh-agent --vsock "
             "route. The route is create-time only, so SSH_AUTH_SOCK will not be set in the guest and git signing "
             "will fail.")
        _say(f"acq(msb):   If this sandbox was recreated with the same name after wiping msb state, remove it with "
             f"'acq rm {name}' and re-run 'acq run …' with SSH_AUTH_SOCK set so acq can create the route. "
             "See ADR-0021.")
        return None
    _ACTIVE.add(name)
    if check_socat(name):
        start_bridge(name)
    return guest_sock()

