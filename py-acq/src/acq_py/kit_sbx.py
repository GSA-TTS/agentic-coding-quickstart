"""Apply neutral ``hybrid/v1`` kits to an sbx sandbox (ADR-0011, ADR-0017, ADR-0037).

sbx has a native kit format (sbx-v2 mixins) and applies kits itself, at
``sbx create --kit DIR`` time or later with ``sbx kit add``. acq's part is to
translate each neutral kit into an sbx-v2 kit directory, as the Bash sbx
adapter does:

* :func:`render_spec` and :func:`translate` are a byte-for-byte port of Bash
  ``kit_translate_to_sbx`` (``acq.backends/kit-translate.sh``), working from
  :mod:`kitspec`'s typed records rather than its tab-separated text form.
* :func:`git_identity_spec` and :func:`startup_barrier_spec` port
  ``_acq_sbx_git_identity_kit`` and ``_acq_sbx_startup_barrier_kit``
  (``acq.backends/sbx.sh``); :func:`prepare` builds the whole ``--kit`` flag
  set (``_acq_sbx_kit_flags`` plus those two generated kits).
* :func:`ensure_kits_applied` ports the sbx ``acq_backend_ensure_kits_applied``
  (``sbx kit add`` for each built-in kit not recorded as applied, decided from
  the host-side ``builtin-kits`` record, never from the guest).

Like the msb path, the Python acq applies only its pinned built-in bundle: a
ref that would have to be fetched is refused before anything is created, and
the bundle is checked against its manifest first (:func:`resolve`).

Generated kit directories live under the acq state directory, in private
(0700) directories acq creates itself; an existing path that is a symlink, not
a directory, or (on POSIX) owned by someone else is refused rather than
followed. A kit's ``files/`` tree is checked with
:func:`kitspec.tree_symlinks_within` before it is copied, as in Bash.
Translated kits are named by their content and only ever moved into place when
absent, so concurrent creates share them without removing one another's; the
per-create barrier kit is removed once ``sbx create`` has read it, and unused
directories are pruned after :data:`STALE_AGE_S`.
"""

from __future__ import annotations

import hashlib
import os
import re
import secrets
import shutil
import stat
import sys
import tempfile
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path

from . import errors, kit_msb, kitspec, lock, sbx, state, timeouts

# The kit record type is shared with the msb path: name, role, parsed spec, ref.
Kit = kit_msb.Kit

KIT_DIR_NAME = "sbx-kits"
BARRIER_PATH = "/tmp/acq/startup-complete"  # nosec B108 # a guest path the barrier kit writes
BARRIER_TIMEOUT_ENV = "ACQ_SBX_STARTUP_BARRIER_TIMEOUT"
DEFAULT_BARRIER_TIMEOUT_S = 60.0
BARRIER_POLL_S = 2.0
FORCE_REAPPLY_ENV = "ACQ_FORCE_KIT_REAPPLY"
STALE_AGE_S = 7 * 24 * 3600  # generated kit directories unused for this long are pruned
PROVIDER_RECORD_NAME = "usai-provider"  # Bash USAI_PROVIDER_KIT_NAME, the record key
OPENCODE_CONFIG_LINK_FIX = (
    'f="$HOME/.config/opencode/opencode.jsonc"; if [ -L "$f" ] && [ ! -e "$f" ]; then rm -f "$f"; fi'
)

# Host-config keys that describe one guest (Bash acq_host_config_clear_instance_state).
_INSTANCE_KEYS = ("agent-user-ready", "workspace", "ssh-auth-sock", "generic-opencode",
                  "extra-kits", "builtin-kits", "ro-host-config")
_INSTANCE_PREFIXES = ("install-", "agent-installed-")
_KEY = re.compile(r"[A-Za-z0-9._-]+")
_SLUG_BYTES = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
_BARRIER_TOKEN = re.compile(r"[A-Za-z0-9-]+")
_YAML_SPECIAL = frozenset(":{}[]#&*!|>'\"%@`")
# Plain scalars YAML 1.1 or 1.2 would read as something other than a string.
_YAML_COERCIBLE = re.compile(
    r"~|null|Null|NULL|y|Y|yes|Yes|YES|n|N|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF"
    r"|=|<<|[-+]?(0b[01_]+|0o?[0-7_]+|0x[0-9a-fA-F_]+|[0-9][0-9_]*(:[0-5]?[0-9])*)"
    r"|[-+]?(\.[0-9_]+|[0-9][0-9_]*(\.[0-9_]*)?)([eE][-+]?[0-9]+)?|[-+]?\.(inf|Inf|INF)|\.(nan|NaN|NAN)"
    r"|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}([Tt ].*)?"
)


class KitTranslateError(Exception):
    """A kit could not be turned into an sbx-v2 kit directory (acq-authored message)."""


def _warn(message: str) -> None:
    print(message, file=sys.stderr)


# ---------------------------------------------------------------------------
# YAML emission (_kit_yaml_quote).
# ---------------------------------------------------------------------------


def yaml_quote(value: str) -> str:
    """``_kit_yaml_quote``: single-quote a scalar with a YAML-special character, else bare."""
    if value == "":
        return "''"
    if (any(ch in _YAML_SPECIAL for ch in value) or value.startswith(("-", " "))
            or value.endswith(" ")):
        return "'" + value.replace("'", "''") + "'"
    return value


def _shell_lines(text: str) -> list[str]:
    """``printf '%s\\n' "$text" | while IFS= read -r line``: the lines of ``text``."""
    return text.split("\n")


def _subst(token: str) -> str:
    """``$(...)``: command substitution drops every trailing newline."""
    return token.rstrip("\n")


# ---------------------------------------------------------------------------
# Translation (kit_translate_to_sbx).
# ---------------------------------------------------------------------------


def _header(spec: kitspec.KitSpec) -> list[str]:
    out = ['schemaVersion: "2"', "kind: mixin", f"name: {spec.field('name') or ''}"]
    display = spec.field("displayName") or ""
    desc = spec.field("description") or ""
    if display:
        out.append(f"displayName: {yaml_quote(display)}")
    if desc:
        out.append(f"description: {yaml_quote(desc)}")
    hosts = [h for h in spec.net_allow if h]
    if hosts:
        out += ["permissions:", "  network:", "    allow:", *(f"      - {yaml_quote(h)}" for h in hosts)]
    if spec.env:
        out += ["environment:", "  variables:"]
        # ``IFS=<tab> read -r key value`` trims the value's leading and trailing tabs.
        out += [f"    {e.name}: {yaml_quote(e.value.strip(chr(9)))}" for e in spec.env if e.name]
    return out


def _ports_and_volumes(spec: kitspec.KitSpec) -> list[str]:
    out: list[str] = []
    if spec.published_ports:
        out.append("ports:")
        for port in spec.published_ports:
            if not port.guest:
                continue
            out.append(f"  - container: {port.guest}")
            if port.protocol:
                out.append(f"    protocol: {port.protocol}")
            if port.name:
                out.append(f"    name: {yaml_quote(port.name)}")
    if spec.volumes:
        out.append("volumes:")
        for vol in spec.volumes:
            if not vol.path:
                continue
            out.append(f"  - path: {vol.path}")
            if vol.type:
                out.append(f"    type: {vol.type}")
            out.append(f"    size: {vol.size}")
    return out


def _chmod_script(spec: kitspec.KitSpec, warn: list[str]) -> list[str]:
    """``_kit_sbx_mode_chmod_script``: one chmod line per home-staged file with a mode."""
    lines = []
    for entry in spec.files:
        path, mode = entry.path, entry.mode
        if not path or not mode:
            continue
        if not path.startswith("/home/agent/"):
            warn.append(f"kit-translate: warning: mode {mode} on {path} cannot be applied on sbx (only "
                        "home-staged files can be chmodded in setup.install; files/workspace/ is written "
                        "after install commands — docker/sbx-releases#499)")
            continue
        if not re.fullmatch("0[0-7]{3}", mode):
            warn.append(f"kit-translate: skipping chmod for {path}: mode must be a 0-prefixed octal string "
                        f'like "0755" (got: {mode})')
            continue
        lines.append(f"chmod {mode} '{path}' && echo \"acq kit-modes: {mode} {path}\" || "
                     f"echo \"acq kit-modes: FAILED {mode} {path}\"")
    return lines


_CHMOD_DESCRIPTION = "Apply kit-declared file modes (sbx pins files/ payloads to 0644 — see docker/sbx-releases#499)"


def _command_lines(cmd: kitspec.Command) -> list[str]:
    """``_kit_sbx_emit_one_setup_command`` for one decoded command."""
    argv = [_subst(tok) for tok in cmd.argv]
    out: list[str] = []
    if cmd.phase == "install":
        script = argv[2] if len(argv) == 3 and argv[:2] == ["sh", "-c"] else " ".join(argv)
        out.append("    - command: |")
        out += [f"        {line}" for line in _shell_lines(script)]
        if cmd.user:
            out.append(f'      user: "{cmd.user}"')
        return out
    out.append("    - command:")
    for tok in argv:
        if "\n" in tok:
            out.append("        - |")
            out += [f"          {line}" for line in _shell_lines(tok)]
        else:
            out.append(f"        - {yaml_quote(tok)}")
    if cmd.user:
        out.append(f'      user: "{cmd.user}"')
    if cmd.background:
        out.append("      background: true")
    return out


def _setup(spec: kitspec.KitSpec, warn: list[str]) -> list[str]:
    """``_kit_sbx_emit_setup``: setup.install, then setup.startup (initFiles before startup)."""
    out: list[str] = []
    chmod = _chmod_script(spec, warn)
    have_install = have_startup = False
    if chmod:
        out += ["setup:", "  install:", "    - command: |", *(f"        {line}" for line in chmod),
                '      user: "0"', f"      description: {yaml_quote(_CHMOD_DESCRIPTION)}"]
        have_install = True
    for phase in ("install", "initFiles", "startup"):
        for cmd in spec.commands_for(phase):
            if not out:
                out.append("setup:")
            if phase == "install" and not have_install:
                out.append("  install:")
                have_install = True
            if phase != "install" and not have_startup:
                out.append("  startup:")
                have_startup = True
            out += _command_lines(cmd)
    return out


def _agent_instructions(spec: kitspec.KitSpec) -> list[str]:
    ctx = _subst("".join(f"{line}\n" for line in spec.agent_context))
    if not ctx:
        return []
    return ["agentInstructions:", "  content: |", *(f"    {line}" for line in _shell_lines(ctx))]


def render_spec(spec: kitspec.KitSpec, warn: list[str] | None = None) -> str:
    """The sbx-v2 ``spec.yaml`` Bash ``kit_translate_to_sbx`` writes for ``spec``.

    ``warn`` collects the translator's own warnings (file modes it cannot apply).
    """
    sink: list[str] = [] if warn is None else warn
    lines = [*_header(spec), *_ports_and_volumes(spec), *_setup(spec, sink), *_agent_instructions(spec)]
    return "".join(f"{line}\n" for line in lines)


def readonly_warning(spec: kitspec.KitSpec) -> list[str]:
    """``_acq_sbx_warn_readonly_files``: sbx has no read-only staging (ADR-0037)."""
    paths = [f.path for f in spec.files if f.readonly]
    if not paths:
        return []
    return [
        f"acq(sbx): WARNING: kit '{spec.field('name') or 'unknown'}' marks startup files readonly: {' '.join(paths)}",
        "acq(sbx):   On sbx these are guest-resident copies with NO integrity guarantee",
        "acq(sbx):   against a sudo guest (the agent can rewrite them). This is the",
        "acq(sbx):   documented interim state in docs/adr/0037-sbx-trusted-startup-parity.md.",
        "acq(sbx):   The kit still applies. msb stages these files from a read-only host mount.",
    ]


def translate(spec: kitspec.KitSpec, out: Path) -> list[str]:
    """Write the sbx-v2 kit for ``spec`` into the new, empty directory ``out``; returns warnings.

    The ``files/`` payload is copied verbatim (symlinks stay symlinks, as with
    ``cp -a``) once every symlink in it is shown to resolve inside the kit.
    Raises :class:`KitTranslateError`.
    """
    if spec.kit_dir is None:
        raise KitTranslateError("the kit has no directory to translate")
    payload = spec.kit_dir / "files"
    if payload.is_dir():
        problems = kitspec.tree_symlinks_within(spec.kit_dir, payload)
        if problems:
            raise KitTranslateError("; ".join(problems))
        try:
            shutil.copytree(payload, out / "files", symlinks=True)
        except (OSError, shutil.Error) as exc:
            raise KitTranslateError(f"could not copy the kit's files: {exc}") from exc
    warnings: list[str] = []
    text = render_spec(spec, warnings)
    _write_private(out / "spec.yaml", text)
    return [*warnings, *readonly_warning(spec)]


# ---------------------------------------------------------------------------
# Private kit directories under the acq state directory.
# ---------------------------------------------------------------------------


def _private_dir(path: Path) -> Path:
    """Create ``path`` (0700), or accept it only as acq's own directory, never through a symlink."""
    try:
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
            raise KitTranslateError(f"{str(path)!r} is not a directory acq created; refusing to use it")
        if hasattr(os, "getuid") and st.st_uid != os.getuid():
            raise KitTranslateError(f"{str(path)!r} is owned by another user; refusing to use it")
        os.chmod(path, 0o700)
    except OSError as exc:
        raise KitTranslateError(f"could not prepare {str(path)!r}: {exc.strerror or exc}") from exc
    return path


def kit_root() -> Path:
    """``<state>/sbx-kits``, created private. Raises :class:`KitTranslateError`."""
    base = state.state_dir()
    try:
        base.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise KitTranslateError(f"could not create the acq state directory: {exc.strerror or exc}") from exc
    return _private_dir(base / KIT_DIR_NAME)


def _subdir(*parts: str) -> Path:
    path = kit_root()
    for part in parts:
        path = _private_dir(path / part)
    return path


def _write_private(path: Path, text: str) -> None:
    """Write ``text`` to a new file (0600, LF line endings), never through an existing link."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    try:
        fd = os.open(path, flags, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(text.encode("utf-8"))
    except OSError as exc:
        raise KitTranslateError(f"could not write {str(path)!r}: {exc.strerror or exc}") from exc


def _remove_tree(path: Path) -> None:
    """Remove an acq-owned directory (a symlink in its place is unlinked, never followed)."""
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.exists():
        shutil.rmtree(path)


def _valid_kit_dir(path: Path) -> bool:
    return path.is_dir() and not path.is_symlink() and (path / "spec.yaml").is_file()


def _tree_digest(root: Path) -> str:
    """A digest of every name, type, mode and byte under ``root`` (symlinks by target)."""
    digest = hashlib.sha256()
    for base, dirs, files in sorted(os.walk(root)):
        dirs.sort()
        for name in sorted([*dirs, *files]):
            path = Path(base) / name
            st = os.lstat(path)
            digest.update(f"{path.relative_to(root).as_posix()}\0{stat.S_IFMT(st.st_mode)}\0"
                          f"{stat.S_IMODE(st.st_mode) & 0o777}\0".encode())
            if stat.S_ISLNK(st.st_mode):
                digest.update(os.readlink(path).encode())
            elif stat.S_ISREG(st.st_mode):
                digest.update(path.read_bytes())
            digest.update(b"\0")
    return digest.hexdigest()


def _publish(parent: Path, stem: str, fill: Callable[[Path], None], *, by_content: bool = False) -> Path:
    """Build a kit directory in a private temporary one, then move it to ``parent/name`` if absent.

    ``name`` is ``stem``, or ``stem.<digest>`` with ``by_content``, so the
    same name always means the same content. An existing valid directory is
    reused and never removed: another create may be handing it to sbx right
    now. Raises :class:`KitTranslateError`.
    """
    try:
        tmp = Path(tempfile.mkdtemp(prefix=f".{stem[:40]}.", dir=parent))
    except OSError as exc:
        raise KitTranslateError(f"could not create a kit directory in {str(parent)!r}: {exc.strerror or exc}") from exc
    try:
        fill(tmp)
        dest = parent / (f"{stem}.{_tree_digest(tmp)[:16]}" if by_content else stem)
        if not _valid_kit_dir(dest):
            if dest.is_symlink() or dest.is_file():
                dest.unlink()  # never a kit acq made: nothing can be using it
            try:
                os.rename(tmp, dest)
            except OSError:
                if not _valid_kit_dir(dest):  # not a concurrent create's copy
                    raise
    except OSError as exc:
        shutil.rmtree(tmp, ignore_errors=True)
        raise KitTranslateError(f"could not place a generated kit in {str(parent)!r}: {exc.strerror or exc}") from exc
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    shutil.rmtree(tmp, ignore_errors=True)  # gone already when it was renamed into place
    _touch(dest)
    return dest


def _touch(path: Path) -> None:
    try:
        os.utime(path)
    except OSError:
        pass


def _slug(kit: Kit) -> str:
    """The kit's sanitized name; :func:`_publish` appends its content digest.

    Bash names the directory after the whole sanitized ref; this short form
    keeps the deepest payload path well inside the Windows path limit.
    """
    return "".join(chr(b) if b in _SLUG_BYTES else "_" for b in kit.name.encode("utf-8"))


def translated_kit(kit: Kit) -> Path:
    """``_acq_sbx_translate_kit`` for a bundled kit: its sbx-v2 directory (``v2/<name>.<digest>``).

    Raises :class:`KitTranslateError`; the caller must not create the sandbox.
    """
    if kit.spec.field("schemaVersion") != "hybrid/v1":
        raise KitTranslateError(f"built-in kit '{kit.name}' is not a neutral hybrid/v1 kit")
    warnings: list[str] = []

    def fill(tmp: Path) -> None:
        warnings.extend(translate(kit.spec, tmp))

    path = _publish(_subdir("v2"), _slug(kit), fill, by_content=True)
    for line in warnings:
        _warn(line)
    return path


# ---------------------------------------------------------------------------
# Generated kits: host git identity and the startup barrier.
# ---------------------------------------------------------------------------


def _safe_identity(value: str) -> bool:
    """One line and no tab: CR, NEL, LS, PS and the other line breaks would split the YAML value."""
    return "\t" not in value and value.splitlines() == [value]


def _identity_value(value: str) -> str:
    """:func:`yaml_quote`, and single quotes too for a value YAML would read as a bool, null or number.

    Bash emits such a value bare (``user.name = true`` becomes a boolean), so
    here the Python kit deliberately differs from Bash's.
    """
    quoted = yaml_quote(value)
    return f"'{value}'" if quoted == value and _YAML_COERCIBLE.fullmatch(value) else quoted


def _session():
    from .commands import session  # lazy: the commands package imports the adapters

    return session


def git_global_config_env() -> list[str]:
    """``acq_host_git_global_config_env``: the host's global git ``user.name``/``user.email``."""
    session = _session()
    out = []
    for key, var in (("user.name", "ACQ_GIT_USER_NAME"), ("user.email", "ACQ_GIT_USER_EMAIL")):
        value = session._host_git_config(key)
        if value and _safe_identity(value):
            out.append(f"{var}={value}")
    return out


_GIT_IDENTITY_INSTALL = (
    "setup:",
    "  install:",
    "    - command: |",
    '        [ -n "${ACQ_GIT_USER_NAME:-}" ] && git config --global user.name "$ACQ_GIT_USER_NAME" 2>/dev/null || true',
    '        [ -n "${ACQ_GIT_USER_EMAIL:-}" ] && git config --global user.email "$ACQ_GIT_USER_EMAIL" 2>/dev/null || true',
)
_GIT_IDENTITY_DESCRIPTION = ("Apply the forwarded host git identity (from the environment.variables block above) "
                             "to the guest global git config")


def git_identity_spec(env_records: list[str], config_records: list[str]) -> tuple[int, str] | None:
    """``_acq_sbx_git_identity_kit``'s ``(slug, spec.yaml)``, or ``None`` when there is no identity."""
    records = [r for r in (*env_records, *config_records) if r]
    if not records:
        return None
    slug = lock.posix_cksum("\n".join(records).encode("utf-8"))
    lines = ['schemaVersion: "2"', "kind: mixin", f"name: acq-git-identity-{slug}",
             "displayName: ACQ Git Identity", "description: Forward host git identity into the guest",
             "environment:", "  variables:"]
    for rec in records:
        key, _, value = rec.partition("=")
        lines.append(f"    {key}: {_identity_value(value)}")
    if config_records:
        lines += [*_GIT_IDENTITY_INSTALL, f"      description: {yaml_quote(_GIT_IDENTITY_DESCRIPTION)}"]
    return slug, "".join(f"{line}\n" for line in lines)


def git_identity_kit() -> Path | None:
    """The host git identity kit's directory (``generated/git-identity-<cksum>``), or ``None``."""
    env = [r for r in _session().host_git_identity_env() if _safe_identity(r.partition("=")[2])]
    built = git_identity_spec(env, git_global_config_env())
    if built is None:
        return None
    slug, text = built
    return _publish(_subdir("generated"), f"git-identity-{slug}", lambda tmp: _write_private(tmp / "spec.yaml", text))


def startup_barrier_spec(token: str) -> str:
    """``_acq_sbx_startup_barrier_kit``'s ``spec.yaml``: it runs after every earlier startup command."""
    if not _BARRIER_TOKEN.fullmatch(token):
        raise ValueError(f"unsafe startup-barrier token: {token!r}")
    return (
        'schemaVersion: "2"\n'
        "kind: mixin\n"
        "name: acq-startup-barrier\n"
        "displayName: ACQ Startup Barrier\n"
        "description: Marks completion of prior non-background startup commands for acq\n"
        "setup:\n"
        "  startup:\n"
        "    - command:\n"
        "        - sh\n"
        "        - -c\n"
        "        - |\n"
        "          mkdir -p /tmp/acq\n"
        f"          printf '%s\\n' '{token}' > {BARRIER_PATH}\n"
    )


def new_barrier_token() -> str:
    """Bash's ``acq-$$-$(date +%s)-$RANDOM-$RANDOM``."""
    return f"acq-{os.getpid()}-{int(time.time())}-{secrets.randbelow(32768)}-{secrets.randbelow(32768)}"


def startup_barrier_kit(token: str) -> Path:
    text = startup_barrier_spec(token)
    return _publish(_subdir("generated"), f"startup-barrier-{token}",
                    lambda tmp: _write_private(tmp / "spec.yaml", text))


@dataclass(frozen=True)
class CreateKits:
    """The ``sbx create`` kit flags, the token the startup barrier kit writes, and that kit's directory."""

    flags: list[str]
    barrier_token: str
    barrier_dir: Path


def discard_barrier(prepared: CreateKits) -> None:
    """Remove this create's barrier kit once ``sbx create`` has read it (best-effort)."""
    try:
        _remove_tree(prepared.barrier_dir)
    except OSError:
        pass


def prune_stale(keep: Iterable[Path], *, now: float | None = None) -> None:
    """Remove generated kit directories unused for :data:`STALE_AGE_S` (best-effort).

    Directories this create uses are kept, and a reused one has its time
    refreshed, so only kits from an older bundle, an old identity or a crashed
    create are pruned.
    """
    cutoff = (time.time() if now is None else now) - STALE_AGE_S
    kept = {Path(p) for p in keep}
    for sub in ("v2", "generated"):
        try:
            entries = list(_subdir(sub).iterdir())
        except (KitTranslateError, OSError):
            continue
        for entry in entries:
            try:
                if entry not in kept and os.lstat(entry).st_mtime < cutoff:
                    _remove_tree(entry)
            except OSError:
                pass


def prepare(kits: Iterable[Kit]) -> CreateKits:
    """Every ``--kit`` flag for a create: the kits in order, the git identity kit, then the barrier.

    Raises :class:`KitTranslateError`: a kit that cannot be prepared stops the create.
    """
    flags: list[str] = []
    try:
        for kit in kits:
            flags += ["--kit", str(translated_kit(kit))]
        identity = git_identity_kit()
        if identity is not None:
            flags += ["--kit", str(identity)]
        token = new_barrier_token()
        barrier = startup_barrier_kit(token)
        flags += ["--kit", str(barrier)]
    except OSError as exc:
        raise KitTranslateError(f"could not prepare the sandbox's kits: {exc.strerror or exc}") from exc
    prune_stale(Path(flags[i + 1]) for i in range(0, len(flags), 2))
    return CreateKits(flags, token, barrier)


# ---------------------------------------------------------------------------
# Selection -> parsed kits (the bundle only; fail closed otherwise).
# ---------------------------------------------------------------------------


def resolve(selection: kitspec.KitSelection) -> list[Kit]:
    """Verify the bundle and parse every selected kit; raises :class:`sbx.SbxError`."""
    try:
        problems = kitspec.verify_bundle()
    except kitspec.KitSpecError as exc:
        problems = [str(exc)]
    if problems:
        raise sbx.SbxError(
            errors.VALIDATION_FAILED,
            f"the built-in kit bundle does not match its pinned content ({problems[0]})",
            "reinstall acq; it will not apply a kit bundle it cannot verify",
        )
    out: list[Kit] = []
    seen: set[str] = set()
    for sel in selection.kits:
        if sel.bundled is None:
            raise sbx.SbxError(
                errors.UNSUPPORTED,
                f"kit {sel.ref!r} ({sel.role} kit) would have to be fetched; the Python acq "
                "applies only its pinned built-in kits",
                "drop it from --kit, ACQ_EXTRA_KITS, ACQ_PROVIDER_KITS or config extra_kits/provider_kit, "
                "or use the Bash acq (ACQ_IMPL=bash) for kits that must be fetched",
            )
        if sel.ref in seen:
            continue
        seen.add(sel.ref)
        try:
            spec = kitspec.load_bundled_kit(sel.bundled)
        except kitspec.KitSpecError as exc:
            raise sbx.SbxError(errors.VALIDATION_FAILED, f"cannot read built-in kit '{sel.bundled}': {exc}",
                               "reinstall acq") from exc
        out.append(Kit(sel.bundled, sel.role, spec, sel.ref))
    return out


def bundled_kit(name: str, role: str = "cli") -> Kit:
    """One verified bundled kit by name (``acq kit apply``)."""
    sel = kitspec.SelectedKit(kitspec.builtin_kit_ref(name), role, name)
    return resolve(kitspec.KitSelection((sel,), 0, 0, None))[0]


def select(agent: str, cli_kits: list[str], *, image_is_default: bool,
           extras: list[str] | None = None) -> tuple[list[Kit], kitspec.KitSelection]:
    """Select, verify and parse a sandbox's kit set (Bash ``_build_kit_list``).

    As on msb, config ``extra_kits`` take part, recorded ``extras`` replace
    ``ACQ_EXTRA_KITS``, and on the default image the agent's bundled kit is
    required. Raises :class:`kitspec.KitSelectionError` or :class:`sbx.SbxError`.
    """
    required = agent if agent in kitspec.AGENT_BUNDLE_KITS and image_is_default else None
    env = {**os.environ, "ACQ_EXTRA_KITS": " ".join(extras)} if extras else os.environ
    selection = kitspec.select_kits(agent, cli_kits=cli_kits, env=env, configured_extras=True,
                                    required_agent_kit=required)
    selection.require()
    return resolve(selection), selection


# ---------------------------------------------------------------------------
# Host-config directory (Bash acq_host_config_* for sbx).
# ---------------------------------------------------------------------------


def host_config_dir(name: str) -> Path:
    """The sbx sandbox's host-config directory, at the path Bash uses."""
    return lock.bash_provenance_dir() / "sbx" / f"{lock.bash_sandbox_key(name)}.config"


def hc_write(name: str, key: str, value: str) -> None:
    """Write one key (0600, atomic). Raises ``OSError``."""
    if not _KEY.fullmatch(key) or key in (".", ".."):
        raise ValueError(f"unsafe host-config key: {key!r}")
    root = host_config_dir(name)
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o711)
    state.atomic_write_text(root / key, value)
    (root / key).chmod(0o600)


def hc_read(name: str, key: str) -> str:
    """One key's value ("" when absent or unreadable), trailing newlines dropped as ``$(...)`` does."""
    if not _KEY.fullmatch(key):
        return ""
    try:
        return (host_config_dir(name) / key).read_text(encoding="utf-8").rstrip("\n")
    except (OSError, UnicodeDecodeError):
        return ""


def clear_instance_state(name: str) -> None:
    """Drop the keys that describe a previous guest of the same name."""
    root = host_config_dir(name)
    if not root.is_dir() or root.is_symlink():
        return
    for entry in root.iterdir():
        if entry.name in _INSTANCE_KEYS or entry.name.startswith(_INSTANCE_PREFIXES):
            try:
                entry.unlink()
            except OSError:
                pass


def remove_host_config(name: str) -> None:
    """Remove the sandbox's host-config directory once its guest is gone (best-effort)."""
    path = host_config_dir(name)
    if path.is_symlink():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path, ignore_errors=True)


def _builtin_ref(name: str) -> str:
    return kitspec.builtin_kit_ref(name)


def _provider_ref(selection: kitspec.KitSelection) -> str:
    """The first selected provider ref ("" when none), as Bash's heal resolves it."""
    return next((k.ref for k in selection.kits if k.role == "provider"), "")


def seed_records(name: str, selection: kitspec.KitSelection) -> None:
    """Create-time host records (``_acq_sbx_seed_extra_kit_record`` / ``_seed_builtin_kit_record``).

    They describe what the host passed to the ``sbx create`` it saw succeed,
    never the guest's own report. A write failure is a warning, as in Bash.
    """
    # Every requested extra and --kit ref, as Bash records them, even one that
    # duplicates a built-in kit and so was passed to sbx only once.
    extras = [k.ref for k in selection.kits if k.role in ("extra", "cli")]
    if extras:
        try:
            hc_write(name, "extra-kits", "\n".join(extras))
        except OSError:
            _warn(f"acq: warning: could not record extra kits for '{name}'; re-attach may re-attempt them.")
    records = [f"zscaler-ca-certificate {_builtin_ref('zscaler-ca-certificate')}"]
    if selection.provider_error is None and _provider_ref(selection):
        records.append(f"{PROVIDER_RECORD_NAME} {_provider_ref(selection)}")
    records.append(f"agentic-coding-playbook {_builtin_ref('agentic-coding-playbook')}")
    try:
        hc_write(name, "builtin-kits", "\n".join(records))
    except OSError:
        _warn(f"acq: warning: could not record built-in kits for '{name}'; re-attach may re-apply them.")


def _barrier_script(token: str) -> str:
    return f"test \"$(cat '{BARRIER_PATH}' 2>/dev/null)\" = '{token}' && echo ready"


def wait_startup_barrier(name: str, token: str) -> bool:
    """``_acq_sbx_wait_for_startup_barrier``: the guest wrote this create's token in time.

    It is a readiness signal only (a guest could write it early), so no host
    record depends on it.
    """
    deadline = time.monotonic() + barrier_timeout_s()
    while True:
        out = sbx.exec_capture(name, _barrier_script(token))
        if out is not None and "ready" in out.split("\n"):
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(BARRIER_POLL_S, remaining))


def barrier_timeout_s() -> float:
    return timeouts.env_seconds(BARRIER_TIMEOUT_ENV, DEFAULT_BARRIER_TIMEOUT_S)


# ---------------------------------------------------------------------------
# Mid-life kits: ``sbx kit add`` (acq_backend_apply_kit / ensure_kits_applied).
# ---------------------------------------------------------------------------

RECREATE_NOTICE = (
    "acq: sbx >= 0.38 cannot extend a live sandbox with startup-bearing kits\n"
    "     (every built-in acq kit declares startup commands). The kit set is\n"
    "     fixed at create time on this sbx version.\n"
    "     To pick up the current bundle, recreate the sandbox (this discards\n"
    "     its session/context):\n"
    "       acq rm '{name}' && acq run opencode /path/to/your/project"
)


@dataclass
class HealResult:
    """The outcome of a heal: which kits were added, and whether every built-in is in place."""

    ok: bool = True
    healed: bool = False
    added: list[str] = field(default_factory=list)
    failed: list[str] = field(default_factory=list)
    notice_shown: bool = False


def _add(name: str, kit: Kit, label: str, result: HealResult, *, counts: bool = True) -> bool:
    """Translate and ``sbx kit add`` one kit; classify the outcome as Bash does."""
    try:
        code = sbx.kit_add(name, str(translated_kit(kit)))
    except KitTranslateError as exc:
        _warn(f"acq(sbx): error: no usable kit to add to '{name}' ({exc}).")
        code = sbx.KIT_ADD_FAILED
    if code == sbx.KIT_ADD_OK:
        result.healed = True
        result.added.append(kit.name)
        return True
    if code == sbx.KIT_ADD_RECREATE:
        if not result.notice_shown:
            _warn(RECREATE_NOTICE.format(name=name))
            result.notice_shown = True
    else:
        _warn(f"acq: warning: 'sbx kit add' ({label}) failed for '{name}'.")
    if counts:
        result.ok = False
        result.failed.append(kit.name)
    return False


def _recorded(name: str, kit: str, ref: str) -> bool:
    return f"{kit} {ref}" in hc_read(name, "builtin-kits").split("\n")


def _record(name: str, kit: str, ref: str) -> None:
    """Record KIT at REF, replacing an older line for KIT (``_acq_sbx_builtin_kit_record``)."""
    kept = [line for line in hc_read(name, "builtin-kits").split("\n")
            if line.split() and not line.startswith(f"{kit} ")]
    try:
        hc_write(name, "builtin-kits", "\n".join([*kept, f"{kit} {ref}"]))
    except OSError:
        _warn(f"acq: warning: could not record built-in kit '{kit}' for '{name}'; re-attach may re-attempt it.")


def _builtin_steps(kits: list[Kit], selection: kitspec.KitSelection) -> list[tuple[Kit, str, str, str]]:
    """``(kit, record key, record ref, label)`` for the CA, provider and playbook kits, in heal order."""
    by_ref = {k.ref: k for k in kits}
    steps = []
    zscaler, playbook = _builtin_ref("zscaler-ca-certificate"), _builtin_ref("agentic-coding-playbook")
    provider = _provider_ref(selection)
    for ref, key, label in ((zscaler, "zscaler-ca-certificate", "Zscaler CA kit"),
                            (provider, PROVIDER_RECORD_NAME, "provider kit"),
                            (playbook, "agentic-coding-playbook", "playbook kit")):
        if ref and ref in by_ref:
            steps.append((by_ref[ref], key, ref, label))
    return steps


def _force_refresh_kits(kits: list[Kit], selection: kitspec.KitSelection) -> list[tuple[Kit, str]]:
    """On a forced reapply: git-ssh-sign, then every other built-in support, provider and agent kit.

    The CA, playbook and first provider kit were handled by the steps before.
    Bash picks the rest by position, assuming exactly one provider kit; here the
    selection's roles decide, so no provider kit, or several, still refresh
    every kit exactly once.
    """
    by_ref = {k.ref: k for k in kits}
    handled = {_builtin_ref("zscaler-ca-certificate"), _builtin_ref("agentic-coding-playbook"),
               _builtin_ref("git-ssh-sign"), _provider_ref(selection)}
    out = []
    signing = by_ref.get(_builtin_ref("git-ssh-sign"))
    if signing is not None:
        out.append((signing, "git-ssh-sign kit"))
    for sel in selection.kits[:selection.builtin_count]:
        kit = by_ref.get(sel.ref)
        if kit is None or sel.ref in handled:
            continue
        handled.add(sel.ref)
        out.append((kit, "agent kit" if sel.role == "agent" else "support kit"))
    return out


def ensure_kits_applied(name: str, kits: list[Kit], selection: kitspec.KitSelection, *,
                        force: bool = False) -> HealResult:
    """The sbx heal (``acq_backend_ensure_kits_applied``).

    Each built-in kit not recorded as applied at its pinned ref (all of them
    when ``force``) is added with ``sbx kit add``. sbx 0.38 and later refuse a
    kit with startup commands mid-life, so on those versions the heal reports
    that the sandbox must be recreated. ``ok`` is False when any built-in kit
    could not be added; extra kits never affect it.
    """
    force = force or os.environ.get(FORCE_REAPPLY_ENV) == "1"
    result = HealResult()
    for kit, key, ref, label in _builtin_steps(kits, selection):
        if not force and _recorded(name, key, ref):
            continue
        _warn(f"acq: '{name}' is missing the {label}; injecting with 'sbx kit add'...")
        if _add(name, kit, label, result):
            if key == PROVIDER_RECORD_NAME:
                sbx.exec_capture(name, OPENCODE_CONFIG_LINK_FIX)
            _record(name, key, ref)
    if force:
        for kit, label in _force_refresh_kits(kits, selection):
            _add(name, kit, label, result)
    _heal_git_identity(name, result)
    _heal_extras(name, kits, result)
    if result.ok and result.healed and not _wait_exec_ready(name):
        _warn(f"acq: warning: '{name}' did not become exec-ready after kit heal.")
        result.ok = False
    return result


def _heal_git_identity(name: str, result: HealResult) -> None:
    try:
        identity = git_identity_kit()
    except KitTranslateError:
        identity = None
    if identity is None:
        return
    code = sbx.kit_add(name, str(identity))
    if code == sbx.KIT_ADD_OK:
        result.healed = True
    elif code == sbx.KIT_ADD_RECREATE and not result.notice_shown:
        _warn(RECREATE_NOTICE.format(name=name))
        result.notice_shown = True
    elif code != sbx.KIT_ADD_RECREATE:
        _warn(f"acq: warning: 'sbx kit add' (git identity env) failed for '{name}'.")


def _heal_extras(name: str, kits: list[Kit], result: HealResult) -> None:
    """Extra kits not in the host ``extra-kits`` record (one original ref per line)."""
    applied = hc_read(name, "extra-kits").split("\n")
    for kit in kits:
        if kit.role != "extra" or kit.ref in applied:
            continue
        _warn(f"acq: applying extra kit to '{name}': {kit.ref}")
        if _add(name, kit, "extra kit", result, counts=False):
            _append_extra(name, kit.ref)


def _append_extra(name: str, ref: str) -> None:
    current = hc_read(name, "extra-kits")
    try:
        hc_write(name, "extra-kits", f"{current}\n{ref}" if current else ref)
    except OSError:
        _warn(f"acq: warning: could not record extra kit '{ref}' for '{name}'; re-attach may re-attempt it.")


def _wait_exec_ready(name: str) -> bool:
    deadline = time.monotonic() + sbx.ready_timeout_s()
    while not sbx.exec_ready(name):
        if time.monotonic() >= deadline:
            return False
        time.sleep(min(BARRIER_POLL_S, max(deadline - time.monotonic(), 0)))
    return True


def apply_single(name: str, kit: Kit) -> None:
    """``acq_backend_apply_kit``: add one kit to a running sandbox.

    Raises :class:`sbx.SbxError`: ``unsupported_capability`` when sbx refuses
    the kit mid-life (it declares startup commands, so the sandbox must be
    recreated), ``failure`` otherwise.
    """
    try:
        code = sbx.kit_add(name, str(translated_kit(kit)))
    except KitTranslateError as exc:
        raise sbx.SbxError(errors.FAILURE, f"could not prepare kit '{kit.name}': {exc}", "reinstall acq") from exc
    if code == sbx.KIT_ADD_RECREATE:
        raise sbx.SbxError(
            errors.UNSUPPORTED,
            f"sbx cannot extend the live sandbox '{name}' with kit '{kit.name}', which declares startup "
            "commands; the kit set is fixed at create time",
            f"recreate the sandbox (this discards its session/context): acq rm '{name}' && "
            "acq run opencode /path/to/your/project",
        )
    if code != sbx.KIT_ADD_OK:
        raise sbx.SbxError(errors.FAILURE, f"'sbx kit add' failed for kit '{kit.name}' in sandbox '{name}'",
                           "check sbx logs and retry")
