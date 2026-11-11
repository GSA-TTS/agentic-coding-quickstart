"""Apply neutral ``hybrid/v1`` kits to an msb sandbox (ADR-0011, ADR-0017, ADR-0033, ADR-0035).

A port of the Bash msb adapter's kit path (``acq.backends/msb.sh``):

* :func:`resolve` checks the packaged bundle against its manifest
  (:func:`kitspec.verify_bundle`) and parses every selected kit. A kit the
  bundle does not hold (an opt-in catalog kit, a remote extra or ``--kit``
  ref, a provider kit from a registered source) is fetched at its pinned
  commit and checked (:mod:`kit_fetch`), and a local kit directory is copied
  into the private cache and checked there; a ref that cannot be fetched or
  copied is refused before anything is created.
* :func:`create_flags` builds a kit set's create-time flags: the read-only
  host-config mount, the ``--script-path`` startup script
  (``_acq_msb_stage_startup_script``) and host CA trust for a kit whose
  ``backend_shortcuts.msb`` asks for it.
* :func:`ensure_kits_applied` applies each kit in order
  (``acq_backend_ensure_kits_applied``): its files, then its commands in
  declaration order with each phase's semantics and as the declared user, each
  with the merged kit environment (``_acq_msb_merge_kit_env_into``), which is
  also kept host-side for session replay.

Kit content is data: argv tokens and environment values travel as separate
``msb exec`` arguments or, in the startup script, single-quoted (SI-10). acq
never runs kit code on the host. Per-sandbox state lives in the sandbox's
host-config directory (:func:`security.host_config_dir`), laid out as Bash lays
it out, so that both implementations read the same markers.
"""

from __future__ import annotations

import os
import re
import shutil
import stat
import sys
import tempfile
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path

from . import (
    errors,
    kit_fetch,
    kitspec,
    legacy_bash,
    lock,
    msb,
    security,
    state,
    userdirs,
)

# Module-local seam for the host OS class (as ``msb.WINDOWS``).
WINDOWS = os.name == "nt"
STARTUP_SCRIPT_NAME = "acq-startup"
STARTUP_STAGE_DIR_ENV = "ACQ_MSB_STARTUP_STAGE_DIR"
KEEP_STARTUP_STAGE_ENV = "ACQ_MSB_KEEP_STARTUP_STAGE"
AGENT_HOME = "/home/agent"
GUARD_NAMES = ("GIT_TERMINAL_PROMPT", "GIT_ASKPASS", "SSH_ASKPASS")
_AGENT_USERS = ("1000", "agent")
_ROOT_USERS = ("0", "root")
_OCTAL = re.compile(r"[0-7]{3,4}")
_KEY = re.compile(r"[A-Za-z0-9._-]+")

# Host-config keys that describe one guest instance. They are cleared when a new
# guest is created under a name, so a stale marker from a sandbox removed outside
# acq never suppresses an install (Bash acq_host_config_clear_instance_state).
_INSTANCE_KEYS = ("agent-user-ready", "workspace", "ssh-auth-sock", "generic-opencode",
                  "extra-kits", "builtin-kits", "ro-host-config")
_INSTANCE_PREFIXES = ("install-", "agent-installed-")


@dataclass(frozen=True)
class Kit:
    """One selected kit, parsed from the bundle or fetched. ``role`` comes from :class:`kitspec.SelectedKit`.

    ``fetched`` marks a kit from outside the bundle, fetched at its pinned
    commit or copied from a local directory (:mod:`kit_fetch`): its egress
    allowlist comes from its own spec, not from the vetted built-in table.
    """

    name: str
    role: str
    spec: kitspec.KitSpec
    ref: str = ""
    fetched: bool = False

    @property
    def shortcut(self) -> bool:
        """``backend_shortcuts.msb`` is set: the native primitive replaces files and commands."""
        return self.spec.has_shortcut("msb")


@dataclass
class ApplyResult:
    """Which kits applied fully, and which did not (a warning was printed for each).

    ``agent_user`` is False when the agent user could not be set up first
    (:func:`ensure_agent_user`); the kits were still attempted, as in Bash's heal.
    """

    applied: list[str] = field(default_factory=list)
    incomplete: list[str] = field(default_factory=list)
    agent_user: bool = True


def _warn(message: str) -> None:
    print(f"acq: warning: {message}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Selection -> parsed kits.
# ---------------------------------------------------------------------------


def _bundle_problem() -> str | None:
    try:
        problems = kitspec.verify_bundle()
    except kitspec.KitSpecError as exc:
        return str(exc)
    return problems[0] if problems else None


def fetch_selected(sel: kitspec.SelectedKit, backend: str) -> Kit:
    """A kit outside the bundle, fetched at its pinned commit or copied from a local directory.

    Raises :class:`kit_fetch.KitFetchError`.
    """
    name, spec = kit_fetch.load(sel.ref, backend)
    return Kit(name, sel.role, spec, sel.ref, fetched=True)


def resolve(selection: kitspec.KitSelection) -> list[Kit]:
    """Verify the bundle, then parse every selected kit, fetching any the bundle does not hold.

    A kit outside the bundle is fetched at its pinned commit, or copied from
    its local directory, and checked (:func:`kit_fetch.load`); one that cannot
    be stops the caller, before anything is created. Raises :class:`msb.MsbError`.
    """
    problem = _bundle_problem()
    if problem is not None:
        raise msb.MsbError(
            errors.VALIDATION_FAILED,
            f"the built-in kit bundle does not match its pinned content ({problem})",
            "reinstall acq; it will not apply a kit bundle it cannot verify",
        )
    out: list[Kit] = []
    seen: set[str] = set()
    for sel in selection.kits:
        if sel.ref in seen:
            continue
        seen.add(sel.ref)
        if sel.bundled is not None:
            out.append(Kit(sel.bundled, sel.role, _load(sel.bundled), sel.ref))
            continue
        try:
            kit = fetch_selected(sel, "msb")
        except kit_fetch.KitFetchError as exc:
            raise msb.MsbError(exc.code, f"{exc.message} ({sel.role} kit)", exc.remediation) from exc
        out.append(kit)
    return out


def selection_for(agent: str, cli_kits: list[str], *, image_is_default: bool,
                  extras: list[str] | None = None) -> kitspec.KitSelection:
    """The kit selection for a new sandbox (``extras`` is None) or an existing one.

    A new sandbox folds in config ``extra_kits`` (Bash
    ``_acq_apply_configured_extra_kits``, which runs only on a fresh create).
    An existing sandbox is rebuilt from what its create recorded: ``extras``
    are the recorded extra refs, which replace ``ACQ_EXTRA_KITS`` even when
    empty, and config ``extra_kits`` never take part, since the create
    recorded the ones it applied. An empty record suppresses live extras too.
    On the default image the agent's bundled kit is required, since that image
    has no agent binary. Raises
    :class:`kitspec.KitSelectionError`.
    """
    required = agent if agent in kitspec.AGENT_BUNDLE_KITS and image_is_default else None
    env = {**os.environ, "ACQ_EXTRA_KITS": " ".join(extras)} if extras is not None else os.environ
    selection = kitspec.select_kits(agent, cli_kits=cli_kits, env=env, configured_extras=extras is None,
                                    required_agent_kit=required)
    selection.require()
    return selection


def select(agent: str, cli_kits: list[str], *, image_is_default: bool, extras: list[str] | None = None) -> list[Kit]:
    """Select, verify and parse a sandbox's kit set (Bash ``_build_kit_list``).

    See :func:`selection_for` for how ``extras`` decides between a new and an
    existing sandbox. Raises :class:`kitspec.KitSelectionError` or :class:`msb.MsbError`.
    """
    return resolve(selection_for(agent, cli_kits, image_is_default=image_is_default, extras=extras))


# ---------------------------------------------------------------------------
# The sandbox's --kit and extra refs (Bash acq_cli_kits_write / acq_cli_kits_load).
# ---------------------------------------------------------------------------


def _cli_kits_path(name: str, backend: str = "msb") -> Path:
    return legacy_bash.cli_kits_file(backend, name)


def cli_kits_write(name: str, kit_set: Iterable[Kit], backend: str = "msb") -> None:
    """Record the sandbox's extra and ``--kit`` refs so later reapplies include them. Raises ``OSError``."""
    kit_set = list(kit_set)
    lines = ["schema=1", *(f"extra={k.ref}" for k in kit_set if k.role == "extra"),
             *(f"kit={k.ref}" for k in kit_set if k.role == "cli")]
    path = _cli_kits_path(name, backend)
    path.parent.mkdir(parents=True, exist_ok=True)
    state.atomic_write_text(path, "\n".join(lines) + "\n")
    path.chmod(0o600)


def cli_kits_read(name: str, backend: str = "msb") -> tuple[list[str], list[str]]:
    """The recorded ``(--kit refs, extra refs)``; live extras only if there is no record.

    A relative local ref (left by an older Bash acq) would resolve against the
    current directory, so it is skipped with a warning, as Bash does.
    """
    recorded = legacy_bash.read_cli_kits(backend, name, _warn)
    if recorded is not None:
        return recorded
    return ([], kitspec._ifs_split(os.environ.get("ACQ_EXTRA_KITS", "")))


def cli_kits_remove(name: str, backend: str = "msb") -> None:
    _cli_kits_path(name, backend).unlink(missing_ok=True)


def bundled_kit(name: str, role: str = "cli") -> Kit:
    """One verified bundled kit by name (``acq kit apply``)."""
    sel = kitspec.SelectedKit(kitspec.builtin_kit_ref(name), role, name)
    return resolve(kitspec.KitSelection((sel,), 0, 0, None))[0]


def _load(name: str) -> kitspec.KitSpec:
    try:
        spec = kitspec.load_bundled_kit(name)
    except kitspec.KitSpecError as exc:
        raise msb.MsbError(errors.VALIDATION_FAILED, f"cannot read built-in kit '{name}': {exc}",
                           "reinstall acq") from exc
    return spec


def egress_names(kits: Iterable[Kit]) -> list[msb.EgressKit]:
    """What forms the sandbox's egress policy: each kit's name, or for a fetched kit its own allowlist.

    A bundled kit is named, and :func:`msb.egress_flags` takes its allowlist
    from the vetted table pinned with the bundle. A fetched kit's allowlist is
    read from its own spec at the pinned commit, as Bash reads every kit's
    (``_acq_msb_net_rules_into``); msb.egress_flags validates each host.
    """
    return [(k.name, k.spec.net_allow) if k.fetched else k.name for k in kits]


# ---------------------------------------------------------------------------
# Host-config directory (Bash acq_host_config_*).
# ---------------------------------------------------------------------------


def _hc_dir(name: str) -> Path:
    path = security.host_config_dir(name)
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o711)
    return path


def hc_write(name: str, key: str, value: str) -> None:
    """Write one key (0600, atomic). Raises ``OSError``."""
    if not _KEY.fullmatch(key) or key in (".", ".."):
        raise ValueError(f"unsafe host-config key: {key!r}")
    state.atomic_write_text(_hc_dir(name) / key, value)
    (_hc_dir(name) / key).chmod(0o600)


def hc_has(name: str, key: str) -> bool:
    return _KEY.fullmatch(key) is not None and (security.host_config_dir(name) / key).is_file()


def hc_clear(name: str, key: str) -> None:
    try:
        (security.host_config_dir(name) / key).unlink()
    except OSError:
        pass


def hc_append(name: str, key: str, line: str) -> bool:
    """Append one line (best-effort, as Bash; False on failure)."""
    try:
        path = _hc_dir(name) / key
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        return False
    return True


def clear_instance_state(name: str) -> None:
    """Drop the keys that describe a previous guest of the same name."""
    root = security.host_config_dir(name)
    if not root.is_dir():
        return
    for entry in root.iterdir():
        if entry.name in _INSTANCE_KEYS or entry.name.startswith(_INSTANCE_PREFIXES):
            try:
                entry.unlink()
            except OSError:
                pass


def remove_host_config(name: str) -> None:
    """Remove the sandbox's host-config directory once its guest is gone (Bash ``acq_host_config_remove``).

    Best-effort. The directory is acq's own (its name is derived from the
    sandbox name), so removing it never follows a symlink out of the state tree.
    """
    path = security.host_config_dir(name)
    if path.is_symlink():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path, ignore_errors=True)


def mount_flags(name: str) -> list[str]:
    """``--volume HOSTCFG:GUEST:ro`` for the sandbox's host-config directory.

    msb cannot mount a symlinked host path, so the directory is passed in its
    canonical form. Raises ``OSError`` when it cannot be prepared.
    """
    host = os.path.realpath(_hc_dir(name))
    return ["--volume", f"{host}:{security.HOST_CONFIG_GUEST_DIR}:ro"]


# ---------------------------------------------------------------------------
# Environment (ADR-0033) and exec flags.
# ---------------------------------------------------------------------------


def merge_env(kits: Iterable[Kit]) -> list[str]:
    """Every kit's ``environment`` as ``NAME=value``: the last kit wins, the first fixes the order.

    A shortcut kit is skipped: its environment is never applied, so commands
    and sessions must not see it either.
    """
    values: dict[str, str] = {}
    for kit in kits:
        if kit.shortcut:
            continue
        for var in kit.spec.env:
            values[var.name] = var.value
    return [f"{k}={v}" for k, v in values.items()]


def own_guards(kit: Kit) -> list[str]:
    """This kit's own git-guard entries, as whole tokens."""
    return [f"{e.name}={e.value}" for e in kit.spec.env if e.name in GUARD_NAMES]


def command_env(merged: list[str], own: list[str]) -> list[str]:
    """The env one kit command runs with (``_acq_msb_env_tokens_with_guards_into``).

    Every guard entry is dropped from the merged set whoever declared it, this
    kit's own are added back, then acq's guards unless this kit set
    ``GIT_TERMINAL_PROMPT``. A command never runs with another kit's guard value.
    """
    out = [t for t in merged if t.split("=", 1)[0] not in GUARD_NAMES]
    out += own
    if not any(t.startswith("GIT_TERMINAL_PROMPT=") for t in own):
        out += list(msb.GIT_GUARD_ENV)
    return out


def exec_flags(user: str, env: list[str], ssh_auth_sock: str | None = None) -> list[str]:
    """``msb exec`` ``-u``/``-e`` flags (``_acq_msb_exec_flags_into``).

    The kits name the unprivileged agent as uid 1000 (the sbx contract); on msb
    it is addressed by name, with HOME set, since uid 1000 may be another user.
    ``ssh_auth_sock`` is the forwarded agent's guest socket when this command
    wired the forward (:func:`acq_py.ssh_agent.forwarding_sock`): agent-user
    commands get it, so a kit that asks the agent for a key (git-ssh-sign) can.
    """
    flags: list[str] = []
    extra: list[str] = []
    if user in _AGENT_USERS:
        flags, extra = ["-u", "agent"], [f"HOME={AGENT_HOME}"]
        if ssh_auth_sock:
            extra.append(f"SSH_AUTH_SOCK={ssh_auth_sock}")
    elif user:
        flags = ["-u", user]
    for token in (*extra, *env):
        flags += ["-e", token]
    return flags


# ---------------------------------------------------------------------------
# Startup script (ADR-0017).
# ---------------------------------------------------------------------------


def _sq(value: str) -> str:
    """Single-quote ``value`` for a generated ``/bin/sh`` line (``_acq_msb_sq``)."""
    return "'" + value.replace("'", "'\\''") + "'"


def startup_line(user: str, background: bool, prefix: list[str], argv: list[str]) -> str:
    """One guest ``/bin/sh`` line for a startup command (``_acq_msb_startup_emit_command``)."""
    if not argv:
        return ""
    payload = ("env " + " ".join(_sq(t) for t in prefix)) if prefix else ""
    payload += " sh -c 'exec \"$@\"' sh" + "".join(" " + _sq(t) for t in argv)
    if background:
        payload = f"nohup sh -c {_sq(payload)} >/dev/null 2>&1 & :"
    if user in ("", *_ROOT_USERS):
        return payload
    if user in _AGENT_USERS:
        quoted = _sq(payload)
        return (f"if command -v runuser >/dev/null 2>&1; then runuser -u agent -- sh -c {quoted}; "
                f"else su agent -c {quoted}; fi")
    return f"su {_sq(user)} -c {_sq(payload)}"


def ro_guest_path(guest_path: str) -> str:
    """Where a read-only kit file appears in the guest (``_acq_msb_stage_readonly_file``)."""
    slug = re.sub("-+", "-", re.sub("[^A-Za-z0-9]", "-", guest_path.lstrip("/"))).removesuffix("-")
    crc = lock.posix_cksum(guest_path.encode("utf-8"))
    return f"{security.HOST_CONFIG_GUEST_DIR}/kit-files/{slug}.{crc}"


def ro_rewrites(kit: Kit) -> dict[str, str]:
    """Declared guest path -> read-only staged path, for each readonly file with a source."""
    return {f.path: ro_guest_path(f.path) for f in kit.spec.files if f.readonly and f.source}


def startup_body(kit: Kit, merged: list[str], *, ro_mount: bool) -> str:
    """The startup-phase lines of one kit ("" when it has none)."""
    rewrite = ro_rewrites(kit) if ro_mount else {}
    own = own_guards(kit)
    lines = []
    for cmd in kit.spec.commands_for("startup"):
        prefix = ([f"HOME={AGENT_HOME}"] if cmd.user in _AGENT_USERS else []) + command_env(merged, own)
        line = startup_line(cmd.user, cmd.background, prefix, [rewrite.get(t, t) for t in cmd.argv])
        if line:
            lines.append(line + "\n")
    return "".join(lines)


_STARTUP_HEADER = (
    "#!/bin/sh\n"
    "# acq-generated msb startup script (ADR-0017). Reproduces kit startup\n"
    "# commands so microsandbox can replay them on a native restart.\n"
    "# Generated verbatim into a host file and registered via --script-path;\n"
    "# kit argv/env tokens are single-quote-escaped (SI-10), never interpolated.\n"
)


def startup_script(kits: Iterable[Kit], merged: list[str], *, ro_mount: bool) -> str | None:
    """The script for the FIRST kit with startup commands, as Bash stages it, or ``None``.

    Registering it with ``--script-path`` only stages it on the guest PATH; msb
    does not run it at boot, so acq's own apply path runs every kit's startup.
    """
    for kit in kits:
        body = startup_body(kit, merged, ro_mount=ro_mount)
        if body:
            return _STARTUP_HEADER + body
    return None


def _stage_dir() -> Path:
    """The private staging directory; a relative override raises :class:`userdirs.UserDirError`.

    A relative ``ACQ_MSB_STARTUP_STAGE_DIR`` would resolve against the current
    directory, normally the agent-writable workspace. The CLI refuses it up
    front (:func:`userdirs.check_path_overrides`); this is the same refusal for
    any other caller.
    """
    override = userdirs.path_override(STARTUP_STAGE_DIR_ENV)
    path = override or state.state_dir() / "msb-startup"
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
    return path


def stage_startup_script(body: str) -> Path | None:
    """Write ``body`` to a private host file for ``--script-path`` (best-effort, as Bash).

    Nothing is written when the staging directory is refused; the warning names why.
    """
    try:
        fd, raw = tempfile.mkstemp(prefix=f"{STARTUP_SCRIPT_NAME}.", dir=_stage_dir())
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
    except userdirs.UserDirError as exc:
        _warn(f"{exc.message}; skipping --script-path")
        return None
    except OSError:
        _warn("could not stage the kit startup script; skipping --script-path")
        return None
    return Path(raw)


def discard_staged(paths: Iterable[Path]) -> None:
    """Remove staged startup scripts once ``msb create`` has read them."""
    if os.environ.get(KEEP_STARTUP_STAGE_ENV):
        return
    for path in paths:
        try:
            path.unlink()
        except OSError:
            pass


def volume_flags(name: str, kits: Iterable[Kit]) -> list[str]:
    """Create-time storage, unioned by guest path with the last declaration winning.

    Named disks live in msb's volume store; no arbitrary host path is mounted.
    The POSIX CRC keeps distinct paths with the same readable slug separate.
    """
    volumes: dict[str, kitspec.Volume] = {}
    for kit in kits:
        for warning in kit.spec.warnings["volumes"]:
            print(warning, file=sys.stderr)
        for volume in kit.spec.volumes:
            volumes.pop(volume.path, None)
            volumes[volume.path] = volume
    flags: list[str] = []
    for path, volume in volumes.items():
        if not path.startswith("/"):
            print(f"acq(msb): warning: skipping volume with non-absolute path: {path}", file=sys.stderr)
            continue
        if re.search(r"[^A-Za-z0-9._/-]", path + volume.size):
            print(f"acq(msb): warning: skipping volume with unsafe path/size: {path}:{volume.size}",
                  file=sys.stderr)
            continue
        if volume.type == "tmpfs":
            flags += ["--tmpfs", f"{path}:{volume.size}"]
        else:
            slug = re.sub(r"[^A-Za-z0-9]+", "-", path[1:]).rstrip("-")
            crc = legacy_bash.posix_cksum(path.encode("utf-8"))
            flags += ["--mount-named", f"acq-{name}-{slug}-{crc}:{path}:kind=disk,size={volume.size}"]
    return flags


def create_flags(name: str, kits: list[Kit], *, ro_mount: bool) -> tuple[list[str], list[Path]]:
    """The kit set's ``msb create`` flags and the staged files to discard afterwards.

    Raises ``OSError`` when the host-config directory cannot be prepared.
    """
    flags = [*(mount_flags(name) if ro_mount else []), *volume_flags(name, kits)]
    staged: list[Path] = []
    body = startup_script(kits, merge_env(kits), ro_mount=ro_mount)
    path = stage_startup_script(body) if body else None
    if path is not None:
        flags += ["--script-path", f"{STARTUP_SCRIPT_NAME}:{path}"]
        staged.append(path)
    if any(k.shortcut and k.spec.shortcut_val("msb", "trust_host_cas") == "true" for k in kits):
        flags.append("--trust-host-cas")
    return flags, staged


# ---------------------------------------------------------------------------
# Applying a kit (_acq_msb_apply_kit_dir).
# ---------------------------------------------------------------------------


class KitApplyFailed(Exception):
    """A kit could not be placed; the message says why (acq-authored, no backend text)."""


class RoGate:
    """Whether readonly kit files may be staged on the read-only mount (evaluated once, lazily).

    ``required`` is the sandbox's host record: a sandbox created with the mount
    must have it confirmed, and never falls back to a guest-writable copy.
    """

    def __init__(self, name: str, required: bool, check: Callable[[str], tuple[str, str]] | None = None):
        self.name, self.required, self._check = name, required, check
        self._result: tuple[str, str] | None = None

    def confirmed(self) -> bool:
        if not self.required:
            return False
        if self._result is None:
            self._result = (self._check or security.probe_mount)(self.name)
        if self._result[0] != "ok":
            raise KitApplyFailed(
                f"cannot place a read-only kit file: {self._result[1]}; no guest-copy fallback is taken "
                "because the sandbox was created with a read-only host config, so recreate it"
            )
        return True


def stage_readonly_file(name: str, guest_path: str, src: Path) -> str:
    """Copy a readonly kit file into the host-config directory (0555); returns its guest path."""
    files = _hc_dir(name) / "kit-files"
    files.mkdir(exist_ok=True)
    files.chmod(0o711)
    guest = ro_guest_path(guest_path)
    dest = files / guest.rsplit("/", 1)[1]
    # A staged copy is 0555, so it is replaced rather than written over (Bash
    # ``cp -f``): a temporary file in the same directory, renamed into place.
    fd, tmp = tempfile.mkstemp(prefix=f".{dest.name}.", dir=files)
    try:
        with os.fdopen(fd, "wb") as out, open(src, "rb") as inp:
            shutil.copyfileobj(inp, out)
        os.chmod(tmp, 0o555)  # nosec B103 # read-only kit code the guest must read and run (Bash stages it 0555)
        if WINDOWS and dest.exists():
            # Windows refuses to replace a file with the read-only attribute.
            os.chmod(dest, stat.S_IWRITE)
        os.replace(tmp, dest)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return guest


def _chown_top(path: str) -> str:
    """The top-most directory a file under the agent home introduced ("" when none)."""
    if not path.startswith(AGENT_HOME + "/"):
        return ""
    top = path[len(AGENT_HOME) + 1:].split("/", 1)[0]
    return "" if top in ("", ".", "..") else f"{AGENT_HOME}/{top}"


# Positional args: PATH MODE CHOWN-TOP. Exit 3 when the copied file is absent or
# empty; chmod/chown failures are tolerated, as in Bash. chown -P never follows
# a symlink a kit staged under the tree.
_PLACE_SCRIPT = (
    'test -s "$1" || exit 3; '
    'if [ -n "$2" ]; then chmod "$2" "$1" 2>/dev/null || :; fi; '
    'if [ -n "$3" ]; then chown -R -P agent "$3" 2>/dev/null || :; fi'
)


def _copy_into_guest(name: str, src: Path, path: str, mode: str) -> None:
    """``_acq_msb_copy_file_verified``: copy, verify it landed (one retry), chmod, chown."""
    if not path.startswith("/"):
        raise KitApplyFailed(f"refusing kit file with a non-absolute path: {path!r}")
    if mode and not _OCTAL.fullmatch(mode):
        _warn(f"refusing chmod: non-octal mode {mode!r} for {path!r}")
        mode = ""
    place = ["sh", "-c", _PLACE_SCRIPT, "sh", path, mode, _chown_top(path)]
    for _attempt in range(2):
        msb.copy(str(src), f"{name}:{path}")
        if msb.kit_exec(name, ["-u", "0"], place):
            return
    raise KitApplyFailed(f"could not place kit file at {name}:{path}")


def place_files(name: str, kit: Kit, ro: RoGate) -> dict[str, str]:
    """Place a kit's ``files``; returns the readonly path rewrites for its commands."""
    rewrite: dict[str, str] = {}
    sources = []
    for entry in kit.spec.files:
        src = kitspec.resolve_source(kit.spec.kit_dir or "", entry.source) if entry.source else None
        if entry.source and src is None:
            _warn(f"skipping kit file '{entry.path}': its source is not a regular file inside the kit directory")
        elif src is not None:
            sources.append((entry, src))
    dirs = sorted({posix_dirname(e.path) for e, _ in sources if not (e.readonly and ro.required)})
    if dirs:
        msb.kit_exec(name, ["-u", "0"], ["sh", "-c", 'mkdir -p "$@"', "sh", *dirs])
    for entry, src in sources:
        if entry.readonly and ro.confirmed():
            try:
                rewrite[entry.path] = stage_readonly_file(name, entry.path, src)
            except OSError as exc:
                raise KitApplyFailed(f"could not stage read-only kit file '{entry.path}'") from exc
            continue
        if entry.readonly:
            _warn(f"sandbox '{name}' has no read-only host-config record; copying readonly kit file "
                  f"'{entry.path}' into the guest for compatibility (recreate it for tamper-resistant startup code)")
        _copy_into_guest(name, src, entry.path, entry.mode)
    return rewrite


def posix_dirname(path: str) -> str:
    return path.rsplit("/", 1)[0] or "/"


def _install_marker(argv: list[str]) -> str:
    return "install-" + str(lock.posix_cksum(b"".join(t.encode("utf-8") + b"\0" for t in argv)))


def run_command(name: str, cmd: kitspec.Command, env: list[str], rewrite: dict[str, str], *, force: bool,
                ssh_auth_sock: str | None = None) -> bool:
    """Run one kit command with its phase's semantics (``_acq_msb_exec_command``).

    ``install`` runs once per guest: a host-held marker (a cache of the guest's
    reported success, not an integrity fact) skips it unless ``force``.
    ``startup`` with ``background`` is detached under ``nohup``. Everything else
    runs in the foreground on every apply.
    """
    argv = [rewrite.get(t, t) for t in cmd.argv]
    if not argv:
        return True
    flags = exec_flags(cmd.user, env, ssh_auth_sock)
    if cmd.phase == "install":
        marker = _install_marker(argv)
        if not force and hc_has(name, marker):
            return True
        ok = msb.kit_exec(name, flags, _foreground(argv))
        if ok:
            try:
                hc_write(name, marker, "1")
            except OSError:
                pass
        return ok
    if cmd.phase == "startup" and cmd.background:
        return msb.kit_exec(name, flags, ["sh", "-c", 'nohup "$@" >/dev/null 2>&1 & exit 0', "sh", *argv])
    return msb.kit_exec(name, flags, _foreground(argv))


def _foreground(argv: list[str]) -> list[str]:
    """A fixed waiting shell around ``node`` (the measured msb direct-node startup cost)."""
    return ["sh", "-c", '"$@"', "sh", *argv] if argv[0] == "node" else argv


def apply_kit(name: str, kit: Kit, merged: list[str], ro: RoGate, *, force: bool,
              ssh_auth_sock: str | None = None) -> bool:
    """Files, then the kit's environment (kept host-side), then its commands.

    Returns False when a command failed (warned). Raises :class:`KitApplyFailed`
    when a file could not be placed, so the kit's commands never run against it.
    ``ssh_auth_sock`` goes to the agent-user commands (:func:`exec_flags`).
    """
    if kit.shortcut:
        return True
    rewrite = place_files(name, kit, ro)
    for var in kit.spec.env:
        if not hc_append(name, "kit-env", f"{var.name}={var.value}"):
            _warn(f"could not persist kit env for '{name}'; its environment will not reach agent sessions")
    env = command_env(merged, own_guards(kit))
    ok = True
    for cmd in kit.spec.commands:
        if not run_command(name, cmd, env, rewrite, force=force, ssh_auth_sock=ssh_auth_sock):
            _warn(f"{cmd.phase or 'a'} command of kit '{kit.name}' failed in sandbox '{name}'")
            ok = False
    return ok


def _persisted_env(name: str) -> list[str]:
    """The sandbox's persisted kit env (``kit-env``), malformed lines dropped."""
    try:
        text = (security.host_config_dir(name) / "kit-env").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []
    return [line for line in text.splitlines() if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", line)]


def _dedupe_env(tokens: Iterable[str]) -> list[str]:
    values: dict[str, str] = {}
    for token in tokens:
        key, _, value = token.partition("=")
        values[key] = value
    return [f"{k}={v}" for k, v in values.items()]


def session_env(name: str) -> list[str]:
    """The kit environment every session in ``name`` gets (Bash ``_acq_msb_kit_env_flags_into``).

    The persisted ``kit-env`` lines, one entry per variable: the last value
    wins and the first occurrence fixes the order, as kits append in the order
    they were applied. Empty when no kit declared an environment.
    """
    return _dedupe_env(_persisted_env(name))


def apply_single(name: str, kit: Kit, *, ro_required: bool) -> bool:
    """Apply one kit to a running sandbox (``acq kit apply``); additive, so the env is not reset.

    Its commands see the sandbox's persisted kit env with this kit's own entries
    layered last. Raises :class:`KitApplyFailed` or :class:`msb.MsbError` like
    :func:`apply_kit`.
    """
    if kit.spec.volumes:
        print("acq(msb): note: this kit declares volumes:, which apply at CREATE time only —", file=sys.stderr)
        print("acq(msb):   this apply skips them. Recreate the sandbox (acq rm && acq run) to mount them.",
              file=sys.stderr)
    merged = _dedupe_env([*_persisted_env(name), *(f"{e.name}={e.value}" for e in kit.spec.env)])
    return apply_kit(name, kit, merged, RoGate(name, ro_required), force=False)


# The agent-user setup (Bash ``_acq_msb_ensure_agent_user``), run as guest root.
# Idempotent and never skipped on a recorded marker: a guest could report
# success once and so suppress the check for good. An existing ``agent`` user is
# reused; otherwise it is created with whatever uid is free (uid 1000 may belong
# to another user on a plain base image; the kits address the agent by name).
# The home must exist, be owned by the agent and be writable by it, or every
# agent-user kit command fails, so that part is fatal. The recursive chown is
# only for a user created here. Passwordless sudo and proxy-variable
# preservation are set only where sudo exists.
_AGENT_USER_SCRIPT = (
    "set -e\n"
    "created=0\n"
    "if id agent >/dev/null 2>&1; then :\n"
    "elif command -v useradd >/dev/null 2>&1; then useradd -M -d /home/agent -s /bin/sh agent; created=1\n"
    "elif command -v adduser >/dev/null 2>&1; then adduser -h /home/agent -s /bin/sh -D -H agent; created=1\n"
    "else echo 'acq(msb): no useradd/adduser in base image; cannot create agent user' >&2; exit 1\n"
    "fi\n"
    "mkdir -p /home/agent\n"
    "grp=$(id -gn agent 2>/dev/null || echo agent)\n"
    'chown "agent:$grp" /home/agent\n'
    'if [ "$created" = 1 ]; then chown -R "agent:$grp" /home/agent; fi\n'
    "su agent -s /bin/sh -c 'test -w /home/agent' 2>/dev/null"
    " || { echo 'acq(msb): /home/agent is not writable by the agent user' >&2; exit 1; }\n"
    "if command -v sudo >/dev/null 2>&1; then\n"
    "  mkdir -p /etc/sudoers.d\n"
    "  printf 'agent ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/90-acq-agent\n"
    "  chmod 0440 /etc/sudoers.d/90-acq-agent\n"
    "  printf 'Defaults env_keep += \"HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy\"\\n'"
    " > /etc/sudoers.d/91-acq-proxy-env\n"
    "  chmod 0440 /etc/sudoers.d/91-acq-proxy-env\n"
    "fi\n"
)


def ensure_agent_user(name: str) -> bool:
    """Make sure the guest has the ``agent`` user and a home it owns; True on success.

    Runs before every kit-set apply (create, recreate, start, re-attach, ``kit
    update``), as Bash runs ``_acq_msb_ensure_agent_user`` in its provision and
    heal paths. A failure is warned about here; the caller decides whether it
    is fatal (a new sandbox) or a warning (a heal).
    """
    try:
        ok = msb.kit_exec(name, ["-u", "0"], ["sh", "-c", _AGENT_USER_SCRIPT])
    except msb.MsbError as exc:
        _warn(f"could not set up the agent user in sandbox '{name}': {exc.message}")
        return False
    if not ok:
        _warn(f"could not establish a writable agent home in sandbox '{name}'; /home/agent must exist and be "
              "owned by the 'agent' user (a custom image must ship that user, or useradd/adduser)")
    return ok


# The kit prerequisite check (Bash ``_acq_msb_check_prereqs``). The pinned kits
# assume these tools are in the base image. The default image ships them; a
# custom image may not, and acq does not install them, because the kits' egress
# rules lock the sandbox to the kits' own hosts, so a package mirror is out of
# reach. The probe prints one tagged line, so output that is not its answer
# (an msb that echoes the command, say) is never read as a missing tool.
PREREQ_TOOLS = ("node", "git", "curl", "update-ca-certificates")
SKIP_PREREQ_CHECK_ENV = "ACQ_MSB_SKIP_PREREQ_CHECK"
_PREREQ_TAG = "acq-prereqs:"
_PREREQ_SCRIPT = (
    'm=""\n'
    f"for t in {' '.join(PREREQ_TOOLS)}; do\n"
    '  command -v "$t" >/dev/null 2>&1 || m="$m $t"\n'
    "done\n"
    f'printf "{_PREREQ_TAG}%s\\n" "$m"\n'
)


def missing_prereqs(name: str) -> list[str] | None:
    """The kit prerequisites the guest lacks, or ``None`` when the probe gave no answer."""
    out = msb.guest_probe(name, ["sh", "-c", _PREREQ_SCRIPT])
    for line in out.replace("\r", "").splitlines():
        if not line.startswith(_PREREQ_TAG):
            continue
        tools = line[len(_PREREQ_TAG):].split()
        if all(tool in PREREQ_TOOLS for tool in tools):
            return tools
    return None


def check_prereqs(name: str) -> None:
    """Warn when the guest lacks a kit prerequisite; never fails the caller.

    Runs when a new guest is provisioned (create and recreate), ahead of the
    agent-user setup, as Bash's provision does; not on a heal of an existing
    sandbox. ``ACQ_MSB_SKIP_PREREQ_CHECK`` (any non-empty value) skips
    it. A probe that gives no answer is not reported, as in Bash.
    """
    if os.environ.get(SKIP_PREREQ_CHECK_ENV):
        return
    missing = missing_prereqs(name)
    if not missing:
        return
    _warn(f"the base image of sandbox '{name}' is missing kit prerequisite(s): {' '.join(missing)}. "
          f"The pinned kits need {', '.join(PREREQ_TOOLS)}; the default image provides them and a custom "
          "image must too (acq does not install them, because the kits' egress rules lock the sandbox to "
          f"the kits' hosts). Affected kits may not fully apply. Set {SKIP_PREREQ_CHECK_ENV}=1 to silence this.")


def ensure_kits_applied(name: str, kits: list[Kit], *, ro_required: bool, force: bool = False,
                        ssh_auth_sock: str | None = None) -> ApplyResult:
    """Apply the whole kit set (``acq_backend_ensure_kits_applied``); best-effort per kit.

    The agent user is set up first (:func:`ensure_agent_user`); if that fails
    the kits are still attempted and ``agent_user`` says so. The merged
    environment is computed before the first kit runs, so a kit's commands see
    every kit's variables whatever the order (ADR-0033), and the persisted copy
    is rebuilt from the current kits only. ``ssh_auth_sock`` is the forwarded
    agent's guest socket while the forward is wired (see :func:`exec_flags`).
    """
    result = ApplyResult(agent_user=ensure_agent_user(name))
    merged = merge_env(kits)
    hc_clear(name, "kit-env")
    ro = RoGate(name, ro_required)
    for kit in kits:
        try:
            ok = apply_kit(name, kit, merged, ro, force=force, ssh_auth_sock=ssh_auth_sock)
        except (KitApplyFailed, msb.MsbError, OSError) as exc:
            reason = exc.message if isinstance(exc, msb.MsbError) else str(exc)
            _warn(f"kit '{kit.name}' did not apply to sandbox '{name}': {reason}")
            ok = False
        (result.applied if ok else result.incomplete).append(kit.name)
    return result
