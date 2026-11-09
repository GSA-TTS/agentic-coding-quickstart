"""GitHub repositories in a workspace, and the fine-grained token URL (ADR-0013).

``github-scope`` needs to know which GitHub repositories a sandbox mounts, so
it can point the user at a fine-grained personal access token limited to those
repositories (GitHub has no API to mint one). This mirrors the Bash
``detect_workspace_repos``, ``_acq_parse_github_nwo`` and
``_acq_github_pat_url``: the workspace may itself be a repository, or a parent
whose immediate children are repositories; each repository's
``remote.origin.url`` (else its first configured remote) is parsed into
``owner/repo``. Nothing here touches the network or writes anything.

The workspace is agent-writable, and acq can be started from a git hook, an
editor or another git command that exports ``GIT_DIR`` and friends. Those
variables would make every read below describe some other repository, so they
are removed from the environment git runs with (see :func:`git_env`).
"""

from __future__ import annotations

import os
import re
import subprocess
from urllib.parse import quote

from . import hostexec

# Variables that point git at a repository, work tree, index, object store or
# ref namespace other than the one found from ``-C``, or that send config reads
# to another file (the Bash ``_kit_git_isolate_repo`` list). The command-scope
# config variables are dropped as well: detection should read the workspace
# repository's own remotes, not a remote injected by the caller's environment.
# GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM and discovery settings such as
# GIT_CEILING_DIRECTORIES are kept: they are the user's own configuration.
_GIT_REPO_ENV = frozenset(
    {
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CONFIG",
        "GIT_OBJECT_DIRECTORY",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_IMPLICIT_WORK_TREE",
        "GIT_GRAFT_FILE",
        "GIT_INDEX_FILE",
        "GIT_NO_REPLACE_OBJECTS",
        "GIT_REPLACE_REF_BASE",
        "GIT_PREFIX",
        "GIT_SHALLOW_FILE",
        "GIT_COMMON_DIR",
        "GIT_NAMESPACE",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
    }
)
_GIT_CONFIG_PAIR = re.compile(r"GIT_CONFIG_(KEY|VALUE)_[0-9]+")

# Child directories never worth scanning (the Bash skip list), and the scan cap.
_SKIP_DIRS = frozenset({"node_modules", ".venv", "venv", "vendor", "target", "dist", "build"})
_SCAN_CAP = 200
_GIT_TIMEOUT_S = 10.0

# The github.com remote forms Bash recognises (https/http, scp-like ssh, ssh://
# and git://). An https/http remote may carry userinfo (a token embedded in the
# URL); it is matched and dropped, never returned.
_REMOTE_PREFIX = re.compile(
    r"(?:https?://(?:[^/@]*@)?github\.com/|git@github\.com:|ssh://git@github\.com/|git://github\.com/)(?P<rest>.*)",
    re.IGNORECASE | re.DOTALL,
)
# GitHub account and repository names. Anything else is not a GitHub name and is
# skipped, so a crafted remote cannot put control characters in acq's output.
# Owners allow "_" and a longer name for Enterprise Managed User handles
# (``user_shortcode``), which ordinary account names never contain.
_OWNER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,99}", re.ASCII)
_REPO_RE = re.compile(r"[A-Za-z0-9._-]{1,100}", re.ASCII)

PAT_PERMISSIONS = (("contents", "write"), ("pull_requests", "write"), ("issues", "write"), ("actions", "read"))


def git_env() -> dict[str, str]:
    """The environment for git reads: the caller's, minus repository redirects."""
    return {
        k: v for k, v in os.environ.items() if k not in _GIT_REPO_ENV and not _GIT_CONFIG_PAIR.fullmatch(k)
    }


def _git(git: str, cwd: str, *args: str) -> str | None:
    """``git -C cwd ARGS`` stdout, or None if git failed or could not run."""
    try:
        proc = subprocess.run(
            [git, "-C", cwd, *args],
            env=git_env(),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=_GIT_TIMEOUT_S,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return proc.stdout if proc.returncode == 0 else None


def parse_github_nwo(url: str) -> str | None:
    """``owner/repo`` for a github.com remote URL, else None. Pure string work."""
    match = _REMOTE_PREFIX.fullmatch(url.strip())
    if match is None:
        return None
    rest = match.group("rest").rstrip("/")
    rest = rest[: -len(".git")] if rest.lower().endswith(".git") else rest
    owner, _, tail = rest.partition("/")
    repo = tail.split("/", 1)[0]
    if not _OWNER_RE.fullmatch(owner) or not _REPO_RE.fullmatch(repo) or repo in (".", ".."):
        return None
    return f"{owner}/{repo}"


def _is_link(entry: os.DirEntry) -> bool:
    if entry.is_symlink():
        return True
    isjunction = getattr(entry, "is_junction", None)
    return bool(isjunction is not None and isjunction())


def _candidate_repos(git: str, path: str) -> list[str]:
    """The workspace itself if it is inside a work tree, else its child repos."""
    if (_git(git, path, "rev-parse", "--is-inside-work-tree") or "").strip() == "true":
        return [path]
    out: list[str] = []
    try:
        entries = sorted(os.scandir(path), key=lambda e: e.name)
    except OSError:
        return out
    scanned = 0
    for entry in entries:
        try:
            if _is_link(entry) or not entry.is_dir(follow_symlinks=False) or entry.name in _SKIP_DIRS:
                continue
        except OSError:
            continue
        scanned += 1
        if scanned > _SCAN_CAP:
            break
        if os.path.lexists(os.path.join(entry.path, ".git")):
            out.append(entry.path)
    return out


def _remote_url(git: str, repo: str) -> str:
    url = (_git(git, repo, "config", "--get", "remote.origin.url") or "").strip()
    if url:
        return url
    listing = _git(git, repo, "config", "--get-regexp", r"^remote\..*\.url$") or ""
    first = listing.splitlines()[0] if listing.strip() else ""
    return first.split(" ", 1)[1].strip() if " " in first else ""


def detect_workspace_repos(path: str) -> list[str]:
    """Deduplicated ``owner/repo`` names for every github.com remote in ``path``.

    An empty list means git is not installed, ``path`` is not a directory, or no
    repository there has a GitHub remote.
    """
    git = hostexec.which("git")
    if git is None or not path or not os.path.isdir(path):
        return []
    found: list[str] = []
    for repo in _candidate_repos(git, path):
        nwo = parse_github_nwo(_remote_url(git, repo))
        if nwo is not None and nwo not in found:
            found.append(nwo)
    return found


def owners(repos: list[str]) -> list[str]:
    """Distinct owners of ``repos`` (GitHub names ignore case; the first spelling wins)."""
    seen: dict[str, str] = {}
    for nwo in repos:
        owner = nwo.split("/", 1)[0]
        seen.setdefault(owner.lower(), owner)
    return list(seen.values())


def pat_url(owner: str, sandbox: str) -> str:
    """Pre-filled fine-grained token creation URL for one owner (no token in it).

    Least privilege by default (ADR-0013): contents, pull requests and issues at
    read/write, actions read-only, no workflows; a 30-day expiry. The user picks
    the repositories in the form.
    """
    perms = "&".join(f"{name}={level}" for name, level in PAT_PERMISSIONS)
    return (
        "https://github.com/settings/personal-access-tokens/new"
        f"?name={quote('acq-' + sandbox, safe='')}&target_name={quote(owner, safe='')}&expires_in=30&{perms}"
    )
