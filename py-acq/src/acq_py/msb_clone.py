"""Clone mode on msb (ADR-0027): a disposable primary workspace.

msb mounts workspaces straight from the host, so ``--clone`` (or
``ACQ_CLONE=1``) is emulated with a managed host-side scratch clone, as the
Bash adapter does (``acq.backends/msb.sh``, ``_acq_msb_clone_*``):

* ``git clone --no-local --no-hardlinks`` the primary workspace into
  ``<clones>/<sandbox>/<repo>``, where ``<clones>`` is ``ACQ_MSB_CLONES_DIR``
  or ``<state dir>/clones``. ``--no-hardlinks`` keeps the copy physical: a
  same-filesystem clone would hard-link object files, and the guest, which can
  write the scratch, could then change inodes the real repository shares.
* The scratch is mounted read-write at the ORIGINAL workspace's guest path, so
  the agent's start directory and kits behave as in a non-clone run.
* ``<clones>/<sandbox>/.origin`` records the source checkout, and a
  ``sandbox-<sandbox>`` remote in that checkout points at the scratch, so
  ``git fetch sandbox-<sandbox>`` brings the agent's branches back.
* ``acq rm`` warns about commits the checkout never fetched, then removes the
  remote and the scratch once the sandbox is gone.

The layout and the hooks path are the Bash adapter's, so either implementation
can remove a clone sandbox the other created, and the Python ``create
--recreate`` can rebuild one the Bash acq created.

Every host-side git call against the workspace goes through :func:`ws_git`.
The workspace is mounted read-write into sandboxes that do not use clone mode,
so its repository config, attributes and hooks are untrusted here: git runs
without a pager, fsmonitor, hooks (``core.hooksPath`` names a path under acq's
state dir that must not exist), the untracked cache, any transport (the clone
re-allows only ``file``), submodule recursion, or any filter driver the config
defines (each is blanked through ``GIT_CONFIG_COUNT``). The caller's inherited
git environment (``GIT_DIR``, ``GIT_WORK_TREE``, ``GIT_CONFIG*`` and the rest
of ``git rev-parse --local-env-vars``) is removed first (:mod:`gitrepos`).
Before the clone, the workspace must be an ordinary repository checkout: no
gitfile, no ``commondir``, no symlink anywhere below ``.git`` but in
``.git/hooks``, and git's directories resolving to ``<workspace>/.git``.

Refusals are raised as :class:`msb.MsbError` with Bash's text: the message is
Bash's first line without its ``acq(msb): error:`` prefix, the remediation its
continuation lines. Notes and warnings are written to stderr as Bash writes
them.
"""

from __future__ import annotations

import ntpath
import os
import re
import shutil
import stat
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from . import errors, gitrepos, hostexec, kit_fetch, state, userdirs
from .msb import MsbError

# Module-local seam for the host OS class (as ``msb.WINDOWS``).
WINDOWS = os.name == "nt"

CLONES_ENV = "ACQ_MSB_CLONES_DIR"
HOOKS_NAME = ".git-hooks-disabled"
ORIGIN_FILE = ".origin"
REMOTE_PREFIX = "sandbox-"

# A sandbox name lands in host paths (the scratch dir, and its removal) and in
# the remote name, so it must be one safe path component.
_NAME_RE = re.compile(r"[A-Za-z0-9._-]+", re.ASCII)
_HEX_RE = re.compile(r"[0-9a-f]+", re.ASCII)
_DRIVE_POSIX_RE = re.compile(r"/([A-Za-z])(/.*)?", re.DOTALL)
_UNC_POSIX_RE = re.compile(r"/unc/([^/]+)/(.+)", re.DOTALL)
_FILTER_BLANK = {".clean": "", ".smudge": "", ".process": "", ".required": "false"}
_FALSE_WORDS = frozenset({"false", "no", "off"})

# Bounds on what is read back from the guest-writable scratch at rm time: a
# loose ref is one object name, and a packed-refs file this large is treated
# as unverifiable (the warning is shown) rather than read whole.
_LOOSE_REF_CAP = 64 * 1024
_PACKED_REFS_CAP = 64 * 1024 * 1024
_READ_FLAGS = kit_fetch._FILE_FLAGS

# Seam for the private-dir chmod, so a test can make it fail.
_chmod = os.chmod


def _say(*lines: str) -> None:
    for line in lines:
        print(f"acq(msb): {line}", file=sys.stderr)


def _refuse(message: str, *rest: str, code: str = errors.VALIDATION_FAILED) -> MsbError:
    return MsbError(code, message, " ".join(rest) or None)


def _show(exc: MsbError) -> None:
    """Print a refusal the way Bash prints it inline (error line, then the rest)."""
    _say(f"error: {exc.message}")
    if exc.remediation:
        _say(f"  {exc.remediation}")


def valid_name(name: str) -> bool:
    return bool(_NAME_RE.fullmatch(name)) and name not in (".", "..")


def check_name(name: str) -> None:
    if not valid_name(name):
        raise _refuse(f"--clone: invalid sandbox name '{name}' for the scratch clone",
                      "(allowed: letters, digits, '.', '_', '-').")


# ---------------------------------------------------------------------------
# Locations.
# ---------------------------------------------------------------------------


def _state_dir() -> Path:
    try:
        return state.state_dir()
    except userdirs.UserDirError:
        raise _refuse("--clone: ACQ_STATE_DIR must be an absolute path: "
                      f"{os.environ.get('ACQ_STATE_DIR', '')}") from None


def clones_root() -> Path:
    """``ACQ_MSB_CLONES_DIR`` (absolute only), else ``<state dir>/clones``."""
    try:
        override = userdirs.path_override(CLONES_ENV)
    except userdirs.UserDirError as exc:
        raise _refuse(exc.message, exc.remediation) from None
    return override if override is not None else _state_dir() / "clones"


def hooks_path() -> str:
    return str(_state_dir() / HOOKS_NAME)


def _canon(path: str) -> str:
    return os.path.realpath(path)


def _same(a: str, b: str) -> bool:
    return os.path.normcase(_canon(a)) == os.path.normcase(_canon(b))


def origin_text(ws: str) -> str:
    """How ``.origin`` records a checkout: its canonical path, with ``/`` on Windows."""
    return ws.replace("\\", "/") if WINDOWS else ws


def origin_from_text(text: str) -> str:
    """The checkout a ``.origin`` names, read back as a native path.

    Bash on Windows (Git Bash) records the POSIX form ``/c/Users/me/proj`` or
    ``/unc/server/share/proj``; both are turned back into native paths there.
    """
    value = text.rstrip("\n")
    if not WINDOWS:
        return value
    match = _DRIVE_POSIX_RE.fullmatch(value)
    if match:
        return ntpath.normpath(f"{match.group(1).upper()}:{match.group(2) or '/'}")
    match = _UNC_POSIX_RE.fullmatch(value)
    if match:
        return ntpath.normpath(f"\\\\{match.group(1)}\\{match.group(2)}")
    return ntpath.normpath(value) if value else value


def _read_origin(sandbox_dir: Path) -> str:
    try:
        return origin_from_text((sandbox_dir / ORIGIN_FILE).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError):
        return ""


def _find_scratch(sandbox_dir: Path) -> Path | None:
    """The last ``<dir>/*/`` holding a ``.git`` directory (Bash's glob order)."""
    try:
        names = sorted(n for n in os.listdir(sandbox_dir) if not n.startswith("."))
    except OSError:
        return None
    found = None
    for name in names:
        candidate = sandbox_dir / name
        if candidate.is_dir() and (candidate / ".git").is_dir():
            found = candidate
    return found


def present(name: str) -> bool:
    """True when a scratch-clone directory exists for ``name`` (a host record of it)."""
    if not valid_name(name):
        return False
    try:
        return os.path.lexists(clones_root() / name)
    except MsbError:
        return False


def _lstat_link(info: os.stat_result) -> bool:
    attrs = getattr(info, "st_file_attributes", 0)
    return stat.S_ISLNK(info.st_mode) or bool(attrs & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0))


def _make_owner_writable(directory: str, root: str) -> bool:
    """chmod 0700 the real directory ``directory`` inside ``root``; never a link, never outside ``root``.

    The parent is opened without following a link and the entry is checked
    through that fd, then changed by name relative to it, so a directory with
    no permissions at all (which cannot be opened itself) can be fixed too.
    acq removes a scratch only once its guest is gone, so nothing races the
    check and the change.
    """
    parent, base = os.path.split(directory)
    try:
        pfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return False
    try:
        info = os.stat(base, dir_fd=pfd, follow_symlinks=False)
        if _lstat_link(info) or not stat.S_ISDIR(info.st_mode):
            return False
        if os.path.commonpath([os.path.join(os.path.realpath(parent), base), root]) != root:
            return False
        os.chmod(base, 0o700, dir_fd=pfd)
        return True
    except (OSError, ValueError):
        return False
    finally:
        os.close(pfd)


def remove_guest_tree(path: Path) -> None:
    """Remove a tree the guest could write (best-effort), changing nothing outside it.

    The guest controls what is inside: links to host paths, directories
    without write or search permission. Nothing that ``os.lstat`` reports as a
    link is ever chmodded or followed (``shutil.rmtree`` unlinks links). On
    POSIX a permission failure is retried after making the entry's real
    parent directory (or the unreadable directory itself) owner-writable,
    checked through its parent's fd to be a real directory inside the tree
    (:func:`_make_owner_writable`). On Windows a read-only non-link entry is made writable and
    retried; links are never touched there either.
    """
    try:
        info = os.lstat(path)
    except OSError:
        return
    if _lstat_link(info) or not stat.S_ISDIR(info.st_mode):
        try:
            os.unlink(path)
        except OSError:
            try:
                os.rmdir(path)  # a Windows directory junction
            except OSError:
                pass
        return
    root = os.path.realpath(path)

    def retry(func, target, exc):
        try:
            if isinstance(exc, FileNotFoundError):
                return
            if WINDOWS:
                if not _lstat_link(os.lstat(target)):
                    os.chmod(target, stat.S_IWRITE | stat.S_IREAD)
                    func(target)
                return
            if not isinstance(exc, PermissionError):
                return
            if func in (os.unlink, os.rmdir, os.remove):
                if _make_owner_writable(os.path.dirname(target), root):
                    func(target)
            elif _make_owner_writable(target, root):
                remove_guest_tree(Path(target))  # a directory it could not list
        except OSError:
            pass

    try:
        shutil.rmtree(path, onexc=retry)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Host-side git.
# ---------------------------------------------------------------------------


@dataclass
class _Prep:
    hooks: str
    env: dict[str, str] = field(default_factory=dict)
    cfg: list[str] = field(default_factory=list)


def _git_program() -> str:
    git = hostexec.which("git")
    if git is None:
        raise _refuse("--clone: git is required to clone the workspace, and it was not found on PATH",
                      "install git, then re-run", code=errors.FAILURE)
    return git


def _env(*, keep: bool = False) -> dict[str, str]:
    """The caller's environment without its git redirects; refuses if any survived."""
    env = gitrepos.git_env(keep_command_scope=keep)
    if gitrepos.redirects_left(env, keep_command_scope=keep):
        raise _refuse("--clone: acq cannot clear the inherited git environment (GIT_DIR and the like);",
                      "refusing to run git.", code=errors.FAILURE)
    # An inherited GIT_ALLOW_PROTOCOL would override protocol.allow=never.
    env.pop("GIT_ALLOW_PROTOCOL", None)
    return env


def _run(argv: list[str], env: dict[str, str], *, input_text: str | None = None,
         show_stderr: bool = False) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(  # nosec B603 # an absolute git and a fixed argument list, no shell
            argv, env=env, input=input_text, stdin=subprocess.DEVNULL if input_text is None else None,
            stdout=subprocess.PIPE, stderr=None if show_stderr else subprocess.PIPE, text=True,
            encoding="utf-8", errors="surrogateescape", check=False,
        )
    except OSError as exc:
        raise _refuse(f"--clone: could not run git: {exc.strerror or exc}",
                      "check the git installation, then re-run", code=errors.FAILURE) from exc


def git_version_ge(major: int, minor: int) -> bool:
    """True when the host git is at least MAJOR.MINOR (2.31 reads GIT_CONFIG_COUNT)."""
    proc = _run([_git_program(), "--version"], _env())
    if proc.returncode != 0:
        return False
    version = proc.stdout.strip().removeprefix("git version ")
    parts = version.split(".")
    maj, mnr = parts[0], parts[1] if len(parts) > 1 else parts[0]
    if not (maj.isascii() and maj.isdigit() and mnr.isascii() and mnr.isdigit()):
        return False
    return int(maj) > major or (int(maj) == major and int(mnr) >= minor)


def _filter_blank(key: str) -> str | None:
    if not key.startswith("filter."):
        return None
    for suffix, value in _FILTER_BLANK.items():
        if key.endswith(suffix) and len(key) >= len("filter.") + len(suffix):
            return value
    return None


def _filter_settings(ws: str, hooks: str) -> _Prep:
    """Blank every filter driver ``ws``'s config defines (a config read starts nothing)."""
    proc = _run([_git_program(), "--no-pager", "-C", ws, "config", "--name-only", "-z", "--get-regexp",
                 r"^filter\."], _env())
    if proc.returncode not in (0, 1):
        raise _refuse(f"--clone: could not read the git config for {ws} (git exit {proc.returncode});",
                      "refusing to run git there without knowing its filter drivers.")
    prep = _Prep(hooks)
    count, envok = 0, None
    for key in (k for k in proc.stdout.split("\0") if k):
        value = _filter_blank(key)
        if value is None:
            continue
        envok = git_version_ge(2, 31) if envok is None else envok
        if envok:
            prep.env.update({f"GIT_CONFIG_KEY_{count}": key, f"GIT_CONFIG_VALUE_{count}": value})
            count += 1
        elif "=" in key:
            raise _refuse("--clone: the repository config defines a filter driver whose",
                          f"name contains '=' ({key}). This git cannot disable it; git 2.31 or",
                          "later can. Upgrade git, or remove or rename that filter, then re-run.")
        else:
            prep.cfg += ["-c", f"{key}={value}"]
    if count:
        prep.env["GIT_CONFIG_COUNT"] = str(count)
    return prep


def prep(ws: str) -> _Prep:
    """The wrapper's per-call settings for ``ws``; refuses when they cannot be made safe.

    Hooks stay off only while the hooks path does not exist, so an existing
    file, directory or link there fails closed rather than becoming a hooks
    directory. Runs before every wrapped call, as in Bash.
    """
    hooks = hooks_path()
    if not os.path.isabs(hooks):
        raise _refuse(f"--clone: ACQ_STATE_DIR must be an absolute path: {os.environ.get('ACQ_STATE_DIR', '')}")
    if os.path.lexists(hooks):
        raise _refuse(f"--clone: {hooks} exists. acq disables git hooks by",
                      "pointing core.hooksPath at that path and needs it absent. Remove it, then re-run.")
    return _filter_settings(ws, hooks)


def ws_git(ws: str, *args: str, keep: bool = False, input_text: str | None = None,
           show_stderr: bool = False) -> subprocess.CompletedProcess[str]:
    """Run git against the workspace repository with its config-driven programs off.

    ``keep`` keeps the user's command-scope config and leaves the filter
    entries off (Bash ``_acq_msb_git_ws_cmdscope``): only for a ``git config``
    read, which starts no program.
    """
    settings = prep(ws)
    env = _env(keep=keep)
    if not keep:
        env.update(settings.env)
    env.update({"GIT_NO_LAZY_FETCH": "1", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"})
    argv = [_git_program(), "--no-pager", "-c", "core.fsmonitor=false", "-c", f"core.hooksPath={settings.hooks}",
            "-c", "core.untrackedCache=false", "-c", "protocol.allow=never", "-c", "submodule.recurse=false",
            *settings.cfg, "-C", ws, *args]
    return _run(argv, env, input_text=input_text, show_stderr=show_stderr)


def scratch_git(scratch: str, *args: str) -> subprocess.CompletedProcess[str]:
    """Run git in a scratch acq just created and has not yet exposed to the guest."""
    return _run([_git_program(), "--no-pager", "-C", scratch, *args], _env())


def _nul_values(out: str) -> list[str]:
    values = out.split("\0")
    if values and values[-1] == "":
        values.pop()
    return values


# ---------------------------------------------------------------------------
# Preflight.
# ---------------------------------------------------------------------------


def repo_root(ws: str) -> str:
    """``ws`` canonicalized, or a refusal when it is not a repository's root."""
    proc = ws_git(ws, "rev-parse", "--show-toplevel")
    if proc.returncode != 0:
        raise _refuse(f"--clone: workspace is not a git repository: {ws}",
                      "--clone runs the agent on a clone of the primary workspace's repo.")
    top = _canon(proc.stdout.rstrip("\n"))
    if not _same(ws, top):
        raise _refuse(f"--clone: workspace must be the repository root: {top}")
    return _canon(ws)


def _is_link_entry(entry: os.DirEntry) -> bool:
    if entry.is_symlink() or entry.is_junction():
        return True
    attrs = getattr(entry.stat(follow_symlinks=False), "st_file_attributes", 0)
    return bool(attrs & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0))


def _is_link_path(path: str) -> bool:
    if os.path.islink(path) or os.path.isjunction(path):
        return True
    try:
        attrs = getattr(os.lstat(path), "st_file_attributes", 0)
    except OSError:
        return False
    return bool(attrs & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0))


def _scan_git_dir(gitdir: str) -> tuple[bool, bool]:
    """``(link found, scan failed)`` for every entry below ``gitdir``.

    A top-level ``hooks`` is skipped before it is read (hooks never run). The
    walk never follows a link, lists every directory and keeps going after a
    find, so a directory it cannot list is reported even when a link was seen.
    """
    linked, failed = False, False
    stack = [(gitdir, True)]
    while stack:
        path, top = stack.pop()
        try:
            with os.scandir(path) as entries:
                for entry in entries:
                    if top and entry.name == "hooks":
                        continue
                    if _is_link_entry(entry):
                        linked = True
                    elif entry.is_dir(follow_symlinks=False):
                        stack.append((entry.path, False))
        except OSError:
            failed = True
    return linked, failed


def _git_dirs_problem(ws: str, want: str) -> str | None:
    def rev_parse(flag: str) -> str:
        proc = ws_git(ws, "rev-parse", flag)
        return proc.stdout.rstrip("\n") if proc.returncode == 0 else ""

    gd, common = rev_parse("--absolute-git-dir"), rev_parse("--git-common-dir")
    if common and not (os.path.isabs(common) or re.match(r"[A-Za-z]:", common)):
        common = os.path.join(ws, common)
    gd, common = (_canon(gd) if gd else ""), (_canon(common) if common else "")
    target = os.path.normcase(_canon(want))
    if os.path.normcase(gd) != target or os.path.normcase(common) != target:
        return f"git resolves its directory to {gd or '?'} (common: {common or '?'})"
    return None


def _layout_problem(ws: str) -> str | None:
    want = os.path.join(ws, ".git")
    if _is_link_path(want):
        return ".git is a symlink"
    if not os.path.isdir(want):
        return ".git is a file pointing at another git directory"
    if os.path.lexists(os.path.join(want, "commondir")):
        return ".git/commondir exists"
    linked, failed = _scan_git_dir(want)
    if failed:
        return "could not scan .git (an unreadable directory inside it)"
    if linked:
        return ".git contains a symlink (outside .git/hooks)"
    return _git_dirs_problem(ws, want)


def check_layout(ws: str) -> None:
    why = _layout_problem(ws)
    if why is not None:
        raise _refuse(f"--clone: {ws} is not an ordinary repository checkout: {why}.",
                      "Clone mode needs .git to be the repository's own directory; 'git worktree'",
                      "checkouts and submodule checkouts are not supported. Run it from the main",
                      "checkout or a regular clone, then re-run.")


def _git_false(value: str) -> bool:
    return value == "" or value == "0" or (value.isascii() and value.lower() in _FALSE_WORDS)


def check_partial(ws: str) -> None:
    """Refuse a partial clone: its missing objects are never fetched by the wrapper."""
    partial = ws_git(ws, "config", "--get-all", "extensions.partialClone").returncode == 0
    if not partial:
        out = ws_git(ws, "config", "-z", "--get-regexp", r"^remote\..*\.promisor$").stdout
        for entry in _nul_values(out):
            value = entry.split("\n", 1)[1] if "\n" in entry else "true"
            if not _git_false(value):
                partial = True
                break
    if partial:
        raise _refuse(f"--clone: {ws} is a partial clone (it has a promisor remote).",
                      "Objects left on the server are missing locally and clone mode never",
                      "fetches them. Use a full clone of the repository, then re-run.")


def _read_bounded(path: str, cap: int) -> tuple[bytes, bool] | None:
    """Up to ``cap`` bytes of a regular, non-link file, and whether more remained."""
    try:
        fd = os.open(path, _READ_FLAGS)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        chunks, size = [], 0
        while size <= cap:
            chunk = os.read(fd, min(1024 * 1024, cap + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        data = b"".join(chunks)
        return data[:cap], len(data) > cap
    except OSError:
        return None
    finally:
        os.close(fd)


def _uses_lfs(ws: str) -> bool:
    for path in (os.path.join(ws, ".gitattributes"), os.path.join(ws, ".git", "info", "attributes")):
        read = _read_bounded(path, _PACKED_REFS_CAP)
        if read is not None and b"filter=lfs" in read[0]:
            return True
    if os.path.isdir(os.path.join(ws, ".git", "lfs")):
        return True
    return ws_git(ws, "config", "--local", "--no-includes", "--get-regexp", r"^lfs\.").returncode == 0


def preflight(ws: str) -> None:
    """Refuse an unusual layout, borrowed objects or a partial clone; note LFS and a dirty tree."""
    check_layout(ws)
    alternates = os.path.join(ws, ".git", "objects", "info", "alternates")
    if os.path.isfile(alternates) and os.path.getsize(alternates) > 0:
        raise _refuse(f"--clone: {ws} borrows objects from other repositories",
                      "(.git/objects/info/alternates). Run 'git repack -a -d' and remove that",
                      "file, or use a regular clone, then re-run.")
    check_partial(ws)
    lfs = _uses_lfs(ws)
    if lfs:
        _say("note: this repository uses Git LFS. Clone mode disables filter drivers,",
             "  so LFS-tracked files are checked out in the scratch as pointer files.",
             "  If git-lfs is available in the sandbox, fetch their content there with:",
             "  git lfs pull")
    if _has_uncommitted(ws):
        _say("note: the workspace has uncommitted changes; a git clone carries",
             "  committed state only. Commit first ('git add' untracked files),",
             "  or copy files in with 'acq cp'.")


def _has_uncommitted(ws: str) -> bool:
    """Staged changes or untracked files, found with plumbing that never reads file content.

    ``git status`` compares the working tree and so may run a clean filter,
    and the filter list blanked in :func:`prep` comes from an earlier read of
    a config the guest can change in between. Comparing the index with HEAD
    and listing untracked names starts no filter; an edit to a tracked file
    that is not staged goes unreported.
    """
    staged = ws_git(ws, "diff-index", "--cached", "--quiet", "HEAD", "--").returncode == 1
    return staged or bool(ws_git(ws, "ls-files", "-z", "--others", "--exclude-standard").stdout)


def check_stale(name: str, sandbox_dir: Path, exists: Callable[[str], bool]) -> None:
    if not os.path.lexists(sandbox_dir):
        return
    message = f"--clone: a scratch clone for '{name}' already exists: {sandbox_dir}"
    if exists(name):
        # The scratch is the live mount source of an existing sandbox: deleting it
        # by hand would destroy that workspace and skip the unfetched-work warning.
        raise _refuse(message, f"sandbox '{name}' still exists and mounts it. Remove the sandbox with",
                      f"'acq rm {name}' (it warns about unfetched work and cleans up), then re-run.")
    raise _refuse(message, "it may hold unfetched work from an earlier sandbox. Recover it",
                  f"('git fetch {REMOTE_PREFIX}{name}') and remove the directory, then re-run.")


# ---------------------------------------------------------------------------
# The scratch clone.
# ---------------------------------------------------------------------------


def _make_private(sandbox_dir: Path) -> bool:
    """Create ``sandbox_dir`` and any missing parent 0700, then chmod it 0700."""
    try:
        missing, node = [], sandbox_dir
        while not os.path.lexists(node) and node.parent != node:
            missing.append(node)
            node = node.parent
        for directory in reversed(missing):
            os.mkdir(directory, 0o700)
        _chmod(sandbox_dir, 0o700)
    except OSError:
        return False
    return True


def make_scratch(ws: str, sandbox_dir: Path, scratch: Path) -> None:
    """Create the private dir, record ``ws`` as its origin and clone ``ws`` into ``scratch``."""
    # Private: the scratch's .git/config carries the source origin URL, which
    # may embed a credential, at a path the user never sees.
    if not _make_private(sandbox_dir):
        remove_guest_tree(sandbox_dir)
        raise _refuse(f"--clone: could not create a private scratch dir: {sandbox_dir}",
                      "Refusing to clone a config that may embed a credential into a",
                      "directory other users can read.", code=errors.FAILURE)
    try:
        (sandbox_dir / ORIGIN_FILE).write_text(origin_text(ws) + "\n", encoding="utf-8")
    except OSError as exc:
        remove_guest_tree(sandbox_dir)
        raise _refuse(f"--clone: could not record the source checkout in {sandbox_dir}: {exc.strerror or exc}",
                      "check that the acq state directory is writable, then re-run", code=errors.FAILURE) from exc
    # --no-local goes through upload-pack, so only objects reachable from the
    # repository's refs are copied; only the local file transport is allowed.
    proc = ws_git(ws, "-c", "protocol.file.allow=always", "clone", "--quiet", "--no-local", "--no-hardlinks",
                  "--", ws, str(scratch), show_stderr=True)
    if proc.returncode != 0:
        remove_guest_tree(sandbox_dir)
        raise _refuse(f"--clone: git clone of {ws} failed", code=errors.FAILURE)


def git_bool_true(value: str) -> bool:
    """git's boolean reading: true/yes/on, or a non-zero integer (``00`` is false).

    Anything git would refuse is treated as true (``GIT_CONFIG_NOSYSTEM``).
    """
    if value == "" or (value.isascii() and value.lower() in _FALSE_WORDS):
        return False
    if value.isascii() and value.lower() in ("true", "yes", "on"):
        return True
    digits = value[1:] if value[:1] in ("+", "-") else value
    digits = digits[:-1] if digits[-1:] in tuple("kKmMgG") else digits
    if not digits or not all(ch in "0123456789" for ch in digits):
        return True
    return any(ch != "0" for ch in digits)


def _read_scope(src: str, key: str, *flags: str, keep: bool = False) -> tuple[int, list[tuple[str, str]]]:
    proc = ws_git(src, "config", *flags, "-z", "--get-all", key, keep=keep)
    if proc.returncode == 1:
        return 1, []
    if proc.returncode != 0:
        return 2, []
    values = _nul_values(proc.stdout)
    if "--show-scope" not in flags:
        return 0, [("", v) for v in values]
    return 0, list(zip(values[0::2], values[1::2], strict=False))


def _scope_value(src: str, key: str, scope: str) -> tuple[int, str]:
    """One scope's last value of ``key``: ``(0, value)``, ``(1, "")`` absent, ``(2, "")`` unreadable."""
    if scope == "command":
        if not git_version_ge(2, 26):
            return 1, ""
        rc, pairs = _read_scope(src, key, "--no-includes", "--show-scope", keep=True)
        if rc != 0:
            return rc, ""
        pairs = [p for p in pairs if p[0] == "command"]
        return (0, pairs[-1][1]) if pairs else (1, "")
    flags = {"system": ("--system", "--includes"), "global": ("--global", "--includes"),
             "local": ("--local", "--no-includes"), "worktree": ("--worktree", "--no-includes")}[scope]
    rc, pairs = _read_scope(src, key, *flags)
    return (rc, pairs[-1][1]) if rc == 0 and pairs else (rc, "")


def read_identity(src: str, key: str) -> tuple[int, str]:
    """``key`` (user.name/user.email) as git resolves it for ``src``, scope by scope.

    system, global, local, worktree, command; the last value wins. The system
    file is skipped when GIT_CONFIG_NOSYSTEM is git-true; the worktree file is
    read only with ``extensions.worktreeConfig``; the repository's own files
    are read without includes. ``(0, value)``, ``(1, "")`` or ``(2, "")``.
    """
    found, value = False, ""
    for scope in ("system", "global", "local", "worktree", "command"):
        if scope == "system" and git_bool_true(os.environ.get("GIT_CONFIG_NOSYSTEM", "")):
            continue
        if scope == "worktree" and ws_git(src, "config", "--local", "--no-includes", "--bool", "--get",
                                          "extensions.worktreeConfig").stdout.rstrip("\n") != "true":
            continue
        rc, scoped = _scope_value(src, key, scope)
        if rc == 2:
            return 2, ""
        if rc == 0:
            found, value = True, scoped
    return (0, value) if found else (1, "")


def _config_fail(verb: str, key: str) -> None:
    """Abort for an origin key (raise); warn and carry on for an identity key."""
    where = "the source checkout's config" if verb == "read" else "the scratch clone"
    if key.startswith("remote.origin."):
        raise _refuse(f"--clone: could not {verb} {key} in {where}.",
                      "Refusing a scratch whose origin may still resolve to itself: an in-guest",
                      "'git push origin' would then look successful while reaching no forge.", code=errors.FAILURE)
    _say(f"warning: --clone: could not {verb} {key} in {where}; the guest may need 'git config {key}'.")


def _unset_key(scratch: str, key: str) -> None:
    if scratch_git(scratch, "config", "--unset-all", key).returncode not in (0, 5):  # 5: nothing to unset
        _config_fail("set", key)


def copy_config(src: str, scratch: str) -> None:
    """Carry the identity and the raw origin URL(s) of ``src`` into the scratch (ADR-0027).

    A clone points ``origin`` at the host path, where the guest mounts the
    scratch itself, so every configured origin value is copied in order (or
    unset when ``src`` has none). An origin that cannot be carried aborts.
    """
    for key in ("user.name", "user.email"):
        rc, value = read_identity(src, key)
        if rc == 0:
            if scratch_git(scratch, "config", "--replace-all", key, value).returncode != 0:
                _config_fail("set", key)
        elif rc == 1:
            _unset_key(scratch, key)
        else:
            _config_fail("read", key)
    for key in ("remote.origin.url", "remote.origin.pushurl"):
        proc = ws_git(src, "config", "--no-includes", "-z", "--get-all", key)
        if proc.returncode == 1:
            _unset_key(scratch, key)
            continue
        if proc.returncode != 0:
            _config_fail("read", key)
        for i, value in enumerate(_nul_values(proc.stdout)):
            mode = "--replace-all" if i == 0 else "--add"
            if scratch_git(scratch, "config", mode, key, value).returncode != 0:
                _config_fail("set", key)


def _wire(name: str, ws: str, sandbox_dir: Path, scratch: Path) -> None:
    try:
        copy_config(ws, str(scratch))
    except MsbError:
        remove_guest_tree(sandbox_dir)
        raise
    remote = f"{REMOTE_PREFIX}{name}"
    try:
        # Replace a stale same-name remote: its scratch was just verified absent.
        ws_git(ws, "remote", "remove", remote)
        added = ws_git(ws, "remote", "add", remote, str(scratch)).returncode == 0
    except MsbError:
        added = False
    if not added:
        _say(f"warning: could not register the '{remote}' remote in {ws};",
             f"  fetch agent work directly: git fetch {scratch}")
    # acq never runs git inside the guest-writable scratch, but the recovery
    # command below does: see KNOWN_FAILURE_MODES, "Recovering agent work reads
    # the guest-writable scratch clone".
    _say("agent runs on a disposable clone; the real checkout is untouched.",
         f"  Recover agent branches with: git fetch {remote}")


def setup(name: str, ws: str, exists: Callable[[str], bool]) -> str:
    """Create the scratch clone and fetch-back remote for ``ws``; returns the mount source.

    Each step refuses before anything is created, in Bash's order: name,
    wrapper settings, repository root, stale scratch, preflight, clone, then
    the config and remote wiring. ``exists`` says whether a sandbox is live
    (for the stale-scratch advice).
    """
    check_name(name)
    prep(ws)
    ws_canon = repo_root(ws)
    sandbox_dir = clones_root() / name
    scratch = sandbox_dir / os.path.basename(ws_canon)
    check_stale(name, sandbox_dir, exists)
    preflight(ws_canon)
    make_scratch(ws_canon, sandbox_dir, scratch)
    _wire(name, ws_canon, sandbox_dir, scratch)
    return _canon(str(scratch))


# ---------------------------------------------------------------------------
# rm and recreate.
# ---------------------------------------------------------------------------


def _ref_tips(scratch: Path) -> tuple[list[str], bool]:
    """Branch tips read straight from the scratch's ref files, and whether any were unreadable.

    The scratch is guest-writable, so git never runs in it; links are never
    followed and only regular files are read (a FIFO would block).
    """
    tips: list[str] = []
    if _is_link_path(str(scratch / ".git")) or _is_link_path(str(scratch / ".git" / "refs")):
        return [], True  # redirected out of the scratch: unverifiable, so warn
    heads = scratch / ".git" / "refs" / "heads"
    if heads.is_dir() and not _is_link_path(str(heads)):
        for root, dirs, files in os.walk(heads, followlinks=False):
            dirs[:] = [d for d in dirs if not _is_link_path(os.path.join(root, d))]
            for name in files:
                read = _read_bounded(os.path.join(root, name), _LOOSE_REF_CAP)
                if read is not None:
                    tips += read[0].decode("ascii", "replace").split("\n")
    read = _read_bounded(str(scratch / ".git" / "packed-refs"), _PACKED_REFS_CAP)
    if read is not None:
        for line in read[0].decode("ascii", "replace").split("\n"):
            fields = line.split()
            if len(fields) >= 2 and _HEX_RE.fullmatch(fields[0]) and fields[1].startswith("refs/heads/"):
                tips.append(fields[0])
    return list(dict.fromkeys(t for t in tips if _HEX_RE.fullmatch(t))), bool(read and read[1])


def _all_present(origin: str, tips: list[str]) -> bool:
    if not tips:
        return True
    proc = ws_git(origin, "cat-file", "--batch-check", input_text="\n".join(tips) + "\n")
    lines = proc.stdout.splitlines()
    if proc.returncode != 0 or len(lines) != len(tips):
        return False
    return all(re.fullmatch(r"[0-9a-f]+ [a-z]+ [0-9]+", line) for line in lines)


def warn_unfetched(name: str) -> bool:
    """Warn (never block) when ``name``'s scratch holds commits its origin lacks; True when warned.

    When the wrapper refuses to run git in the origin, its reason is shown and
    the check is reported as skipped rather than every tip looking unfetched.
    """
    if not valid_name(name):
        return False
    try:
        sandbox_dir = clones_root() / name
    except MsbError:
        return False
    if not sandbox_dir.is_dir():
        return False
    origin = _read_origin(sandbox_dir)
    if not origin or not os.path.isdir(origin):
        return False
    try:
        prep(origin)
    except MsbError as exc:
        _show(exc)
        _say(f"warning: could not check sandbox '{name}''s scratch clone for unfetched",
             "  commits (see above); any it holds are discarded with it.")
        return False
    scratch = _find_scratch(sandbox_dir)
    if scratch is None:
        return False
    tips, truncated = _ref_tips(scratch)
    try:
        fetched = not truncated and _all_present(origin, tips)
    except MsbError:
        fetched = False
    if fetched:
        return False
    _say(f"warning: discarding unfetched commits in sandbox '{name}''s scratch clone",
         f"  (they were recoverable with: git fetch {REMOTE_PREFIX}{name}).")
    return True


def cleanup(name: str) -> None:
    """Delete ``name``'s scratch clone and drop its fetch-back remote (best-effort).

    ``git remote remove sandbox-<name>`` also deletes the checkout's
    ``refs/remotes/sandbox-<name>/*``: branches fetched from the sandbox stay
    only where the user merged or branched them.
    """
    if not valid_name(name):
        return
    try:
        sandbox_dir = clones_root() / name
    except MsbError as exc:
        _show(exc)
        return
    if not os.path.lexists(sandbox_dir):
        return
    origin = _read_origin(sandbox_dir)
    remote = f"{REMOTE_PREFIX}{name}"
    if origin and os.path.isdir(origin):
        try:
            ws_git(origin, "remote", "remove", remote)
        except MsbError as exc:
            _show(exc)
            _say(f"warning: left the '{remote}' remote in {origin} (see above).",
                 f"  Remove it with: git -C {origin} remote remove {remote}")
    remove_guest_tree(sandbox_dir)


def recorded_scratch(name: str, workspace: str) -> tuple[str | None, bool]:
    """``(scratch, matches)`` for an existing clone sandbox.

    ``scratch`` is the canonical scratch path when one exists; ``matches`` says
    its ``.origin`` names ``workspace``, the checkout the sandbox records.
    """
    if not valid_name(name):
        return None, False
    try:
        sandbox_dir = clones_root() / name
    except MsbError:
        return None, False
    scratch = _find_scratch(sandbox_dir) if sandbox_dir.is_dir() else None
    origin = _read_origin(sandbox_dir) if scratch is not None else ""
    matches = bool(origin) and os.path.isdir(origin) and _same(origin, workspace)
    return (_canon(str(scratch)) if scratch is not None else None), matches
