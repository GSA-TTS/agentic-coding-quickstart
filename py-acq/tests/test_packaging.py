"""Build and CI dependencies follow the exact-pin rule (AGENTS.md "Dependencies").

A range such as ``setuptools>=77`` resolves to whatever is newest when the
package is built, so two builds of one commit can use different build backends.
These checks keep the py-acq build requirement an exact pin, hash-locked for CI,
keep the vectors workflow installing only hash-verified packages, and keep every
workflow file parseable (an invalid one silently runs nothing).
"""

from __future__ import annotations

import re
import tomllib

import yaml

from conftest import REPO_ROOT

_EXACT_PIN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*==[0-9][0-9A-Za-z.+!-]*")
_WORKFLOWS = REPO_ROOT / ".github" / "workflows"


def _build_requires() -> list[str]:
    doc = tomllib.loads((REPO_ROOT / "py-acq" / "pyproject.toml").read_text(encoding="utf-8"))
    return doc["build-system"]["requires"]


def test_the_build_requirements_are_exact_pins():
    requires = _build_requires()
    assert requires
    for requirement in requires:
        assert _EXACT_PIN.fullmatch(requirement), f"not an exact pin: {requirement!r}"


def test_the_setuptools_pin_has_pep_639_license_metadata():
    # PEP 639 (`license` as an SPDX expression, `license-files`) needs 77 or later.
    [setuptools] = [r for r in _build_requires() if r.startswith("setuptools==")]
    major = int(setuptools.split("==", 1)[1].split(".")[0])
    assert major >= 77


def test_the_hash_locked_build_requirements_match_pyproject():
    text = (REPO_ROOT / "py-acq" / "requirements-build.txt").read_text(encoding="utf-8")
    pins = re.findall(r"^([A-Za-z0-9][A-Za-z0-9._-]*==\S+)", text, re.MULTILINE)
    assert sorted(pins) == sorted(_build_requires())
    entries = [e for e in re.split(r"\n(?=[A-Za-z0-9])", text) if e[:1].isalnum()]
    for entry in entries:
        assert re.search(r"--hash=sha256:[0-9a-f]{64}", entry), entry


def test_the_vectors_workflow_installs_only_hash_verified_packages():
    workflow = (_WORKFLOWS / "python-vectors.yml").read_text(encoding="utf-8")
    installs = [line.strip() for line in workflow.splitlines() if "pip install" in line and not line.lstrip().startswith("#")]
    assert installs
    for line in installs:
        # From an index only with hashes; otherwise only a local artifact (the
        # wheel CI just built), never a source tree that pip would build itself.
        assert "--require-hashes" in line or "--no-index" in line, line
        assert "./py-acq" not in line, line
    assert "--no-build-isolation" in workflow


def test_every_workflow_is_valid_yaml():
    files = sorted(_WORKFLOWS.glob("*.yml")) + sorted(_WORKFLOWS.glob("*.yaml"))
    assert files
    for path in files:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        assert isinstance(doc, dict) and doc.get("jobs"), f"{path.name} has no jobs"
