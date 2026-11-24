"""Private-loader fixtures use a FAKE SDK, not PyO3/native qualification.

Run only in the workspace sandbox. The optional real-wheel probe loads but does
not create/connect a sandbox or execute native guest work.
"""

import hashlib
import importlib
import io
import json
import os
import subprocess
import sys
from dataclasses import asdict, replace
from pathlib import Path
from types import ModuleType

import pytest

from acq_py import sdk_runtime as runtime

# Non-ACQ names deliberately survive the repository's environment scrub.
REAL_CONFIG = os.environ.get("PRIVATE_SDK_PROBE_CONFIG", "")
REAL_PYTHON = os.environ.get("PRIVATE_SDK_PROBE_PYTHON", "")
FAKE_SDK = '''"""FAKE SDK used only to test loader ordering and origin checks."""
import os
from types import SimpleNamespace
assert os.environ["MSB_PATH"] and os.environ["MSB_HOME"]
class BackendKind:
    LOCAL = "local"
selected = False
calls = 0
def set_default_backend(kind):
    global selected, calls
    assert kind == BackendKind.LOCAL
    assert not selected
    selected = True
    calls += 1
def default_backend_kind():
    assert selected
    return BackendKind.LOCAL
def default_backend_info():
    assert selected
    return SimpleNamespace(kind="local", api_url=None, profile=None)
def resolve_runtime():
    assert selected
    return SimpleNamespace(msb_path=os.environ["MSB_PATH"],
                           libkrunfw_path=os.environ["MSB_LIBKRUNFW_PATH"])
'''


def manifest(root, *, records=None, version="0.7.16"):
    if records is None:
        records = {}
        for path in root.rglob("*"):
            if path.is_file() and path.name != runtime.MANIFEST:
                data = path.read_bytes()
                records[path.relative_to(root).as_posix()] = {
                    "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    raw = json.dumps({"schema": 1, "version": version, "files": records}).encode()
    (root / runtime.MANIFEST).write_bytes(raw)
    return hashlib.sha256(raw).hexdigest()


@pytest.fixture
def private(tmp_path, monkeypatch):
    # resolve the test base on macOS, where /var itself is a symlink.
    base = tmp_path.resolve()
    root = base / "payload"
    package = root / "microsandbox"
    package.mkdir(parents=True)
    (package / "__init__.py").write_text(FAKE_SDK)
    (package / "msb").write_bytes(b"fake-binary-not-executed")
    (package / "msb").chmod(0o700)
    (package / "firmware").write_bytes(b"fake-firmware-not-loaded")
    dist = root / runtime.DIST_INFO
    dist.mkdir()
    (dist / "METADATA").write_text("Metadata-Version: 2.1\nName: microsandbox\nVersion: 0.7.16\n")
    home = base / "home"
    home.mkdir()
    config_path = base / "config.json"
    config_path.write_text("{}")
    config = runtime.SDKRuntimeConfig(str(root), manifest(root), str(package / "msb"),
                                      str(package / "firmware"), str(home), str(config_path))
    for key in list(os.environ):
        if key.startswith("MSB_"):
            monkeypatch.delenv(key)
    for key, value in child_environment(config).items():
        if key.startswith("MSB_"):
            monkeypatch.setenv(key, value)
    monkeypatch.setattr(sys, "dont_write_bytecode", True)
    monkeypatch.setattr(sys, "path", sys.path.copy())
    monkeypatch.setattr(runtime, "_ATTEMPTED", False)
    monkeypatch.setattr(runtime, "_LOADED", None)
    previous = {k: v for k, v in sys.modules.items()
                if k == "microsandbox" or k.startswith("microsandbox.")}
    for key in previous:
        del sys.modules[key]
    yield config
    for key in list(sys.modules):
        if key == "microsandbox" or key.startswith("microsandbox."):
            del sys.modules[key]
    sys.modules.update(previous)
    importlib.invalidate_caches()


def child_environment(config):
    return {"MSB_PATH": config.msb_path, "MSB_LIBKRUNFW_PATH": config.libkrunfw_path,
            "MSB_HOME": config.home, "MSB_CONFIG_PATH": config.config_path,
            "PYTHONPATH": str(Path(runtime.__file__).resolve().parents[1]),
            "PYTHONDONTWRITEBYTECODE": "1", "PYTHONSAFEPATH": "1",
            "HOME": config.home, "LANG": "C.UTF-8"}


def refused(config):
    with pytest.raises(runtime.SDKRuntimeError, match="fresh process"):
        runtime.load_private_sdk(config)


def test_fake_load_is_idempotent_local_and_does_not_mutate_environment(private):
    before = dict(os.environ)
    loaded = runtime.load_private_sdk(private)
    assert loaded.sdk.calls == 1
    assert runtime.load_private_sdk(private) is loaded
    assert loaded.config == private
    assert dict(os.environ) == before
    assert Path(loaded.sdk.__file__).is_relative_to(private.payload_root)
    assert importlib.metadata.version("microsandbox") == "0.7.16"
    refused(replace(private, home=private.home + "-different"))
    assert runtime.load_private_sdk(private) is loaded


@pytest.mark.parametrize("name", ["microsandbox", "microsandbox._microsandbox", "microsandbox.orphan"])
@pytest.mark.parametrize("module", [None, ModuleType("ambient")])
def test_ambient_module_or_submodule_refused(private, name, module):
    sys.modules[name] = module
    refused(private)
    del sys.modules[name]
    refused(private)


def test_import_failure_poison_no_retry(private):
    path = Path(private.payload_root) / "microsandbox/__init__.py"
    path.write_text("raise RuntimeError('diagnostic-canary')")
    config = replace(private, manifest_sha256=manifest(Path(private.payload_root)))
    with pytest.raises(runtime.SDKRuntimeError) as error:
        runtime.load_private_sdk(config)
    assert "canary" not in str(error.value)
    path.write_text(FAKE_SDK)
    refused(replace(private, manifest_sha256=manifest(Path(private.payload_root))))


@pytest.mark.parametrize("field,value", [
    ("payload_root", "relative"), ("manifest_sha256", "0" * 64),
    ("manifest_sha256", "A" * 64), ("manifest_sha256", None),
    ("msb_path", "/missing"), ("libkrunfw_path", "/missing"),
    ("home", "/missing"), ("config_path", "/missing"),
])
def test_invalid_explicit_config(private, field, value):
    refused(replace(private, **{field: value}))
    assert "microsandbox" not in sys.modules


@pytest.mark.parametrize("key", ["MSB_PATH", "MSB_LIBKRUNFW_PATH", "MSB_HOME", "MSB_CONFIG_PATH"])
def test_environment_must_already_match(private, monkeypatch, key):
    monkeypatch.delenv(key)
    refused(private)
    assert "microsandbox" not in sys.modules


def test_unknown_msb_environment_refused(private, monkeypatch):
    monkeypatch.setenv("MSB_PROFILE", "ambient")
    refused(private)


def test_bytecode_writes_must_be_disabled(private, monkeypatch):
    monkeypatch.setattr(sys, "dont_write_bytecode", False)
    refused(private)


@pytest.mark.parametrize("content", ["", "[]", '{"home":"/ambient"}', '{"x":1,"x":2}', "NaN"])
def test_only_explicit_empty_json_config(private, content):
    Path(private.config_path).write_text(content)
    refused(private)


@pytest.mark.parametrize("kind", ["extra", "missing", "hash", "pth", "pycache", "symlink", "fifo"])
def test_closed_payload_refuses_changes_before_import(private, kind):
    root = Path(private.payload_root)
    path = root / "microsandbox/firmware"
    if kind == "extra":
        (root / "microsandbox/extra.py").write_text("raise AssertionError")
    elif kind == "missing":
        path.unlink()
    elif kind == "hash":
        path.write_bytes(b"tamper")
    elif kind == "pth":
        (root / "unsafe.pth").write_text("import unsafe")
    elif kind == "pycache":
        (root / "microsandbox/__pycache__").mkdir()
    elif kind == "symlink":
        path.unlink()
        path.symlink_to(root / "microsandbox/msb")
    else:
        path.unlink()
        os.mkfifo(path)
    refused(private)
    assert "microsandbox" not in sys.modules


@pytest.mark.parametrize("target", ["", "microsandbox", "microsandbox/__init__.py", runtime.MANIFEST])
def test_writable_payload_refused(private, target):
    path = Path(private.payload_root) / target
    path.chmod(path.stat().st_mode | 0o020)
    refused(private)


def test_root_symlink_refused(private):
    root = Path(private.payload_root)
    alias = root.parent / "alias"
    alias.symlink_to(root, target_is_directory=True)
    refused(replace(private, payload_root=str(alias)))


def test_hardlink_refused(private):
    root = Path(private.payload_root)
    os.link(root / "microsandbox/msb", root.parent / "binary-alias")
    refused(private)


@pytest.mark.parametrize("name", ["../escape", "/absolute", "microsandbox/../escape",
                                   "microsandbox/x.pth", "other/a", "microsandbox/a\\b"])
def test_even_trusted_manifest_cannot_expand_path_policy(private, name):
    root = Path(private.payload_root)
    records = {name: {"size": 0, "sha256": hashlib.sha256(b"").hexdigest()}}
    refused(replace(private, manifest_sha256=manifest(root, records=records)))


@pytest.mark.parametrize("budget", ["MAX_MANIFEST", "MAX_FILE", "MAX_TOTAL", "MAX_FILES"])
def test_budgets_refuse_before_sdk_import(private, monkeypatch, budget):
    monkeypatch.setattr(runtime, budget, 1)
    refused(private)
    assert "microsandbox" not in sys.modules


@pytest.mark.parametrize("contents", [
    "Metadata-Version: 2.1\nName: microsandbox\nVersion: 0.8.1\n",
    "Metadata-Version: 2.1\nName: unrelated\nVersion: 0.7.16\n",
    "Name: microsandbox\nName: microsandbox\nVersion: 0.7.16\n",
])
def test_metadata_is_private_exact_and_unique(private, contents):
    root = Path(private.payload_root)
    (root / runtime.DIST_INFO / "METADATA").write_text(contents)
    refused(replace(private, manifest_sha256=manifest(root)))


def test_ambient_metadata_not_selected(private, tmp_path, monkeypatch):
    ambient = tmp_path / "ambient"
    dist = ambient / "microsandbox-9.9.dist-info"
    dist.mkdir(parents=True)
    (dist / "METADATA").write_text("Name: microsandbox\nVersion: 9.9\n")
    monkeypatch.syspath_prepend(str(ambient))
    runtime.load_private_sdk(private)
    assert importlib.metadata.version("microsandbox") == "0.7.16"


@pytest.mark.parametrize("suffix", [
    '\n__file__ = "/ambient/__init__.py"\n',
    '\n__path__ = ["/ambient"]\n',
    '\ndef resolve_runtime():\n    return SimpleNamespace(msb_path="/wrong", libkrunfw_path="/wrong")\n',
    '\ndef default_backend_info():\n    return SimpleNamespace(kind="cloud", api_url=None, profile=None)\n',
])
def test_origin_or_effective_selection_mismatch_poison(private, suffix):
    root = Path(private.payload_root)
    (root / "microsandbox/__init__.py").write_text(FAKE_SDK + suffix)
    config = replace(private, manifest_sha256=manifest(root))
    refused(config)
    refused(config)


def test_probe_accepts_only_fixed_bounded_json(private, monkeypatch):
    for raw in (b"{}", b'{"operation":"exec","config":{}}',
                b" " * (runtime.MAX_PROBE + 1), b'{"operation":1,"operation":2}'):
        stdin = type("Input", (), {"buffer": io.BytesIO(raw)})()
        stdout = io.StringIO()
        monkeypatch.setattr(sys, "stdin", stdin)
        monkeypatch.setattr(sys, "stdout", stdout)
        assert runtime._probe() == 1
        assert json.loads(stdout.getvalue()) == {"ok": False, "error": "sdk-runtime-refused"}
        assert len(stdout.getvalue()) < 128


def run_probe(config, executable):
    request = json.dumps({"operation": "load", "config": asdict(config)}).encode()
    # Timeout here belongs to the parent test harness, not a generic RPC layer.
    result = subprocess.run([executable, "-B", "-s", "-P", "-m", "acq_py.sdk_runtime"],
                            input=request, capture_output=True, timeout=30,
                            env=child_environment(config), check=False)
    assert len(result.stdout) <= 1024 and len(result.stderr) <= 4096
    assert result.returncode == 0, "isolated load-only probe refused"
    assert json.loads(result.stdout) == {"ok": True, "version": "0.7.16", "backend": "local"}


def test_fake_probe_fresh_subprocess(private):
    run_probe(private, sys.executable)


@pytest.mark.skipif(not REAL_CONFIG, reason="explicit private SDK probe config not supplied")
def test_optional_actual_wheel_load_only():
    assert REAL_PYTHON, "supply explicit PRIVATE_SDK_PROBE_PYTHON"
    path = Path(REAL_CONFIG)
    assert path.is_absolute() and path.stat().st_size <= runtime.MAX_PROBE
    config = runtime.SDKRuntimeConfig(**json.loads(path.read_bytes()))
    run_probe(config, REAL_PYTHON)
