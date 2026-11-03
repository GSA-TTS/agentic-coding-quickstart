"""Tier-2 implementation tests for backend detection and version floors.

Non-contract evidence (ADR-0039m): these reach into ``acq_py.backends`` directly.
Contract evidence lives only in the vector corpus (``test/vectors``).
"""

from __future__ import annotations

import acq_py.backends as backends


def test_parse_version_bare():
    v = backends.parse_version("0.39.0")
    assert v is not None
    assert (v.major, v.minor, v.patch) == (0, 39, 0)
    assert v.final is True
    assert v.string == "0.39.0"


def test_parse_version_strips_prefix_and_suffix():
    v = backends.parse_version("msb 0.7.7")
    assert v is not None and v.string == "0.7.7"

    v = backends.parse_version("v0.39.0")
    assert v is not None and v.string == "0.39.0"

    v = backends.parse_version("0.7.3-rc1")
    assert v is not None and v.string == "0.7.3" and v.final is False


def test_parse_version_unparseable():
    assert backends.parse_version("garbage") is None
    assert backends.parse_version("") is None
    assert backends.parse_version(None) is None  # type: ignore[arg-type]


def test_version_ge_ignores_final():
    final = backends.parse_version("0.7.3")
    rc = backends.parse_version("0.7.3-rc1")
    assert final is not None and rc is not None
    # Numeric core is equal, so >= holds regardless of the final flag.
    assert backends.version_ge(rc, final)
    assert backends.version_ge(final, rc)


def test_check_version_floor(monkeypatch):
    sbx = backends.BACKENDS["sbx"]

    monkeypatch.setenv("ACQ_SBX_VERSION", "0.35.0")
    problem = backends.check_version(sbx)
    assert problem is not None and problem.code == "backend_version_unsupported"

    monkeypatch.setenv("ACQ_SBX_VERSION", "garbage")
    problem = backends.check_version(sbx)
    assert problem is not None and problem.code == "backend_version_unknown"

    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    assert backends.check_version(sbx) is None


def test_check_version_blocked(monkeypatch):
    msb = backends.BACKENDS["msb"]

    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.1")
    problem = backends.check_version(msb)
    assert problem is not None and problem.code == "backend_version_unsupported"

    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.3")
    assert backends.check_version(msb) is None

    # Prerelease of a fixed version is still refused (final-release gate).
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.3-rc1")
    problem = backends.check_version(msb)
    assert problem is not None and problem.code == "backend_version_unsupported"


def test_check_version_not_found(monkeypatch):
    sbx = backends.BACKENDS["sbx"]
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    problem = backends.check_version(sbx)
    assert problem is not None and problem.code == "backend_not_found"
