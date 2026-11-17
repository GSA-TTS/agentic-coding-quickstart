"""scripts/refresh-kitbundle: regenerate the kit bundle from a Patterns checkout, and check it.

The tests build a small stand-in Patterns repository, so they need git but no
network. The check against the real pinned tree runs where CI provides a
checkout of Patterns at the pin (ACQ_TEST_PATTERNS_REPO).
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import shutil
import subprocess
from pathlib import Path

import pytest

from acq_py import kitspec

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "refresh-kitbundle"

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="needs git")


def _load_script():
    loader = importlib.machinery.SourceFileLoader("refresh_kitbundle", str(SCRIPT))
    spec = importlib.util.spec_from_loader("refresh_kitbundle", loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


rk = _load_script()


def _git(repo: Path, *args: str, input_text: str | None = None) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), "-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@example.gov",
         *args],
        capture_output=True, text=True, check=True, input=input_text,
    ).stdout.strip()


def _patterns(tmp_path: Path, extra=None, index=None) -> tuple[Path, str]:
    """A stand-in Patterns repository with one commit; returns it and the commit.

    ``extra`` edits the working tree before ``git add``; ``index`` edits the
    index after it. File modes and symlinks are set in the index, never on
    disk, so the tests behave the same where git ignores the executable bit
    (core.filemode=false on Windows) or cannot create symlinks.
    """
    repo = tmp_path / "patterns"
    base = repo / rk.DIRECTORY
    for kit in rk.KITS:
        (base / kit / "files" / "home").mkdir(parents=True)
        (base / kit / "spec.yaml").write_text(f"name: {kit}\n")
        (base / kit / "files" / "home" / "payload").write_text(f"{kit} payload\n")
        (base / kit / "README.md").write_text("not bundled\n")
        (base / kit / "docs").mkdir()
        (base / kit / "docs" / "d.md").write_text("not bundled\n")
    (base / "usai-provider" / "provider-input").mkdir()
    (base / "usai-provider" / "provider-input" / "facts.json").write_text("{}\n")
    (base / "usai-provider" / "provider-input.json").write_text("{}\n")
    (base / "git-ssh-sign" / "LICENSE").write_text("Apache\n")
    (base / "git-ssh-sign" / "files" / "home" / "tool").write_text("#!/bin/sh\n")
    (base / "other-kit").mkdir()
    (base / "other-kit" / "spec.yaml").write_text("name: other\n")
    if extra:
        extra(base)
    repo.mkdir(exist_ok=True)
    _git(repo, "init", "-q")
    _git(repo, "add", "-A")
    _git(repo, "update-index", "--chmod=+x", f"{rk.DIRECTORY}/git-ssh-sign/files/home/tool")
    if index:
        index(repo)
    _git(repo, "commit", "-q", "-m", "kits")
    return repo, _git(repo, "rev-parse", "HEAD")


def test_regenerate_then_check(tmp_path):
    repo, ref = _patterns(tmp_path)
    out = tmp_path / "bundle"
    out.mkdir()
    (out / "stale").write_text("removed by a refresh\n")
    assert rk.main(["--checkout", str(repo), "--ref", ref, "--bundle", str(out)]) == 0
    assert not (out / "stale").exists()
    doc = json.loads((out / "MANIFEST.json").read_text())
    assert doc["ref"] == ref and list(doc["kits"]) == list(rk.KITS)
    assert sorted(doc["kits"]["usai-provider"]["files"]) == [
        "files/home/payload", "provider-input.json", "provider-input/facts.json", "spec.yaml"]
    assert doc["kits"]["git-ssh-sign"]["files"]["files/home/tool"]["upstream_mode"] == "100755"
    assert "LICENSE" in doc["kits"]["git-ssh-sign"]["files"]
    assert not (out / "opencode" / "README.md").exists() and not (out / "other-kit").exists()
    assert (out / "opencode" / "files" / "home" / "payload").read_text() == "opencode payload\n"
    meta = doc["kits"]["opencode"]["files"]["spec.yaml"]
    data = (out / "opencode" / "spec.yaml").read_bytes()
    assert meta == {"git_blob": rk.blob_id(data), "size": len(data), "upstream_mode": "100644"}
    assert rk.check(ref, repo, out) == []
    assert rk.main(["--check", "--checkout", str(repo), "--ref", ref, "--bundle", str(out)]) == 0


def test_check_reports_every_difference(tmp_path, capsys):
    repo, ref = _patterns(tmp_path)
    out = tmp_path / "bundle"
    rk.regenerate(ref, repo, out)
    doc = json.loads((out / "MANIFEST.json").read_text())
    files = doc["kits"]["zscaler-ca-certificate"]["files"]
    files["spec.yaml"]["git_blob"] = "0" * 40
    del files["files/home/payload"]
    files["files/home/ghost"] = {"git_blob": "1" * 40, "size": 1, "upstream_mode": "100644"}
    doc["kits"]["opencode"]["files"]["spec.yaml"]["upstream_mode"] = "100755"
    doc["directory"] = "elsewhere"
    (out / "MANIFEST.json").write_text(json.dumps(doc))
    problems = rk.check(ref, repo, out)
    assert "zscaler-ca-certificate/spec.yaml differs from the pinned tree" in problems
    assert "zscaler-ca-certificate/files/home/payload is in the pinned tree but not in MANIFEST.json" in problems
    assert "zscaler-ca-certificate/files/home/ghost is in MANIFEST.json but not in the pinned tree" in problems
    assert "opencode/spec.yaml differs from the pinned tree" in problems
    assert "MANIFEST.json names a different repository or directory" in problems
    assert rk.main(["--check", "--checkout", str(repo), "--ref", ref, "--bundle", str(out)]) == 1
    assert "differs from the pinned tree" in capsys.readouterr().err
    doc["ref"] = "2" * 40
    doc["kits"] = {"opencode": doc["kits"]["opencode"]}
    (out / "MANIFEST.json").write_text(json.dumps(doc))
    problems = rk.check(ref, repo, out)
    assert any("is pinned to" in p for p in problems)
    assert any("lists kits" in p for p in problems)


def test_refuses_non_regular_upstream_files_and_bad_arguments(tmp_path, capsys):
    def add_symlink(repo: Path) -> None:
        # A symlink entry (mode 120000) written straight into the index.
        target = _git(repo, "hash-object", "-w", "--stdin", input_text="payload")
        _git(repo, "update-index", "--add", "--cacheinfo",
             f"120000,{target},{rk.DIRECTORY}/opencode/files/home/link")

    repo, ref = _patterns(tmp_path, index=add_symlink)
    out = tmp_path / "bundle"
    assert rk.main(["--checkout", str(repo), "--ref", ref, "--bundle", str(out)]) == 2
    assert "not a regular file upstream" in capsys.readouterr().err
    assert not out.exists()
    assert rk.main(["--check", "--ref", ref]) == 2
    assert rk.main(["--ref", "main"]) == 2
    assert rk.main(["--checkout", str(repo), "--ref", "3" * 40, "--bundle", str(out)]) == 2
    assert "failed" in capsys.readouterr().err


def test_refuses_a_kit_without_spec(tmp_path):
    repo, ref = _patterns(tmp_path, lambda base: (base / "git-ssh-sign" / "spec.yaml").unlink())
    with pytest.raises(rk.RefreshError, match="git-ssh-sign has no spec.yaml"):
        rk.select(rk.tree_from_checkout(repo, ref))


def test_script_constants_match_acq():
    assert rk.pinned_ref() == kitspec.kits.CONTROL_PLANE_REF
    assert list(rk.KITS) == list(kitspec.bundle_kit_names())
    assert rk.REPOSITORY == kitspec.kits.CONTROL_PLANE_REPO
    assert rk.DIRECTORY == kitspec.kits.CONTROL_PLANE_DIR
    assert rk.BUNDLE_DIR == kitspec.BUNDLE_DIR


def test_bundle_matches_the_pinned_patterns_tree(pinned_patterns_repo):
    assert rk.check(rk.pinned_ref(), pinned_patterns_repo, rk.BUNDLE_DIR) == []
