"""Pin the relevance list of .github/workflows/windows.yml.

The workflow's `changes` job decides whether the Windows jobs run with
``git diff --name-only <base> -- <paths>``, and the always-on `Windows` gate
passes when they are skipped. A file the Windows jobs read but the list omits
would let a pull request skip the only Windows lane with a green gate. So every
tracked file must be either covered by the list or named in NOT_INPUTS below,
and every entry in either must exist: adding a file forces a decision, and a
stale entry fails rather than lingering. (test/bats/158-bash32-relevance-paths.bats
does the same for the bash 3.2 gate.)
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "windows.yml"

pytestmark = pytest.mark.skipif(
    shutil.which("git") is None or not (REPO_ROOT / ".git").exists(),
    reason="needs a git checkout of the repository",
)

# Paths the Windows jobs must react to, and why.
#   launchers and installers  acq.cmd/acq.ps1 run acq; the smoke steps run both
#                             installers' entry points; installer/ holds the
#                             asset manifest the install tests read
#   py-acq                    the code, its tests, the pytest config and the
#                             hashed tool pins the job installs
#   scripts                   staged, run or read by the pytest suite
#   qualification + ledger    imported and validated by the qualification tests
#   bats subset               06/55/117/163, the helper and stub library, and the
#                             pinned bats submodules (.gitmodules)
#   vectors + fixtures        the corpus pytest runs and the paths it invokes
#   repo files                .gitattributes (the CRLF guard), CODEOWNERS and
#                             the workflows the tests grep, and windows.yml
REQUIRED = {
    "acq.cmd", "acq.ps1", "acq", "acq-python", "acq.backends",
    "install.ps1", "install.sh", "installer",
    "py-acq/src", "py-acq/tests", "py-acq/pyproject.toml", "py-acq/requirements-quality.txt",
    "scripts/stage-windows-runtime", "scripts/gen-install-assets",
    "scripts/qualify-backend-cell", "scripts/setup-provider-input-validator",
    "scripts/test-acq-lib.sh", "scripts/refresh-kitbundle",
    "qualification", "docs/qualification-ledger.json",
    "test/bats/06-windows-install.bats", "test/bats/55-version.bats",
    "test/bats/117-msys-path-forms.bats",
    "test/bats/163-provider-input-windows-native.bats", "test/bats/helper.bash",
    "test/vendor", ".gitmodules", "test/vectors", "test/fixtures",
    ".gitattributes", ".github/CODEOWNERS",
    ".github/workflows/release.yml", ".github/workflows/tier3-release-gate.yml",
    ".github/workflows/windows.yml",
}

# Tracked paths the Windows jobs do not read: an exact path, or a directory
# prefix ending in "/". A path covered by the list wins over a prefix here
# (docs/qualification-ledger.json is listed; the rest of docs/ is prose).
NOT_INPUTS = {
    # prose, governance and repo metadata no Windows test reads
    "docs/", "checklists/", "governance/",
    "AGENTS.md", "AGENTS.fork.md", "CHANGELOG.md", "CODE_OF_CONDUCT.md", "CONTEXT-GUIDE.md",
    "CONTRIBUTING.md", "GLOSSARY.md", "LICENSE", "README.md", "SECURITY.md", "SUPPORT.md",
    "package.json", "release-please-config.json", ".release-please-manifest.json",
    "py-acq/README.md", "py-acq/requirements-dev.txt",
    # the hash-locked build backend only python-vectors.yml installs; the
    # consistency check that reads it (test_packaging.py) also runs there, on
    # every pull request
    "py-acq/requirements-build.txt",
    # lint and hook configuration
    ".gitignore", ".gitleaks.repo.toml", ".gitleaks.toml", ".markdown-link-check.json",
    ".markdownlint-cli2.yaml", ".markdownlint.jsonc", ".markdownlintignore",
    ".pre-commit-config.yaml", ".prettierrc", ".shellcheckrc",
    # GitHub configuration and the other workflows
    ".github/ISSUE_TEMPLATE/", ".github/linters/", ".github/keys/",
    ".github/dependabot.yml", ".github/pull_request_template.md", ".github/release.yml",
    ".github/workflows/bash32-compat.yml", ".github/workflows/markdown-quality.yml",
    ".github/workflows/pr-lint.yml", ".github/workflows/pre-commit.yml",
    ".github/workflows/python-quality.yml", ".github/workflows/python-vectors.yml",
    # the rest of the bats suite, which the Windows jobs do not run
    "test/bats/",
    # scripts no Windows job or test runs, sources or reads
    "scripts/bats-shard", "scripts/bats_timing_core.py", "scripts/bats_timing_render.py",
    "scripts/diagnose-host-egress-diff", "scripts/diagnose-tls-intercept",
    "scripts/fetch-bash32-oci.py", "scripts/fix-exec-bits",
    "scripts/install-provider-input-wheelhouse", "scripts/probe-macos-keychain-stdin",
    "scripts/probe-msb-node-startup", "scripts/probe-msb-posthoc-ports",
    "scripts/probe-msb-startup", "scripts/provider-input-validator-requirements-linux.txt",
    "scripts/provider-input-validator-requirements-macos.txt",
    "scripts/provider-input-validator-requirements-windows.txt",
    "scripts/provider-input-validator-requirements.txt", "scripts/qualify-msb-ro-mount",
    "scripts/rotate-apikey", "scripts/run-shellcheck", "scripts/run-vectors",
    "scripts/scan-heredoc-subst.py", "scripts/summarize-bats-timing",
    "scripts/test-acq-bash32", "scripts/test-acq-bats",
    "scripts/test-probe-msb-node-startup.py", "scripts/test-probe-msb-startup.py",
    "scripts/verify-backends", "scripts/verify-git-https-secret-msb",
    "scripts/verify-image-override", "scripts/verify-issue-320", "scripts/verify-msb-pin",
    "scripts/verify-net-default-egress", "scripts/verify-ports-live",
    "scripts/verify-sbx-startup-barrier",
}


def _pathspecs() -> list[str]:
    text = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(r'git diff --name-only "\$BASE_SHA" -- \\\n(.*?)\)"\n', text, re.S)
    assert match, "cannot find the relevance `git diff` in windows.yml"
    block = match.group(1)
    specs = re.findall(r"'([^']*)'", block)
    # Every line of the command is one single-quoted pathspec and a continuation,
    # so nothing in it escapes the parser.
    for line in block.splitlines():
        assert re.fullmatch(r"\s*'[^']+'( \\)?", line), f"unexpected line in the relevance list: {line!r}"
    return specs


def _tracked() -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files", "-z"], capture_output=True, check=True
    ).stdout
    return [p.decode("utf-8") for p in out.split(b"\0") if p]


def _covered_by(path: str, spec: str) -> bool:
    return path == spec or path.startswith(spec.rstrip("/") + "/")


def _not_input(path: str) -> bool:
    return any(path.startswith(n) if n.endswith("/") else path == n for n in NOT_INPUTS)


def test_the_list_has_every_required_path_and_no_duplicates():
    specs = _pathspecs()
    assert len(specs) == len(set(specs)), "duplicate pathspecs in windows.yml"
    assert set(specs) == REQUIRED, (
        f"missing: {sorted(REQUIRED - set(specs))}; unexpected: {sorted(set(specs) - REQUIRED)}"
    )


def test_every_listed_pathspec_exists():
    tracked = _tracked()
    stale = [s for s in _pathspecs() if not any(_covered_by(f, s) for f in tracked)]
    assert not stale, f"pathspecs that match no tracked file: {stale}"


def test_every_not_input_exists_and_is_not_also_listed():
    tracked = _tracked()
    specs = _pathspecs()
    stale = [n for n in NOT_INPUTS if not any(_not_input(f) and (f == n or f.startswith(n)) for f in tracked)]
    assert not stale, f"NOT_INPUTS entries that match no tracked file: {sorted(stale)}"
    listed = [n for n in NOT_INPUTS if not n.endswith("/") and any(_covered_by(n, s) for s in specs)]
    assert not listed, f"in both the relevance list and NOT_INPUTS: {listed}"


def test_every_tracked_file_is_listed_or_a_known_non_input():
    specs = _pathspecs()
    uncovered = [
        f for f in _tracked() if not any(_covered_by(f, s) for s in specs) and not _not_input(f)
    ]
    assert not uncovered, (
        "tracked files in neither the windows.yml relevance list nor NOT_INPUTS: "
        f"{uncovered}. If a Windows job or test reads one, add it to the workflow list "
        "and REQUIRED; if not, add it to NOT_INPUTS."
    )
