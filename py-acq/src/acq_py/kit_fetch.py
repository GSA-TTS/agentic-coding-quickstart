"""Fetch a remote kit pinned to a commit (ADR-0040m, ADR-0042m).

The built-in bundle covers the kits acq selects by default. Anything else that
names a remote kit (an opt-in catalog kit from config ``extra_kits``, a remote
``ACQ_EXTRA_KITS`` or ``--kit`` ref, a provider kit from a registered source)
is fetched here. This is a port of the Bash ``kit_translate_fetch``,
``_kit_fetch_reuse`` and ``_kit_fetch_materialize``
(``acq.backends/kit-translate.sh``), with the same refusals and some stricter
ones:

* The ref grammar is Bash's: ``git+https://HOST/PATH#ref=REF&dir=DIR``, the
  fragment split on ``&``, the last ``ref=`` and ``dir=`` winning, other
  parameters ignored. A ref with userinfo in its authority is refused
  (``credential-bearing kit URLs are not allowed``), and so is a ``dir=`` that
  is absolute, contains ``..`` or uses a character outside ``[A-Za-z0-9._/-]``.
* Stricter than Bash: ``REF`` must be a full 40-hex commit id. Bash fetches a
  branch or tag name unverified; the Python acq refuses it
  (``kit_ref_not_pinned``). Only ``https`` is fetched (Bash also tries plain
  ``http``), and the URL may hold only a host, an optional port and a path of
  plain characters: no query string, no percent escapes, no whitespace.
* The commit is fetched into a bare repository in acq's private cache, and the
  fetched commit must be exactly the pinned one before anything is read from
  it. The kit is then checked out from the pinned commit's tree with a private
  index (``read-tree`` and ``checkout-index``, as Bash does), never from a work
  tree a consumer could have changed.
* Every git command runs with the repository-redirecting and command-scope
  config variables removed (:func:`gitrepos.git_env`, Bash
  ``_kit_git_isolate``), with prompts disabled and stdin closed, resolved
  through :mod:`hostexec`, under a timeout. The first fetch attempt reads no
  git config files at all and may use only https; only when it fails is it
  retried with the user's own config (credential helpers, URL rewrites), still
  without prompts, and with ``core.hooksPath`` pointed at the null device so
  the user's global hooks never run in the cache. git's diagnostics are never
  shown: under the user's config they can name a credential-bearing URL.
* The checked-out tree must pass :func:`kitspec.tree_symlinks_within` (no name
  with a newline, no symlink resolving outside the kit), on top of the per-file
  checks the backends make (:func:`kitspec.resolve_source`).

A failure of any kind, including a network failure, raises
:class:`KitFetchError`, and the caller refuses the create or heal: a kit that
cannot be fetched is never skipped and never handed to a backend unchecked.

The cache lives under the backend's kit cache (``ACQ_MSB_KIT_CACHE`` or
``ACQ_SBX_KIT_CACHE``, defaulting to ``$XDG_CACHE_HOME/acq/kits`` and
``…/acq/sbx-kits`` as in Bash), in a ``py-fetch`` directory the Bash acq never
writes. Unlike Bash, which fetches again in every process, a verified commit
is kept there and reused by later commands, so a heal on ``start`` works
offline once the create has fetched the kit. Each tree is published by an
atomic rename, so concurrent commands never see a partial one.

A local kit directory is not fetched but copied into the same tree cache
(:func:`copy_local`), following no link on the way, and checked there the same
way, so the backends never read a directory someone else can change.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from . import errors, gitrepos, hostexec, kitspec, timeouts, userdirs

FETCH_TIMEOUT_ENV = "ACQ_KIT_FETCH_TIMEOUT"
DEFAULT_FETCH_TIMEOUT_S = 120.0
LOCAL_GIT_TIMEOUT_S = 60.0
CACHE_ENV = {"msb": "ACQ_MSB_KIT_CACHE", "sbx": "ACQ_SBX_KIT_CACHE"}
_CACHE_DEFAULT = {"msb": "kits", "sbx": "sbx-kits"}
PY_DIR = "py-fetch"
VERIFIED_MARKER = "acq-verified"
COMPLETE_MARKER = "complete"

# The URL schemes a kit may be fetched over. Tests add "file" to fetch from a
# local bare repository without a network; nothing in acq changes it.
SCHEMES: tuple[str, ...] = ("https",)

_SHA = re.compile(r"[0-9a-f]{40}")
_DIR_CHARS = re.compile(r"[A-Za-z0-9._/-]+")
_AUTHORITY = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?")
_PATH_SEGMENT = re.compile(r"[A-Za-z0-9._~+-]+")
_KIT_NAME = re.compile(r"[A-Za-z0-9._-]+")
_DRIVE = re.compile(r"[A-Za-z]:")

# What the anonymous attempt neutralizes, and the authenticated retry keeps
# disabled: a credential prompt (the fetch must never wait on a terminal).
_PROMPT_ENV_DROP = ("GIT_ASKPASS", "SSH_ASKPASS")
_GIT_FAILURE_HINT = (
    "if a kit source needs authentication, configure a git credential helper that does not "
    "prompt (for GitHub: 'gh auth setup-git'), check for a URL rewrite with "
    "\"git config --global --get-regexp 'url\\..*insteadOf'\", and check network access"
)


class KitFetchError(Exception):
    """A kit ref was refused or could not be fetched (an acq-authored message, never git's)."""

    def __init__(self, code: str, message: str, remediation: str):
        super().__init__(message)
        self.code = code
        self.message = message
        self.remediation = remediation


@dataclass(frozen=True)
class RemoteRef:
    """A parsed remote kit ref: the fetch URL, the pinned commit and the kit's directory."""

    url: str
    commit: str
    directory: str  # normalized: no "." or empty segments; "" for the repository root


def ref_display(ref: str) -> str:
    """``kit_ref_display``: a kit ref safe for a terminal or a log.

    Before the ``#`` fragment, a query string becomes ``?***``, URL userinfo
    becomes ``***@``, and without a scheme a first path segment with ``@``
    becomes ``***@HOST``. The fragment is kept so the message still names the
    kit. Every message that names a ref goes through this.
    """
    base, sep, frag = ref.partition("#")
    query = ""
    if "?" in base:
        base, query = base.split("?", 1)[0], "?***"
    if "://" in base:
        scheme, rest = base.split("://", 1)
        if "@" in rest:
            base = f"{scheme}://***@{rest.rsplit('@', 1)[1]}"
    else:
        first = base.split("/", 1)[0]
        if "@" in first:
            base = "***@" + first.rsplit("@", 1)[1] + base[len(first):]
    return f"{base}{query}{sep}{frag}"


def _shown(ref: str) -> str:
    """A ref as messages quote it: redacted (:func:`ref_display`) and in single quotes."""
    return f"'{ref_display(ref)}'"


def is_remote(ref: str) -> bool:
    """True for a ref acq would fetch (``git+…``); anything else names a local directory."""
    return ref.startswith("git+")


def _refused(message: str, code: str = errors.VALIDATION_FAILED, remediation: str | None = None) -> KitFetchError:
    return KitFetchError(code, message, remediation or "fix the kit ref (--kit, ACQ_EXTRA_KITS, ACQ_PROVIDER_KITS, "
                         "or the kit source registry), then retry")


def _check_url(url: str, shown: str) -> None:
    scheme, sep, rest = url.partition("://")
    if not sep or scheme not in SCHEMES:
        raise _refused(f"kit ref {shown} is not an https URL; the Python acq fetches kits over https only")
    authority, slash, path = rest.partition("/")
    segments = path.split("/")
    if scheme == "file":
        authority_ok = authority == ""
        if _DRIVE.fullmatch(segments[0]):  # file:///C:/… on Windows
            segments = segments[1:]
    else:
        authority_ok = bool(_AUTHORITY.fullmatch(authority))
    if not authority_ok or not slash or not all(_PATH_SEGMENT.fullmatch(s) and s not in (".", "..")
                                                  for s in segments):
        raise _refused(f"kit ref {shown} has a URL acq does not accept (only a host, an optional port and a "
                       "plain path; no query string, percent escapes or whitespace)")


def _normalize_dir(directory: str) -> str:
    """The Bash spelling normalization: repeated slashes, ``./`` and a trailing ``/`` or ``/.`` go."""
    return "/".join(part for part in directory.split("/") if part not in ("", "."))


def parse_ref(ref: str) -> RemoteRef:
    """Parse and validate a ``git+https://…#ref=SHA&dir=DIR`` kit ref. Raises :class:`KitFetchError`."""
    shown = _shown(ref)
    if not is_remote(ref):
        raise _refused(f"kit ref {shown} is not a remote kit ref")
    url = ref[len("git+"):]
    frag = url.split("#", 1)[1] if "#" in url else url  # Bash "${url#*#}"
    url = url.split("#", 1)[0]
    authority = url.split("://", 1)[-1].split("/", 1)[0]
    if "@" in authority:
        raise _refused(f"credential-bearing kit URLs are not allowed: {shown}",
                       remediation="remove the user name or token from the kit URL; configure a git credential "
                       "helper for a source that needs authentication")
    commit = directory = ""
    for param in frag.split("&"):
        if param.startswith("ref="):
            commit = param[len("ref="):]
        elif param.startswith("dir="):
            directory = param[len("dir="):]
    if not commit or not directory:
        raise _refused(f"malformed kit ref (need #ref=&dir=): {shown}")
    if directory.startswith("/") or ".." in directory:
        raise _refused(f"unsafe kit dir (no absolute paths or '..'): {shown}")
    if not _DIR_CHARS.fullmatch(directory):
        raise _refused(f"unsafe kit dir (illegal characters): {shown}")
    if not _SHA.fullmatch(commit):
        raise _refused(
            f"kit ref {shown} is not pinned to a full commit id; the Python acq fetches only a kit pinned to "
            "a 40-character commit SHA", errors.KIT_REF_NOT_PINNED,
            "pin the ref to a full commit (#ref=<40-hex sha>), or use the Bash acq (ACQ_IMPL=bash)")
    _check_url(url, shown)
    return RemoteRef(url, commit, _normalize_dir(directory))


# ---------------------------------------------------------------------------
# The private cache.
# ---------------------------------------------------------------------------


def cache_root(backend: str) -> Path:
    """The backend's kit cache (the Bash ``ACQ_*_KIT_CACHE`` default). Raises :class:`KitFetchError`."""
    var = CACHE_ENV[backend]
    try:
        override = userdirs.path_override(var)
        return override or userdirs.xdg_base("XDG_CACHE_HOME", ".cache") / "acq" / _CACHE_DEFAULT[backend]
    except userdirs.UserDirError as exc:
        raise KitFetchError(errors.VALIDATION_FAILED, exc.message, exc.remediation) from None


def _private_dir(path: Path) -> Path:
    """Create ``path`` (0700) or accept it only as acq's own directory, never through a link."""
    try:
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or os.path.isjunction(path):
            raise KitFetchError(errors.VALIDATION_FAILED, f"{str(path)!r} is not a directory acq created",
                                "remove it, then retry")
        if hasattr(os, "getuid") and info.st_uid != os.getuid():
            raise KitFetchError(errors.VALIDATION_FAILED, f"{str(path)!r} is owned by another user",
                                "remove it or point the kit cache elsewhere, then retry")
        os.chmod(path, 0o700)
    except OSError as exc:
        raise KitFetchError(errors.FAILURE, f"could not prepare the kit cache {str(path)!r}: {exc.strerror or exc}",
                            "check that the kit cache directory is writable, then retry") from exc
    return path


def _cache_dirs(backend: str) -> tuple[Path, Path, Path]:
    """``(py-fetch, src, tree)`` under the backend's kit cache, all private."""
    root = cache_root(backend)
    try:
        root.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise KitFetchError(errors.FAILURE, f"could not create the kit cache {str(root)!r}: {exc.strerror or exc}",
                            "check that the kit cache directory is writable, then retry") from exc
    base = _private_dir(root / PY_DIR)
    return base, _private_dir(base / "src"), _private_dir(base / "tree")


def _remove_tree(path: Path) -> None:
    """Remove an acq-owned tree (best-effort); a link in its place is unlinked, never followed."""
    def _writable(func, target, _exc):  # git writes its objects read-only; Windows needs them writable
        try:
            os.chmod(target, stat.S_IWRITE | stat.S_IREAD)
            func(target)
        except OSError:
            pass

    try:
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.exists():
            shutil.rmtree(path, onexc=_writable)
    except OSError:
        pass


def _place(tmp: Path, dest: Path, valid) -> Path:
    """Rename the finished ``tmp`` to ``dest``, keeping a valid tree a concurrent command put there first."""
    try:
        os.rename(tmp, dest)
        return dest
    except OSError:
        if valid(dest):
            _remove_tree(tmp)
            return dest
    trash = dest.parent / f".trash-{secrets.token_hex(8)}"
    try:
        os.rename(dest, trash)  # a damaged tree: moved aside, never deleted where a reader may look
    except OSError:
        pass
    _remove_tree(trash)
    try:
        os.rename(tmp, dest)
    except OSError as exc:
        _remove_tree(tmp)
        if valid(dest):
            return dest
        raise KitFetchError(errors.FAILURE, f"could not place a fetched kit in {str(dest.parent)!r}: "
                            f"{exc.strerror or exc}", "check that the kit cache directory is writable, then retry") from exc
    return dest


# ---------------------------------------------------------------------------
# git.
# ---------------------------------------------------------------------------


def _git_program() -> str:
    git = hostexec.which("git")
    if git is None:
        raise KitFetchError(errors.FAILURE, "git is required to fetch a kit that is not in the built-in bundle, "
                            "and it was not found on PATH", "install git, then retry")
    return git


def _allowed_protocols(inherited: str | None) -> str:
    """``GIT_ALLOW_PROTOCOL`` for the attempt without config: :data:`SCHEMES`, never wider than inherited.

    An inherited list (one the user or a test set) only narrows it. When
    nothing is left, a name no transport has allows nothing.
    """
    allowed = [s for s in SCHEMES if inherited is None or s in inherited.split(":")]
    return ":".join(allowed) or "acq-none"


def _env(*, user_config: bool) -> dict[str, str]:
    """git's environment: no repository redirects, no prompts; the user's config files only on request.

    Without the user's config, git may use only the transports a kit URL may
    name (https). With it (the authenticated retry), the transport is left to
    git's defaults and the user's ``GIT_ALLOW_PROTOCOL``: the user's own
    ``url.<base>.insteadOf`` rewrite may send a pinned https URL to an
    enterprise mirror over ssh, and the commit is verified against the pin
    whatever the transport.
    """
    env = gitrepos.git_env()
    for var in _PROMPT_ENV_DROP:
        env.pop(var, None)
    env.update({"GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never"})
    if not user_config:
        env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_ALLOW_PROTOCOL": _allowed_protocols(os.environ.get("GIT_ALLOW_PROTOCOL"))})
        env.pop("GIT_CONFIG_SYSTEM", None)
    return env


def _git(git: str, args: list[str], *, env: dict[str, str], timeout: float) -> subprocess.CompletedProcess[str]:
    """Run git; its output is captured and only ever parsed, never shown. Raises :class:`KitFetchError`."""
    try:
        return subprocess.run(  # nosec B603 # an absolute git and a fixed argument list, no shell
            [git, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise KitFetchError(errors.TIMEOUT, f"git did not finish within {timeout:g}s while fetching a kit",
                            f"check network access, or raise {FETCH_TIMEOUT_ENV}, then retry") from exc
    except OSError as exc:
        raise KitFetchError(errors.FAILURE, f"could not run git: {exc.strerror or exc}",
                            "check the git installation, then retry") from exc


def _local(git: str, repo: Path, *args: str, index: Path | None = None,
           work_tree: Path | None = None) -> subprocess.CompletedProcess[str]:
    """A local git command on ``repo`` with no config files read."""
    env = _env(user_config=False)
    if index is not None:
        env["GIT_INDEX_FILE"] = str(index)
    head = ["--git-dir", str(repo)] + (["--work-tree", str(work_tree)] if work_tree is not None else [])
    return _git(git, [*head, "-c", "core.autocrlf=false", *args], env=env, timeout=LOCAL_GIT_TIMEOUT_S)


def _commit_of(git: str, repo: Path, rev: str) -> str:
    proc = _local(git, repo, "rev-parse", "--verify", "--quiet", "--end-of-options", f"{rev}^{{commit}}")
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _source_valid(git: str, repo: Path, commit: str) -> bool:
    """A bare repository acq fetched and verified: its marker names the commit, which it holds."""
    try:
        if repo.is_symlink() or not repo.is_dir():
            return False
        marker = (repo / VERIFIED_MARKER).read_text(encoding="utf-8").strip()
    except OSError:
        return False
    return marker == commit and _commit_of(git, repo, commit) == commit


def _fetch_into(git: str, repo: Path, ref: RemoteRef, timeout: float) -> bool:
    """One fetch of the pinned commit, anonymous first, then with the user's config; True on success.

    ``core.hooksPath`` names the null device, which holds no hook, so the
    user's global hooks (read by the retry) never run in acq's cache repository.
    """
    args = ["-c", "core.askPass=", "-c", "credential.interactive=false", "-c", f"core.hooksPath={os.devnull}",
            "-C", str(repo), "fetch", "--quiet",
            "--depth", "1", "--no-tags", "--no-recurse-submodules", "--end-of-options", ref.url, ref.commit]
    for user_config in (False, True):
        if _git(git, args, env=_env(user_config=user_config), timeout=timeout).returncode == 0:
            return True
    return False


def _fetch_source(git: str, ref: RemoteRef, src: Path, shown: str) -> Path:
    """The verified bare repository holding the pinned commit (reused, or fetched now)."""
    key = hashlib.sha256(f"{ref.url}\0{ref.commit}".encode()).hexdigest()[:32]
    dest = src / key
    if _source_valid(git, dest, ref.commit):
        return dest
    timeout = timeouts.positive_seconds(FETCH_TIMEOUT_ENV, DEFAULT_FETCH_TIMEOUT_S)
    try:
        tmp = Path(tempfile.mkdtemp(prefix=".fetch.", dir=src))
    except OSError as exc:
        raise KitFetchError(errors.FAILURE, f"could not create a fetch directory: {exc.strerror or exc}",
                            "check that the kit cache directory is writable, then retry") from exc
    try:
        if _git(git, ["init", "--bare", "--quiet", "--template=", str(tmp)], env=_env(user_config=False),
                timeout=LOCAL_GIT_TIMEOUT_S).returncode != 0:
            raise KitFetchError(errors.FAILURE, "git init failed in the kit cache", "check the git installation")
        if not _fetch_into(git, tmp, ref, timeout):
            raise KitFetchError(errors.FAILURE,
                                f"failed to fetch remote kit {shown} (git fetch failed; details suppressed)",
                                _GIT_FAILURE_HINT)
        fetched = _local(git, tmp, "rev-parse", "--verify", "--quiet", "FETCH_HEAD").stdout.strip()
        if fetched != ref.commit or _commit_of(git, tmp, ref.commit) != ref.commit:
            raise KitFetchError(errors.VALIDATION_FAILED,
                                f"failed to fetch remote kit {shown}: the fetched revision does not match the "
                                "pinned commit", "check the kit source; acq applies only the pinned commit")
        (tmp / VERIFIED_MARKER).write_text(ref.commit + "\n", encoding="utf-8")
    except BaseException:
        _remove_tree(tmp)
        raise
    return _place(tmp, dest, lambda p: _source_valid(git, p, ref.commit))


def _tree_valid(path: Path, stamp: str) -> bool:
    try:
        return (not path.is_symlink() and (path / "kit").is_dir() and not (path / "kit").is_symlink()
                and (path / COMPLETE_MARKER).read_text(encoding="utf-8") == stamp)
    except OSError:
        return False


def _materialize(git: str, repo: Path, ref: RemoteRef, tree: Path, shown: str) -> Path:
    """Check the kit's directory out of the pinned commit into a published, private tree."""
    stamp = f"{ref.commit}\n{ref.directory}\n"
    dest = tree / hashlib.sha256(stamp.encode()).hexdigest()[:32]
    if _tree_valid(dest, stamp):
        return dest / "kit"
    rev = f"{ref.commit}:{ref.directory}"
    if _local(git, repo, "cat-file", "-t", "--end-of-options", rev).stdout.strip() != "tree":
        raise KitFetchError(errors.VALIDATION_FAILED, f"remote kit directory not found: {shown}",
                            "fix the kit ref's dir=, then retry")
    try:
        tmp = Path(tempfile.mkdtemp(prefix=".tree.", dir=tree))
    except OSError as exc:
        raise KitFetchError(errors.FAILURE, f"could not create a kit directory: {exc.strerror or exc}",
                            "check that the kit cache directory is writable, then retry") from exc
    try:
        kit = tmp / "kit"
        kit.mkdir()
        index = tmp / "index"
        # checkout-index keeps files marked export-ignore or export-subst, unlike
        # git archive, and the private index leaves the verified source untouched.
        if (_local(git, repo, "read-tree", "--end-of-options", rev, index=index, work_tree=kit).returncode != 0
                or _local(git, repo, "checkout-index", "--all", index=index, work_tree=kit).returncode != 0):
            raise KitFetchError(errors.FAILURE, f"failed to materialize remote kit {shown}",
                                "check the kit cache directory, then retry")
        index.unlink()
        problems = kitspec.tree_symlinks_within(kit, kit)
        if problems:
            raise KitFetchError(errors.VALIDATION_FAILED, f"remote kit {shown} was refused: {problems[0]}",
                                "fix the kit's payload, then retry")
        (tmp / COMPLETE_MARKER).write_text(stamp, encoding="utf-8")
    except BaseException:
        _remove_tree(tmp)
        raise
    return _place(tmp, dest, lambda p: _tree_valid(p, stamp)) / "kit"


def fetch(ref: str, backend: str) -> Path:
    """The local directory of the kit ``ref`` names, fetched and verified. Raises :class:`KitFetchError`."""
    parsed = parse_ref(ref)
    shown = _shown(ref)
    git = _git_program()
    _base, src, tree = _cache_dirs(backend)
    repo = _fetch_source(git, parsed, src, shown)
    return _materialize(git, repo, parsed, tree, shown)


# ---------------------------------------------------------------------------
# Local kit directories.
#
# Bash reads a local kit in place, where anyone who can write to the directory
# can change it between acq's checks and the backend reading it. The Python acq
# copies it into the private cache first, without following any link on the
# way, and runs every check on the copy, so what was checked is what is
# applied. The copy is named by its content, like a fetched tree.
# ---------------------------------------------------------------------------

# A kit is a spec and a few payload files. A tree larger than this is almost
# certainly a mistyped path (a home directory, say), and is refused rather than
# copied.
_LOCAL_MAX_ENTRIES = 10000
_LOCAL_MAX_BYTES = 256 * 1024 * 1024
# Nesting deeper than this is refused too: the walk recurses once per level,
# and a pathologically deep tree must fail as a refusal, not a RecursionError.
_LOCAL_MAX_DEPTH = 64
_COPY_CHUNK = 1024 * 1024

# Open a directory, or a file that must not be a link, relative to its parent.
# O_NONBLOCK keeps a FIFO swapped in for a file from blocking the open; fstat
# then refuses it. O_NOCTTY keeps a terminal device swapped in from becoming
# acq's controlling terminal.
_DIR_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
_FILE_FLAGS = (os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
               | getattr(os, "O_NOCTTY", 0) | getattr(os, "O_BINARY", 0))
_WALK_BY_FD = os.open in os.supports_dir_fd and os.scandir in os.supports_fd and hasattr(os, "O_NOFOLLOW")

# Whether each file the path-based (Windows) walk opens is checked to still lie
# under the kit: the real platform, so a POSIX host can turn it on in a test.
_CHECK_FINAL_PATH = sys.platform == "win32"


class _LocalCopy:
    """One copy of a local kit tree into ``dest``, with its budget and a record of what it copied.

    On POSIX every directory is opened relative to its parent with
    ``O_NOFOLLOW``, and every file likewise, so a link swapped in for a
    directory or a file during the copy is never followed out of the kit. A
    link that is part of the kit is copied as a link, and the copy is checked
    afterwards (:func:`kitspec.tree_symlinks_within`). On Windows, which has no
    such opens, a reparse point (link or junction) anywhere in the tree is
    refused, each file must still be the file listed when it was opened, and
    the path Windows reports for the opened handle must lie under the kit
    (so a directory swapped for a junction after it was listed is caught).
    """

    def __init__(self, shown: str, root: str = ""):
        self.shown = shown
        self.root = root
        self.entries = 0
        self.bytes = 0
        self.record: list[list[str]] = []

    def refuse(self, why: str) -> KitFetchError:
        return KitFetchError(errors.VALIDATION_FAILED, f"local kit {self.shown} was refused: {why}",
                             "fix the kit directory, then retry")

    def _count(self, rel: str) -> None:
        self.entries += 1
        if self.entries > _LOCAL_MAX_ENTRIES:
            raise self.refuse(f"it has more than {_LOCAL_MAX_ENTRIES} entries (is the path right?)")
        if "\n" in rel:
            raise self.refuse("a file name contains a newline")

    def _descend(self, rel: str) -> None:
        if rel.count("/") + 1 > _LOCAL_MAX_DEPTH:
            raise self.refuse(f"it nests directories more than {_LOCAL_MAX_DEPTH} deep (is the path right?)")

    def copy_file(self, src_fd: int, target: Path, rel: str) -> None:
        info = os.fstat(src_fd)
        if not stat.S_ISREG(info.st_mode):
            raise self.refuse(f"{rel} is not a regular file")
        digest = hashlib.sha256()
        out = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0), 0o600)
        try:
            while chunk := os.read(src_fd, _COPY_CHUNK):
                self.bytes += len(chunk)
                if self.bytes > _LOCAL_MAX_BYTES:
                    raise self.refuse(f"it holds more than {_LOCAL_MAX_BYTES // (1024 * 1024)} MiB (is the path right?)")
                digest.update(chunk)
                os.write(out, chunk)
        finally:
            os.close(out)
        mode = 0o755 if info.st_mode & 0o111 else 0o644
        os.chmod(target, mode)
        self.record.append(["f", rel, f"{mode:o}", digest.hexdigest()])

    def walk_fd(self, dir_fd: int, dest: Path, prefix: str) -> None:
        with os.scandir(dir_fd) as listing:
            entries = sorted(listing, key=lambda e: e.name)
        for entry in entries:
            rel = prefix + entry.name
            self._count(rel)
            target = dest / entry.name
            if entry.is_symlink():
                link = os.readlink(entry.name, dir_fd=dir_fd)
                os.symlink(link, target)
                self.record.append(["l", rel, link])
            elif entry.is_dir(follow_symlinks=False):
                self._descend(rel)
                child = self._open(entry.name, _DIR_FLAGS, dir_fd, rel)
                try:
                    target.mkdir()
                    self.record.append(["d", rel])
                    self.walk_fd(child, target, rel + "/")
                finally:
                    os.close(child)
            elif entry.is_file(follow_symlinks=False):
                src = self._open(entry.name, _FILE_FLAGS, dir_fd, rel)
                try:
                    self.copy_file(src, target, rel)
                finally:
                    os.close(src)
            else:
                raise self.refuse(f"{rel} is not a regular file, directory or link")

    def walk_path(self, directory: str, dest: Path, prefix: str) -> None:
        with os.scandir(directory) as listing:
            entries = sorted(listing, key=lambda e: e.name)
        for entry in entries:
            rel = prefix + entry.name
            self._count(rel)
            full = os.path.join(directory, entry.name)
            target = dest / entry.name
            before = os.lstat(full)
            reparse_tag = getattr(before, "st_reparse_tag", None)  # Windows only: nonzero for any reparse point
            if entry.is_symlink() or os.path.isjunction(full) or reparse_tag:
                raise self.refuse(f"{rel} is a link or junction, which a local kit may not hold on this host")
            if stat.S_ISDIR(before.st_mode):
                self._descend(rel)
                target.mkdir()
                self.record.append(["d", rel])
                self.walk_path(full, target, rel + "/")
            elif stat.S_ISREG(before.st_mode):
                src = self._open(full, _FILE_FLAGS, None, rel)
                try:
                    after = os.fstat(src)
                    if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino):
                        raise self.refuse(f"{rel} changed while it was copied")
                    if _CHECK_FINAL_PATH and not _within(_final_path(src), self.root):
                        raise self.refuse(f"{rel} resolves outside the kit directory")
                    self.copy_file(src, target, rel)
                finally:
                    os.close(src)
            else:
                raise self.refuse(f"{rel} is not a regular file or directory")

    def _open(self, name: str, flags: int, dir_fd: int | None, rel: str) -> int:
        try:
            return os.open(name, flags, dir_fd=dir_fd)
        except OSError as exc:  # a link swapped in (ELOOP, ENOTDIR), or unreadable
            raise self.refuse(f"{rel} could not be opened safely ({exc.strerror or exc})") from exc

    def digest(self) -> str:
        # JSON keeps every entry unambiguous, whatever its names hold
        # (undecodable bytes arrive as escaped lone surrogates).
        return hashlib.sha256(json.dumps(self.record).encode("ascii")).hexdigest()


def _final_path(fd: int) -> str | None:  # pragma: no cover - Windows only
    """The path Windows reports for ``fd``'s open handle, links resolved; None when it cannot say.

    ``GetFinalPathNameByHandleW`` (normalized name, DOS volume) names the file
    the handle really refers to, whatever junctions the path that opened it
    went through. The ``\\\\?\\`` prefix it returns is dropped so the result
    compares with :func:`os.path.realpath` output.
    """
    if sys.platform != "win32":
        return None
    import ctypes
    import msvcrt

    try:
        handle = msvcrt.get_osfhandle(fd)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        function = kernel32.GetFinalPathNameByHandleW
        function.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32]
        function.restype = ctypes.c_uint32
        size = 32768
        buffer = ctypes.create_unicode_buffer(size)
        length = function(ctypes.c_void_p(handle), buffer, size, 0)
    except OSError:
        return None
    if length == 0 or length >= size:
        return None
    path = buffer.value
    if path.startswith("\\\\?\\UNC\\"):
        return "\\\\" + path[len("\\\\?\\UNC\\"):]
    return path[len("\\\\?\\"):] if path.startswith("\\\\?\\") else path


def _within(path: str | None, root: str) -> bool:
    """True when ``path`` lies under ``root`` (case and separators folded, as Windows compares them)."""
    if path is None or not root:
        return False
    folded, base = os.path.normcase(path), os.path.normcase(root).rstrip("\\/")
    return folded.startswith(base + "\\") or folded.startswith(base + "/")


def _local_root(ref: str, shown: str) -> str:
    """The local kit directory ``ref`` names, resolved once (a link to the kit itself is fine)."""
    if not hostexec._is_absolute(ref) or not os.path.isdir(ref):
        raise KitFetchError(errors.VALIDATION_FAILED, f"local kit directory {shown} was not found",
                            "name an existing kit directory (absolute, or relative to the current directory), "
                            "or a git+https://…#ref=<commit>&dir=… ref, then retry")
    return os.path.realpath(ref)


def copy_local(ref: str, backend: str) -> Path:
    """Copy the local kit directory ``ref`` into the private cache; returns the checked copy.

    Raises :class:`KitFetchError`. See :class:`_LocalCopy` for how the copy
    refuses links on the way; the copy must then pass
    :func:`kitspec.tree_symlinks_within` like a fetched tree.
    """
    shown = _shown(ref)
    root = _local_root(ref, shown)
    _base, _src, tree = _cache_dirs(backend)
    try:
        tmp = Path(tempfile.mkdtemp(prefix=".local.", dir=tree))
    except OSError as exc:
        raise KitFetchError(errors.FAILURE, f"could not create a kit directory: {exc.strerror or exc}",
                            "check that the kit cache directory is writable, then retry") from exc
    copy = _LocalCopy(shown, root)
    try:
        kit = tmp / "kit"
        kit.mkdir()
        _copy_local_tree(root, kit, copy)
        problems = kitspec.tree_symlinks_within(kit, kit)
        if problems:
            raise copy.refuse(problems[0])
        stamp = f"local\n{copy.digest()}\n"
        (tmp / COMPLETE_MARKER).write_text(stamp, encoding="utf-8")
    except BaseException:
        _remove_tree(tmp)
        raise
    return _place(tmp, tree / hashlib.sha256(stamp.encode()).hexdigest()[:32], lambda p: _tree_valid(p, stamp)) / "kit"


def _copy_local_tree(root: str, kit: Path, copy: _LocalCopy) -> None:
    try:
        if _WALK_BY_FD:
            fd = os.open(root, _DIR_FLAGS)
            try:
                copy.walk_fd(fd, kit, "")
            finally:
                os.close(fd)
        else:
            copy.walk_path(root, kit, "")
    except KitFetchError:
        raise
    except OSError as exc:
        raise KitFetchError(errors.FAILURE, f"could not copy local kit {copy.shown}: {exc.strerror or exc}",
                            "check that the kit directory is readable and the kit cache writable, then retry") from exc


def _has_crlf(path: Path) -> bool:
    try:
        return b"\r\n" in path.read_bytes()
    except OSError:
        return False  # load_kit reports a missing or unreadable spec


def load(ref: str, backend: str) -> tuple[str, kitspec.KitSpec]:
    """Fetch ``ref`` (or copy it, for a local directory) and parse its kit: ``(kit name, spec)``.

    A remote ref is fetched at its pinned commit (:func:`fetch`); a local
    directory is copied into the private cache and checked there
    (:func:`copy_local`). Either way the kit must be a neutral ``hybrid/v1``
    kit whose ``name`` is a plain kit name (it names host-side records and
    directories). Raises :class:`KitFetchError`.
    """
    shown = _shown(ref)
    kind = "remote" if is_remote(ref) else "local"
    kit_dir = fetch(ref, backend) if kind == "remote" else copy_local(ref, backend)
    if kind == "local" and _has_crlf(kit_dir / "spec.yaml"):
        # The spec reader, like Bash's, reads a CR as part of each value, so the
        # kit would be refused with a misleading reason. A Windows editor that
        # saves CRLF is the usual cause.
        raise KitFetchError(errors.VALIDATION_FAILED, f"local kit {shown} has a spec.yaml with CRLF line endings",
                            "save spec.yaml with LF line endings, then retry")
    try:
        spec = kitspec.load_kit(kit_dir)
    except kitspec.KitSpecError as exc:
        raise KitFetchError(errors.VALIDATION_FAILED, f"cannot read {kind} kit {shown}: {exc}",
                            "fix the kit, then retry") from exc
    if spec.field("schemaVersion") != "hybrid/v1":
        raise KitFetchError(errors.UNSUPPORTED,
                            f"{kind} kit {shown} is not a neutral hybrid/v1 kit; the Python acq does not pass "
                            "backend-native kits through", "use a hybrid/v1 kit, or the Bash acq (ACQ_IMPL=bash)")
    name = spec.field("name") or ""
    if not _KIT_NAME.fullmatch(name) or name in (".", ".."):
        raise KitFetchError(errors.VALIDATION_FAILED, f"{kind} kit {shown} has an unsafe or missing name",
                            "fix the kit's name: field, then retry")
    return name, spec
