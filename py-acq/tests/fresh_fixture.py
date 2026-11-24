"""Explicit fresh-profile fixtures; synthetic outcomes, never live qualification.

Subprocess tests provision their own directory below a validated private base,
even when pytest uses /tmp. No shared ancestor is chmodded and the real CA
validator remains enabled. In-process tests retain their modeled metadata seam.
"""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
from pathlib import Path

import pytest

# Capture before the autouse fixture replaces HOME with a directory under /tmp.
_TEST_HOME = Path.home()


def _trusted_base(root):
    try:
        if not root.is_absolute() or root != root.resolve(strict=True):
            return False
        for path in (root, *root.parents):
            info = path.lstat()
            if (not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o022
                    or info.st_uid not in (0, os.getuid())):
                return False
        return True
    except OSError:
        return False


@pytest.fixture
def trusted_fresh_root(tmp_path, pytestconfig):
    for base in (tmp_path, Path(pytestconfig.rootpath), _TEST_HOME):
        if not _trusted_base(base):
            continue
        try:
            temporary = tempfile.TemporaryDirectory(prefix="acq-fresh-test-", dir=base)
        except OSError:
            continue
        with temporary as directory:
            root = Path(directory)
            # Only our exclusively created directory; guest mount traversal may
            # require read/execute for the unprivileged guest uid.
            root.chmod(0o755)
            assert _trusted_base(root)
            yield root
        return
    pytest.fail("fresh subprocess tests require a writable trusted checkout or HOME with "
                "root/test-uid-owned, non-symlink, non-group/world-writable ancestors; "
                "provision e.g. HOME=/validation/home before pytest (not /tmp/home)")


def fresh_fixture(monkeypatch, tmp_path, *, real_ancestors=False):
    """Keep the real profile, generation, binding, transport and result gates."""
    if os.name != "posix":
        pytest.skip("fresh preparation is POSIX-only")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.16")
    monkeypatch.setenv("ACQ_MSB_STUB_FRESH", "1")
    monkeypatch.setenv("ACQ_MSB_STUB_PREPARATION_STDOUT", json.dumps(
        {"sourceOutcome": "live", "metadataOutcome": "not-requested"}))
    monkeypatch.setenv("ACQ_MSB_STUB_PREPARATION_EXIT", "0")
    validator = tmp_path / "validator-python"
    validator.write_text(f"#!{sys.executable}\n" + _VALIDATOR_FIXTURE, encoding="utf-8")
    validator.chmod(0o700)
    monkeypatch.setenv("ACQ_PROVIDER_INPUT_PYTHON", str(validator))
    ca = Path(os.environ["MSB_HOME"]) / "tls/ca.crt"
    ca.parent.mkdir(parents=True, exist_ok=True)
    # Public-only synthetic syntax, deliberately not a usable trust anchor.
    ca.write_text("-----BEGIN CERTIFICATE-----\nU1lOVEhFVElD\n-----END CERTIFICATE-----\n", encoding="ascii")
    ca.chmod(0o444)
    if not real_ancestors:
        _model_ancestors(monkeypatch, tmp_path)


def qualified_session_fixture(monkeypatch):
    """Opt in only session tests; never fabricate a provider preparation result."""
    from acq_py import _stub_msb

    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.16")
    monkeypatch.setenv("ACQ_MSB_STUB_FRESH", "1")
    for name in _stub_msb._load():
        if name not in _stub_msb._fixture_read("fresh-instances"):
            _stub_msb._fresh_created(name, ["synthetic-legacy-image"])


def _model_ancestors(monkeypatch, tmp_path):
    ancestors = set(tmp_path.parents)
    original = Path.lstat

    def trusted_ancestors(path, *args, **kwargs):
        info = original(path, *args, **kwargs)
        if path in ancestors:
            info = os.stat_result((stat.S_IFDIR | 0o755, *tuple(info)[1:]))
        return info

    monkeypatch.setattr(Path, "lstat", trusted_ancestors)


_VALIDATOR_FIXTURE = '''import json
import sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == "-I"
if args[1] == "-c":
    assert "PyYAML" in args[2] and "jsonschema" in args[2]
else:
    assert Path(args[1]).is_file()
    assert "--schema-dir" in args and "--credential-bindings" in args
    paths = [Path(args[i + 1]) for i, arg in enumerate(args) if arg == "--bundle"]
    assert len(paths) == 1
    manifest = json.loads(paths[0].read_text())
    assert manifest["schemaVersion"] == "acq-provider-input-bundle/v3"
    assert manifest["providerId"] == "usai" and "normalizerPath" not in manifest
    for field in ("factsPath", "snapshotPath"):
        json.loads((paths[0].parent / manifest[field]).read_text())
'''


def jobs(name):
    path = Path(os.environ["MSB_HOME"]) / ".microsandbox/fresh-jobs.json"
    return list(json.loads(path.read_text(encoding="utf-8")).get(name, {}).values()) if path.exists() else []
