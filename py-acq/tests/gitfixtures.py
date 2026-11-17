"""Temporary git repositories for the github-scope tests (no network)."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

GIT = shutil.which("git")
needs_git = pytest.mark.skipif(GIT is None, reason="needs git")


def _clean_env() -> dict[str, str]:
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def git_repo(monkeypatch, path: Path, url: str | None, *, remote: str = "origin") -> Path:
    """``git init`` at ``path`` with ``remote`` pointing at ``url`` (None: no remote).

    Discovery is capped at the directory above the workspace, so a checkout that
    happens to contain the test's temporary directory is never found instead.
    """
    if GIT is None:
        pytest.skip("needs git")
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run([GIT, "init", "-q", str(path)], env=_clean_env(), check=True, capture_output=True)
    if url is not None:
        subprocess.run(
            [GIT, "-C", str(path), "config", f"remote.{remote}.url", url],
            env=_clean_env(), check=True, capture_output=True,
        )
    monkeypatch.setenv("GIT_CEILING_DIRECTORIES", str(path.parent.parent))
    return path
