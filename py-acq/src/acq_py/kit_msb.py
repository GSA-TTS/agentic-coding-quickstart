"""Apply neutral ``hybrid/v1`` kits to an msb sandbox (ADR-0011, ADR-0017, ADR-0033, ADR-0035).

A port of the Bash msb adapter's kit path (``acq.backends/msb.sh``):

* :func:`resolve` checks the packaged bundle against its manifest
  (:func:`kitspec.verify_bundle`) and parses every selected kit. The Python
  acq applies only its pinned built-in bundle; a ref that would have to be
  fetched (an opt-in catalog kit, a remote or local extra, a ``--kit`` ref, a
  provider kit outside the bundle) is refused before anything is created.
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
import sys
import tempfile
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path

from . import errors, kitspec, lock, msb, security, state

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
    """One selected kit, parsed from the bundle. ``role`` comes from :class:`kitspec.SelectedKit`."""

    name: str
    role: str
    spec: kitspec.KitSpec

    @property
    def shortcut(self) -> bool:
        """``backend_shortcuts.msb`` is set: the native primitive replaces files and commands."""
        return self.spec.has_shortcut("msb")


@dataclass
class ApplyResult:
    """Which kits applied fully, and which did not (a warning was printed for each)."""

    applied: list[str] = field(default_factory=list)
    incomplete: list[str] = field(default_factory=list)


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


def resolve(selection: kitspec.KitSelection) -> list[Kit]:
    """Verify the bundle and parse every selected kit; raises :class:`msb.MsbError`."""
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
        if sel.bundled is None:
            raise msb.MsbError(
                errors.UNSUPPORTED,
                f"kit {sel.ref!r} ({sel.role} kit) would have to be fetched; the Python acq "
                "applies only its pinned built-in kits",
                "drop it from --kit, ACQ_EXTRA_KITS, ACQ_PROVIDER_KITS or config extra_kits/provider_kit, "
                "or use the Bash acq (ACQ_IMPL=bash) for kits that must be fetched",
            )
        if sel.ref in seen:
            continue
        seen.add(sel.ref)
        out.append(Kit(sel.bundled, sel.role, _load(sel.bundled)))
    return out


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
    if spec.published_ports or spec.volumes:
        raise msb.MsbError(
            errors.UNSUPPORTED,
            f"kit '{name}' declares published ports or volumes, which the Python acq does not create yet",
            "use the Bash acq (ACQ_IMPL=bash) for this kit",
        )
    return spec


def egress_names(kits: Iterable[Kit]) -> list[str]:
    """The kit names whose network allowances form the sandbox's egress policy."""
    return [k.name for k in kits]


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


def exec_flags(user: str, env: list[str]) -> list[str]:
    """``msb exec`` ``-u``/``-e`` flags (``_acq_msb_exec_flags_into``).

    The kits name the unprivileged agent as uid 1000 (the sbx contract); on msb
    it is addressed by name, with HOME set, since uid 1000 may be another user.
    """
    flags: list[str] = []
    extra: list[str] = []
    if user in _AGENT_USERS:
        flags, extra = ["-u", "agent"], [f"HOME={AGENT_HOME}"]
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
    override = os.environ.get(STARTUP_STAGE_DIR_ENV)
    path = Path(override) if override else state.state_dir() / "msb-startup"
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
    return path


def stage_startup_script(body: str) -> Path | None:
    """Write ``body`` to a private host file for ``--script-path`` (best-effort, as Bash)."""
    try:
        fd, raw = tempfile.mkstemp(prefix=f"{STARTUP_SCRIPT_NAME}.", dir=_stage_dir())
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
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


def create_flags(name: str, kits: list[Kit], *, ro_mount: bool) -> tuple[list[str], list[Path]]:
    """The kit set's ``msb create`` flags and the staged files to discard afterwards.

    Raises ``OSError`` when the host-config directory cannot be prepared.
    """
    flags = mount_flags(name) if ro_mount else []
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
    shutil.copyfile(src, dest)
    dest.chmod(0o555)
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


def run_command(name: str, cmd: kitspec.Command, env: list[str], rewrite: dict[str, str], *, force: bool) -> bool:
    """Run one kit command with its phase's semantics (``_acq_msb_exec_command``).

    ``install`` runs once per guest: a host-held marker (a cache of the guest's
    reported success, not an integrity fact) skips it unless ``force``.
    ``startup`` with ``background`` is detached under ``nohup``. Everything else
    runs in the foreground on every apply.
    """
    argv = [rewrite.get(t, t) for t in cmd.argv]
    if not argv:
        return True
    flags = exec_flags(cmd.user, env)
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


def apply_kit(name: str, kit: Kit, merged: list[str], ro: RoGate, *, force: bool) -> bool:
    """Files, then the kit's environment (kept host-side), then its commands.

    Returns False when a command failed (warned). Raises :class:`KitApplyFailed`
    when a file could not be placed, so the kit's commands never run against it.
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
        if not run_command(name, cmd, env, rewrite, force=force):
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


def apply_single(name: str, kit: Kit, *, ro_required: bool) -> bool:
    """Apply one kit to a running sandbox (``acq kit apply``); additive, so the env is not reset.

    Its commands see the sandbox's persisted kit env with this kit's own entries
    layered last. Raises :class:`KitApplyFailed` or :class:`msb.MsbError` like
    :func:`apply_kit`.
    """
    merged = _dedupe_env([*_persisted_env(name), *(f"{e.name}={e.value}" for e in kit.spec.env)])
    return apply_kit(name, kit, merged, RoGate(name, ro_required), force=False)


def ensure_kits_applied(name: str, kits: list[Kit], *, ro_required: bool, force: bool = False) -> ApplyResult:
    """Apply the whole kit set (``acq_backend_ensure_kits_applied``); best-effort per kit.

    The merged environment is computed before the first kit runs, so a kit's
    commands see every kit's variables whatever the order (ADR-0033), and the
    persisted copy is rebuilt from the current kits only.
    """
    merged = merge_env(kits)
    hc_clear(name, "kit-env")
    ro = RoGate(name, ro_required)
    result = ApplyResult()
    for kit in kits:
        try:
            ok = apply_kit(name, kit, merged, ro, force=force)
        except (KitApplyFailed, msb.MsbError, OSError) as exc:
            reason = exc.message if isinstance(exc, msb.MsbError) else str(exc)
            _warn(f"kit '{kit.name}' did not apply to sandbox '{name}': {reason}")
            ok = False
        (result.applied if ok else result.incomplete).append(kit.name)
    return result
