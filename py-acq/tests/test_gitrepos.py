"""Workspace GitHub repository detection and the fine-grained token URL (ADR-0013).

Tier-2 tests against temporary git repositories: no network, no real checkout.
"""

from __future__ import annotations

import os
import subprocess

import pytest
from gitfixtures import GIT, git_repo, needs_git

from acq_py import gitrepos

pytestmark = needs_git


@pytest.mark.parametrize(
    "url, want",
    [
        ("https://github.com/alpha/app.git", "alpha/app"),
        ("https://github.com/alpha/app", "alpha/app"),
        ("https://github.com/alpha/app/", "alpha/app"),
        ("https://github.com/alpha/app.git/", "alpha/app"),
        ("http://github.com/alpha/app.git", "alpha/app"),
        ("https://x-access-token:ghp_EMBEDDED@github.com/alpha/app.git", "alpha/app"),
        ("git@github.com:alpha/app.git", "alpha/app"),
        ("ssh://git@github.com/alpha/app.git", "alpha/app"),
        ("git://github.com/alpha/app.git", "alpha/app"),
        ("https://GitHub.com/Alpha/App.git", "Alpha/App"),
        ("https://github.com/alpha/app/tree/main", "alpha/app"),
        ("  https://github.com/alpha/app.git\n", "alpha/app"),
        ("https://gitlab.com/alpha/app.git", None),
        ("https://github.com.evil.example/alpha/app.git", None),
        ("https://github.com/alpha", None),
        ("https://github.com//app", None),
        ("https://github.com/al\x1b[31mpha/app", None),
        ("https://github.com/alpha/a\npp", None),
        ("https://github.com/alpha/..", None),
        ("/srv/git/app.git", None),
        ("", None),
    ],
)
def test_parse_github_nwo(url, want):
    assert gitrepos.parse_github_nwo(url) == want


def test_userinfo_is_never_returned():
    nwo = gitrepos.parse_github_nwo("https://user:ghp_EMBEDDED-TOKEN@github.com/alpha/app.git")
    assert nwo == "alpha/app" and "ghp_" not in nwo


def test_one_owner(monkeypatch, tmp_path):
    ws = tmp_path / "ws"
    git_repo(monkeypatch, ws / "app", "https://github.com/alpha/app.git")
    git_repo(monkeypatch, ws / "lib", "git@github.com:Alpha/lib.git")
    git_repo(monkeypatch, ws / "dup", "ssh://git@github.com/alpha/app")
    repos = gitrepos.detect_workspace_repos(str(ws))
    assert repos == ["alpha/app", "Alpha/lib"]
    assert gitrepos.owners(repos) == ["alpha"]


def test_several_owners(monkeypatch, tmp_path):
    ws = tmp_path / "ws"
    git_repo(monkeypatch, ws / "a", "https://github.com/alpha/a.git")
    git_repo(monkeypatch, ws / "b", "https://github.com/beta/b.git")
    repos = gitrepos.detect_workspace_repos(str(ws))
    assert repos == ["alpha/a", "beta/b"]
    assert gitrepos.owners(repos) == ["alpha", "beta"]


def test_none(monkeypatch, tmp_path):
    ws = tmp_path / "ws"
    git_repo(monkeypatch, ws / "local", None)
    git_repo(monkeypatch, ws / "gitlab", "https://gitlab.com/alpha/a.git")
    (ws / "plain").mkdir()
    assert gitrepos.detect_workspace_repos(str(ws)) == []
    assert gitrepos.detect_workspace_repos(str(tmp_path / "missing")) == []
    assert gitrepos.detect_workspace_repos("") == []


def test_inherited_git_dir_pointing_elsewhere_is_ignored(monkeypatch, tmp_path):
    # A hook or editor that exported GIT_DIR (and friends) for another repo must
    # not make detection describe that repo instead of the workspace.
    other = git_repo(monkeypatch, tmp_path / "other", "https://github.com/mallory/other.git")
    ws = tmp_path / "ws"
    git_repo(monkeypatch, ws / "app", "https://github.com/alpha/app.git")
    git_repo(monkeypatch, ws / "lib", "https://github.com/alpha/lib.git")
    monkeypatch.setenv("GIT_DIR", str(other / ".git"))
    monkeypatch.setenv("GIT_WORK_TREE", str(other))
    monkeypatch.setenv("GIT_CONFIG_COUNT", "1")
    monkeypatch.setenv("GIT_CONFIG_KEY_0", "remote.origin.url")
    monkeypatch.setenv("GIT_CONFIG_VALUE_0", "https://github.com/mallory/injected.git")
    monkeypatch.setenv("GIT_CONFIG_PARAMETERS", "'remote.origin.url'='https://github.com/mallory/p.git'")
    assert gitrepos.detect_workspace_repos(str(ws)) == ["alpha/app", "alpha/lib"]
    # The workspace-is-a-repo branch is isolated the same way.
    assert gitrepos.detect_workspace_repos(str(ws / "app")) == ["alpha/app"]
    env = gitrepos.git_env()
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0",
                 "GIT_CONFIG_PARAMETERS"):
        assert name not in env
    assert env["GIT_CEILING_DIRECTORIES"] == os.environ["GIT_CEILING_DIRECTORIES"]


def test_isolation_list_covers_git_local_env_vars():
    # `git rev-parse --local-env-vars` lists the repository-local variables of
    # the installed git; every one must be cleared.
    proc = subprocess.run([GIT, "rev-parse", "--local-env-vars"], capture_output=True, text=True, check=True)
    local = set(proc.stdout.split())
    assert local, "git listed no local env vars"
    assert local <= set(gitrepos._GIT_REPO_ENV)


def test_workspace_is_itself_a_repo(monkeypatch, tmp_path):
    ws = git_repo(monkeypatch, tmp_path / "ws", "https://github.com/alpha/app.git")
    git_repo(monkeypatch, ws / "nested", "https://github.com/beta/nested.git")
    # The workspace's own remote wins; nested repos are not scanned then.
    assert gitrepos.detect_workspace_repos(str(ws)) == ["alpha/app"]
    assert gitrepos.detect_workspace_repos(str(ws / "subdir-missing")) == []


def test_falls_back_to_the_first_remote(monkeypatch, tmp_path):
    ws = tmp_path / "ws"
    git_repo(monkeypatch, ws / "app", "https://github.com/alpha/app.git", remote="upstream")
    assert gitrepos.detect_workspace_repos(str(ws)) == ["alpha/app"]


def test_skips_links_and_build_dirs(monkeypatch, tmp_path):
    ws = tmp_path / "ws"
    ws.mkdir()
    real = git_repo(monkeypatch, tmp_path / "elsewhere" / "real", "https://github.com/alpha/real.git")
    git_repo(monkeypatch, ws / "node_modules", "https://github.com/alpha/dep.git")
    try:
        os.symlink(real, ws / "link", target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("cannot create a directory symlink here")
    assert gitrepos.detect_workspace_repos(str(ws)) == []


def test_scan_is_capped(monkeypatch, tmp_path):
    ws = tmp_path / "ws"
    for i in range(3):
        (ws / f"d{i}").mkdir(parents=True)
    git_repo(monkeypatch, ws / "zz", "https://github.com/alpha/zz.git")
    monkeypatch.setattr(gitrepos, "_SCAN_CAP", 3)
    assert gitrepos.detect_workspace_repos(str(ws)) == []
    monkeypatch.setattr(gitrepos, "_SCAN_CAP", 4)
    assert gitrepos.detect_workspace_repos(str(ws)) == ["alpha/zz"]


def test_no_git_installed(monkeypatch, tmp_path):
    ws = tmp_path / "ws"
    git_repo(monkeypatch, ws / "app", "https://github.com/alpha/app.git")
    monkeypatch.setattr(gitrepos.hostexec, "which", lambda name: None)
    assert gitrepos.detect_workspace_repos(str(ws)) == []


def test_git_that_cannot_run_reads_as_no_repos(monkeypatch, tmp_path):
    ws = tmp_path / "ws"
    git_repo(monkeypatch, ws / "app", "https://github.com/alpha/app.git")
    monkeypatch.setattr(gitrepos.hostexec, "which", lambda name: str(tmp_path / "no-such-git"))
    assert gitrepos.detect_workspace_repos(str(ws)) == []


def test_pat_url_is_least_privilege_and_encoded():
    url = gitrepos.pat_url("alpha", "my box")
    assert url == (
        "https://github.com/settings/personal-access-tokens/new?name=acq-my%20box&target_name=alpha"
        "&expires_in=30&contents=write&pull_requests=write&issues=write&actions=read"
    )
    assert "workflows" not in url and "actions=write" not in url
