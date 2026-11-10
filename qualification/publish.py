"""Git side of ``python -m qualification.host`` (ADR-0044m): checkout checks, fork
remote selection, and the ledger PR.

Safety rules, all enforced here: only a fork remote is ever pushed to (every fetch
and push URL of a remote must be a non-upstream repo and name the same repo); the
only ref pushed is a new ``chore/ledger-*`` branch; the user's checkout is never
switched or edited (the ledger change is made in a throwaway worktree). The
upstream ``GSA-TTS`` repository is hardcoded as off-limits; update ``UPSTREAM`` if
it is ever renamed.

Python >= 3.12, standard library only.
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from . import hostexec
from .ledger import DEFAULT_LEDGER

UPSTREAM = re.compile(r"github\.com[:/]GSA-TTS/agentic-coding-quickstart(\.git)?/?$", re.I)
_SLUG = re.compile(r"github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?/?$", re.I)
_REMOTE_MAIN = re.compile(r"[^/]+/main")
_OFF_LIMITS_OWNERS = {"gsa-tts"}  # the whole upstream org, not just the one repository


class HostError(Exception):
    """A precondition failed; nothing was run or published."""


def git(root: Path, *args: str, env: dict | None = None) -> str:
    proc = subprocess.run(
        [*hostexec.command("git"), *args], cwd=root, capture_output=True, text=True, errors="replace",
        env={**os.environ, **env} if env else None,
    )
    if proc.returncode != 0:
        raise HostError(f"git {' '.join(args)} failed: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout


def check_checkout(root: Path, remote: str | None = None) -> str:
    """HEAD's sha if the tree is clean and HEAD is on ``<remote>/main``; else raise.

    Without a ``remote`` (``--no-publish``) any remote's ``main`` counts.
    """
    if git(root, "status", "--porcelain").strip():
        raise HostError("the working tree has uncommitted or untracked changes; the run must test exactly HEAD")
    head = git(root, "rev-parse", "HEAD").strip()
    refs = [line.strip().split(" -> ")[-1] for line in git(root, "branch", "-r", "--contains", head).splitlines()]
    wanted = f"{remote}/main" if remote else None
    if not any(r == wanted if wanted else _REMOTE_MAIN.fullmatch(r) for r in refs):
        raise HostError(
            f"HEAD {head[:12]} is not on {wanted or 'a remote main branch'}; run 'git fetch' and "
            f"'git switch --detach {wanted or '<remote>/main'}' (the ledger can only record a commit on main)"
        )
    return head


def artifact_sha256(root: Path) -> str:
    """SHA-256 of ``git archive HEAD`` (identity of the tested tree, any OS)."""
    digest = hashlib.sha256()
    with subprocess.Popen([*hostexec.command("git"), "archive", "HEAD"], cwd=root, stdout=subprocess.PIPE) as proc:
        for chunk in iter(lambda: proc.stdout.read(1 << 20), b""):
            digest.update(chunk)
    if proc.returncode != 0:
        raise HostError("git archive HEAD failed")
    return digest.hexdigest()


def choose_remote(root: Path, explicit: str | None) -> tuple[str, str]:
    """``(remote name, owner/repo)`` of the fork to publish to; never the upstream.

    Every fetch and push URL of a remote is considered (``git remote get-url --all``,
    with ``insteadOf`` rewrites applied): one upstream URL disqualifies the remote,
    and all URLs must name the same repository.
    """
    urls = {}
    for name in git(root, "remote").split():
        urls[name] = (
            git(root, "remote", "get-url", "--all", name).split()
            + git(root, "remote", "get-url", "--push", "--all", name).split()
        )
    forks = {n: u for n, u in urls.items() if not any(UPSTREAM.search(x) for x in u)}
    if explicit:
        if explicit not in urls:
            raise HostError(f"no git remote named {explicit!r}")
        if explicit not in forks:
            raise HostError(f"{explicit!r} is (or also pushes to) the upstream repository; this tooling only publishes to a fork")
        name = explicit
    elif len(forks) == 1:
        name = next(iter(forks))
    else:
        raise HostError(f"cannot pick a fork remote from {sorted(forks) or 'none'}; pass --remote NAME")
    slugs = [None if re.search(r"[?#]", x) else _SLUG.search(x) for x in forks[name]]
    if not slugs or None in slugs or len({m.group(1).lower() for m in slugs}) != 1:
        raise HostError(
            f"remote {name!r} does not name exactly one github.com repository over a plain https/ssh URL "
            f"(ssh host aliases, enterprise hosts, query strings and paths with spaces are not supported): {forks[name]}"
        )
    slug = slugs[0].group(1)
    if slug.split("/")[0].lower() in _OFF_LIMITS_OWNERS:
        raise HostError(f"remote {name!r} is in the upstream organisation ({slug}); this tooling only publishes to a personal fork")
    return name, slug


def check_identity(root: Path) -> None:
    for key in ("user.name", "user.email"):
        try:
            if not git(root, "config", key).strip():
                raise HostError(f"git {key} is empty")
        except HostError:
            raise HostError(f"git {key} is not set; the ledger commit needs an identity") from None


def check_remote_reachable(root: Path, remote: str) -> None:
    git(root, "ls-remote", "--exit-code", remote, "refs/heads/main", env={"GIT_TERMINAL_PROMPT": "0"})


def remote_main_tip(root: Path, remote: str, fallback: str) -> str:
    """The commit to branch the ledger change from: ``<remote>/main``, freshly fetched.

    Falls back to the existing remote-tracking ref when the fetch fails (offline), and
    to ``fallback`` (the tested revision) when there is no tracking ref either, so an
    unreachable remote degrades to the old behaviour instead of aborting a long run.
    """
    git_exe = hostexec.command("git")
    fetched = subprocess.run(
        [*git_exe, "fetch", "-q", remote, "main"], cwd=root, capture_output=True, text=True,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
    ).returncode == 0
    for ref in (["FETCH_HEAD"] if fetched else []) + [f"refs/remotes/{remote}/main"]:
        proc = subprocess.run([*git_exe, "rev-parse", "--verify", "--quiet", ref], cwd=root,
                              capture_output=True, text=True)
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    sys.stderr.write(
        f"qualification.host: cannot resolve {remote}/main; branching from the tested "
        f"revision {fallback[:12]}, which may conflict with a concurrent ledger change\n"
    )
    return fallback


def publish(
    root: Path, *, remote: str, slug: str, rev: str, platform: str, title: str, body: str,
    edit: Callable[[Path], None], verify: Callable[[Path], str | None],
) -> str:
    """Commit an edited ledger on a new branch of the fork and open a PR; return its branch.

    The branch is cut from the **remote's current** ``main``, not from ``rev``: two
    hosts recording at the same time (or one recording while another's ledger PR
    merges) both rewrite the whole of ``docs/qualification-ledger.json``, so a branch
    cut from the tested revision conflicts with whatever landed meanwhile. ``rev`` is
    still what was tested and what each ledger entry records; only the branch point
    moves, and ``edit`` appends to the ledger as it stands on that tip, so entries
    from the other host are preserved rather than reverted.

    ``edit(path)`` changes the ledger inside a throwaway worktree; ``verify(worktree)``
    returns a reason to abort (nothing is pushed) or ``None``.
    """
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    branch = f"chore/ledger-{platform}-{stamp}"
    worktree = root / "tmp" / f"ledger-{stamp}"
    worktree.parent.mkdir(exist_ok=True)
    base = remote_main_tip(root, remote, rev)
    git(root, "worktree", "add", "-q", "-b", branch, str(worktree), base)
    try:
        if base != rev:
            print(f"branching from {remote}/main {base[:12]} (tested {rev[:12]})")
        edit(worktree / DEFAULT_LEDGER)
        # Re-resolve the remote from the worktree (includeIf can differ per worktree)
        # and require it to still be the same fork before anything is pushed.
        if choose_remote(worktree, remote) != (remote, slug):
            raise HostError(f"remote {remote!r} resolves differently inside the worktree; refusing to push")
        why = verify(worktree)
        if why:
            raise HostError(f"the recorded runs would not qualify their cells, so nothing was published: {why}")
        git(worktree, "add", DEFAULT_LEDGER)
        git(worktree, "commit", "-q", "-m", title)
        git(worktree, "push", "-q", "--no-follow-tags", remote, branch)
        print(f"pushed {remote}/{branch}")
        gh = hostexec.which("gh")
        opened = gh is not None and subprocess.run(
            [gh, "pr", "create", "--repo", slug, "--base", "main", "--head", branch, "--title", title, "--body", body]
        ).returncode == 0
        if not opened:
            print(f"open the PR yourself (into {slug}:main): https://github.com/{slug}/pull/new/{branch}\n\n{title}\n\n{body}")
        return branch
    finally:
        for args in (("worktree", "remove", "--force", str(worktree)), ("branch", "-D", branch)):
            proc = subprocess.run([*hostexec.command("git"), *args], cwd=root, capture_output=True, text=True)
            if proc.returncode != 0:
                sys.stderr.write(f"qualification.host: cleanup 'git {' '.join(args)}' failed: {proc.stderr.strip()}\n")
