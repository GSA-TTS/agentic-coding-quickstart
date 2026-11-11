"""A release carries its own identity even without a checkout."""
from types import SimpleNamespace

from acq_py import version_info


def test_checkout_fallback(monkeypatch):
    # A source checkout never carries a baked identity (it is generated into
    # release trees only and ignored by git).
    assert version_info._build_info is None
    monkeypatch.delenv("ACQ_VERSION", raising=False)
    monkeypatch.delenv("ACQ_SOURCE_REVISION", raising=False)
    monkeypatch.setattr(version_info, "_build_info", None)
    monkeypatch.setattr(version_info, "_git_revision", lambda: "checkout")
    assert version_info.acq_version() == version_info.__version__
    assert version_info.source_revision() == "checkout"


def test_baked_identity_wins_without_git_probe(monkeypatch):
    monkeypatch.delenv("ACQ_VERSION", raising=False)
    monkeypatch.delenv("ACQ_SOURCE_REVISION", raising=False)
    monkeypatch.setattr(version_info, "_build_info", SimpleNamespace(ACQ_VERSION="8.0.0", SOURCE_REVISION="baked"))
    def unexpected_probe():
        raise AssertionError("a baked release must not consult git")
    monkeypatch.setattr(version_info, "_git_revision", unexpected_probe)
    assert version_info.acq_version() == "8.0.0"
    assert version_info.source_revision() == "baked"
    monkeypatch.setenv("ACQ_VERSION", "9.0.0")
    monkeypatch.setenv("ACQ_SOURCE_REVISION", "override")
    assert version_info.acq_version() == "9.0.0"
    assert version_info.source_revision() == "override"
