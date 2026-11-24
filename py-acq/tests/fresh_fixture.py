"""Explicit fresh-profile fixtures; synthetic outcomes, never live qualification.

Subprocess tests require pytest --basetemp under a sandbox-local private mount
with non-symlink, non-group/world-writable ancestors owned by root or the test
uid. The runner must provision it; we never chmod shared /tmp or relax the
subprocess CA policy. In-process tests retain the narrowly modeled ancestor
metadata seam while exercising the actual CA file read and parser.
"""

from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

import pytest


@pytest.fixture
def trusted_fresh_root(tmp_path):
    root = tmp_path
    assert root.is_absolute() and root == root.resolve(strict=True)
    for path in (root, *root.parents):
        info = path.lstat()
        assert stat.S_ISDIR(info.st_mode) and not info.st_mode & 0o022, (
            f"fresh subprocess tests need --basetemp under a trusted private sandbox mount: {path}")
        assert info.st_uid in (0, os.getuid()), path
    return root


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
