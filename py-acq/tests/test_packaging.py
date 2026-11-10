"""Build and CI dependencies follow the exact-pin rule (AGENTS.md "Dependencies").

A range such as ``setuptools>=77`` resolves to whatever is newest when the
package is built, so two builds of one commit can use different build backends.
These checks keep the py-acq build requirement an exact pin and keep the vectors
workflow installing only hash-verified packages.
"""

from __future__ import annotations

import re
import tomllib

from conftest import REPO_ROOT

_EXACT_PIN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*==[0-9][0-9A-Za-z.+!-]*")


def test_the_build_requirements_are_exact_pins():
    doc = tomllib.loads((REPO_ROOT / "py-acq" / "pyproject.toml").read_text(encoding="utf-8"))
    requires = doc["build-system"]["requires"]
    assert requires
    for requirement in requires:
        assert _EXACT_PIN.fullmatch(requirement), f"not an exact pin: {requirement!r}"


def test_the_setuptools_pin_has_pep_639_license_metadata():
    # PEP 639 (`license` as an SPDX expression, `license-files`) needs 77 or later.
    doc = tomllib.loads((REPO_ROOT / "py-acq" / "pyproject.toml").read_text(encoding="utf-8"))
    [setuptools] = [r for r in doc["build-system"]["requires"] if r.startswith("setuptools==")]
    major = int(setuptools.split("==", 1)[1].split(".")[0])
    assert major >= 77


def test_the_vectors_workflow_installs_only_hash_verified_packages():
    workflow = (REPO_ROOT / ".github" / "workflows" / "python-vectors.yml").read_text(encoding="utf-8")
    installs = [line.strip() for line in workflow.splitlines() if "pip install" in line and not line.lstrip().startswith("#")]
    assert installs
    for line in installs:
        assert "--require-hashes" in line, line
        assert "./py-acq" not in line, line  # a local build would fetch setuptools unhashed
