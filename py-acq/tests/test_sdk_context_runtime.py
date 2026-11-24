"""Private 0.8.2 explicit-context loader fixtures use FAKE two-package modules.

Run only in the workspace sandbox. The optional real-wheel probe loads both
packages and constructs LocalContext without opening the SQLite catalog or
starting a sandbox.
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

from acq_py import sdk_context_runtime as runtime

# Non-ACQ names deliberately survive the repository's environment scrub.
REAL_CONFIG = os.environ.get("PRIVATE_SDK082_PROBE_CONFIG", "")
REAL_PYTHON = os.environ.get("PRIVATE_SDK082_PROBE_PYTHON", "")
FAKE_CORE = '''"""FAKE microsandbox_core used only to test loader ordering and origin checks."""
import os
from types import SimpleNamespace
assert os.environ["MSB_PATH"] and os.environ["MSB_HOME"]
class ContextKind:
    LOCAL = "local"
    REMOTE = "remote"
class Context:
    pass
class LocalContext(Context):
    calls = 0
    last_kwargs = None
    def __init__(self, *, home=None, config_path=None):
        type(self).calls += 1
        type(self).last_kwargs = {"home": home, "config_path": config_path}
        self.kind = ContextKind.LOCAL
        self.sandboxes = SimpleNamespace(context=self)
def version():
    return "0.8.2"
def resolve_runtime():
    return SimpleNamespace(msb_path=os.environ["MSB_PATH"],
                           libkrunfw_path=os.environ["MSB_LIBKRUNFW_PATH"])
def set_default_backend(*_args, **_kwargs):
    raise AssertionError("set_default_backend must not be called")
'''
FAKE_SDK = '''"""FAKE microsandbox wrapper used only to test two-package loader checks."""
from microsandbox_core import (
    Context,
    ContextKind,
    LocalContext,
    resolve_runtime,
    set_default_backend,
    version,
)
__all__ = [
    "Context",
    "ContextKind",
    "LocalContext",
    "resolve_runtime",
    "set_default_backend",
    "version",
]
'''
SDK_METADATA = (
    "Metadata-Version: 2.1\n"
    "Name: microsandbox\n"
    "Version: 0.8.2\n"
    "Requires-Dist: microsandbox-core==0.8.2\n"
)
CORE_METADATA = (
    "Metadata-Version: 2.1\n"
    "Name: microsandbox-core\n"
    "Version: 0.8.2\n"
)


def manifest(root, *, records=None, version="0.8.2"):
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


def _clean_sdk_modules():
    for key in list(sys.modules):
        if (key in ("microsandbox", "microsandbox_core")
                or key.startswith(("microsandbox.", "microsandbox_core."))):
            del sys.modules[key]


@pytest.fixture
def private(tmp_path, monkeypatch):
    # Resolve the test base on macOS, where /var itself is a symlink.
    base = tmp_path.resolve()
    root = base / "payload"
    pkg_sdk = root / "microsandbox"
    pkg_core = root / "microsandbox_core"
    pkg_sdk.mkdir(parents=True)
    pkg_core.mkdir(parents=True)
    (pkg_sdk / "__init__.py").write_text(FAKE_SDK)
    (pkg_core / "__init__.py").write_text(FAKE_CORE)
    (pkg_core / "msb").write_bytes(b"fake-binary-not-executed")
    (pkg_core / "msb").chmod(0o700)
    (pkg_core / "firmware").write_bytes(b"fake-firmware-not-loaded")
    dist_sdk = root / runtime.DIST_INFO
    dist_core = root / runtime.CORE_DIST_INFO
    dist_sdk.mkdir()
    dist_core.mkdir()
    (dist_sdk / "METADATA").write_text(SDK_METADATA)
    (dist_core / "METADATA").write_text(CORE_METADATA)
    home = base / "home"
    home.mkdir()
    config_path = base / "config.json"
    config_path.write_text("{}")
    config = runtime.SDKContextRuntimeConfig(
        str(root), manifest(root), str(pkg_core / "msb"),
        str(pkg_core / "firmware"), str(home), str(config_path),
    )
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
    previous = {
        k: v for k, v in sys.modules.items()
        if k in ("microsandbox", "microsandbox_core")
        or k.startswith(("microsandbox.", "microsandbox_core."))
    }
    _clean_sdk_modules()
    yield config
    _clean_sdk_modules()
    sys.modules.update(previous)
    importlib.invalidate_caches()


def child_environment(config):
    return {"MSB_PATH": config.msb_path, "MSB_LIBKRUNFW_PATH": config.libkrunfw_path,
            "MSB_HOME": config.home, "MSB_CONFIG_PATH": config.config_path,
            "PYTHONPATH": str(Path(runtime.__file__).resolve().parents[1]),
            "PYTHONDONTWRITEBYTECODE": "1", "PYTHONSAFEPATH": "1",
            "HOME": config.home, "LANG": "C.UTF-8"}


def refused(config):
    with pytest.raises(runtime.SDKContextRuntimeError, match="fresh process"):
        runtime.load_private_sdk_context(config)


def test_fake_load_is_idempotent_local_context_and_does_not_mutate_environment_or_home(private):
    before = dict(os.environ)
    loaded = runtime.load_private_sdk_context(private)
    assert loaded.sdk.LocalContext.calls == 1
    assert loaded.sdk.LocalContext.last_kwargs == {
        "home": private.home,
        "config_path": private.config_path,
    }
    assert runtime.load_private_sdk_context(private) is loaded
    assert loaded.config == private
    assert loaded.context.kind == "local"
    assert loaded.context.sandboxes.context is loaded.context
    assert dict(os.environ) == before
    assert os.listdir(private.home) == []
    assert Path(loaded.sdk.__file__).is_relative_to(Path(private.payload_root) / "microsandbox")
    assert Path(loaded.core.__file__).is_relative_to(
        Path(private.payload_root) / "microsandbox_core"
    )
    assert importlib.metadata.version("microsandbox") == "0.8.2"
    assert importlib.metadata.version("microsandbox-core") == "0.8.2"
    refused(replace(private, home=private.home + "-different"))
    assert runtime.load_private_sdk_context(private) is loaded


@pytest.mark.parametrize("name", [
    "microsandbox",
    "microsandbox._microsandbox",
    "microsandbox.orphan",
    "microsandbox_core",
    "microsandbox_core._native",
    "microsandbox_core.orphan",
])
@pytest.mark.parametrize("module", [None, ModuleType("ambient")])
def test_ambient_module_or_submodule_refused(private, name, module):
    sys.modules[name] = module
    refused(private)
    del sys.modules[name]
    refused(private)


def test_import_failure_poison_no_retry(private):
    path = Path(private.payload_root) / "microsandbox_core/__init__.py"
    path.write_text("raise RuntimeError('diagnostic-canary')")
    config = replace(private, manifest_sha256=manifest(Path(private.payload_root)))
    with pytest.raises(runtime.SDKContextRuntimeError) as error:
        runtime.load_private_sdk_context(config)
    assert "canary" not in str(error.value)
    path.write_text(FAKE_CORE)
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
    assert "microsandbox_core" not in sys.modules


@pytest.mark.parametrize("key", ["MSB_PATH", "MSB_LIBKRUNFW_PATH", "MSB_HOME", "MSB_CONFIG_PATH"])
def test_environment_must_already_match(private, monkeypatch, key):
    monkeypatch.delenv(key)
    refused(private)
    assert "microsandbox" not in sys.modules
    assert "microsandbox_core" not in sys.modules


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


@pytest.mark.parametrize("kind", [
    "extra", "missing", "missing_core", "hash", "pth",
    "pycache", "pycache_core", "symlink", "fifo",
])
def test_closed_payload_refuses_changes_before_import(private, kind):
    root = Path(private.payload_root)
    path = root / "microsandbox_core/firmware"
    if kind == "extra":
        (root / "microsandbox/extra.py").write_text("raise AssertionError")
    elif kind == "missing":
        path.unlink()
    elif kind == "missing_core":
        (root / "microsandbox_core/__init__.py").unlink()
        refused(replace(private, manifest_sha256=manifest(root)))
        assert "microsandbox" not in sys.modules
        assert "microsandbox_core" not in sys.modules
        return
    elif kind == "hash":
        path.write_bytes(b"tamper")
    elif kind == "pth":
        (root / "unsafe.pth").write_text("import unsafe")
    elif kind == "pycache":
        (root / "microsandbox/__pycache__").mkdir()
    elif kind == "pycache_core":
        (root / "microsandbox_core/__pycache__").mkdir()
    elif kind == "symlink":
        path.unlink()
        path.symlink_to(root / "microsandbox_core/msb")
    else:
        path.unlink()
        os.mkfifo(path)
    refused(private)
    assert "microsandbox" not in sys.modules
    assert "microsandbox_core" not in sys.modules


@pytest.mark.parametrize("target", [
    "", "microsandbox", "microsandbox_core",
    "microsandbox/__init__.py", "microsandbox_core/__init__.py", runtime.MANIFEST,
])
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
    os.link(root / "microsandbox_core/msb", root.parent / "binary-alias")
    refused(private)


@pytest.mark.parametrize("name", [
    "../escape", "/absolute", "microsandbox/../escape",
    "microsandbox/x.pth", "microsandbox_core/x.pyc", "other/a", "microsandbox/a\\b",
])
def test_even_trusted_manifest_cannot_expand_path_policy(private, name):
    root = Path(private.payload_root)
    records = {name: {"size": 0, "sha256": hashlib.sha256(b"").hexdigest()}}
    refused(replace(private, manifest_sha256=manifest(root, records=records)))


@pytest.mark.parametrize("budget", ["MAX_MANIFEST", "MAX_FILE", "MAX_TOTAL", "MAX_FILES"])
def test_budgets_refuse_before_sdk_import(private, monkeypatch, budget):
    monkeypatch.setattr(runtime, budget, 1)
    refused(private)
    assert "microsandbox" not in sys.modules
    assert "microsandbox_core" not in sys.modules


@pytest.mark.parametrize("sdk_meta,core_meta", [
    (
        "Metadata-Version: 2.1\nName: microsandbox\nVersion: 0.8.2\n",
        CORE_METADATA,
    ),
    (
        "Metadata-Version: 2.1\nName: microsandbox\nVersion: 0.8.2\n"
        "Requires-Dist: microsandbox-core==0.8.1\n",
        CORE_METADATA,
    ),
    (
        SDK_METADATA + "Requires-Dist: extra==1.0\n",
        CORE_METADATA,
    ),
    (
        SDK_METADATA,
        CORE_METADATA + "Requires-Dist: unexpected==1.0\n",
    ),
    (
        "Metadata-Version: 2.1\nName: microsandbox\nVersion: 0.8.1\n"
        "Requires-Dist: microsandbox-core==0.8.2\n",
        CORE_METADATA,
    ),
    (
        SDK_METADATA,
        "Metadata-Version: 2.1\nName: microsandbox-core\nVersion: 0.8.1\n",
    ),
    (
        "Metadata-Version: 2.1\nName: unrelated\nVersion: 0.8.2\n",
        CORE_METADATA,
    ),
    (
        "Name: microsandbox\nName: microsandbox\nVersion: 0.8.2\n"
        "Requires-Dist: microsandbox-core==0.8.2\n",
        CORE_METADATA,
    ),
])
def test_metadata_and_dependency_closure_exact(private, sdk_meta, core_meta):
    root = Path(private.payload_root)
    (root / runtime.DIST_INFO / "METADATA").write_text(sdk_meta)
    (root / runtime.CORE_DIST_INFO / "METADATA").write_text(core_meta)
    refused(replace(private, manifest_sha256=manifest(root)))
    assert "microsandbox" not in sys.modules
    assert "microsandbox_core" not in sys.modules


def test_missing_core_dist_info_or_extra_dist_info_refused(private):
    root = Path(private.payload_root)
    extra = root / "extra-0.8.2.dist-info"
    extra.mkdir()
    (extra / "METADATA").write_text("Name: extra\nVersion: 0.8.2\n")
    refused(replace(private, manifest_sha256=manifest(root)))
    assert "microsandbox" not in sys.modules
    assert "microsandbox_core" not in sys.modules


def test_ambient_metadata_not_selected(private, tmp_path, monkeypatch):
    ambient = tmp_path / "ambient"
    for dist_dir, pkg_name in (
        ("microsandbox-9.9.dist-info", "microsandbox"),
        ("microsandbox_core-9.9.dist-info", "microsandbox-core"),
    ):
        dist = ambient / dist_dir
        dist.mkdir(parents=True)
        (dist / "METADATA").write_text(f"Name: {pkg_name}\nVersion: 9.9\n")
    monkeypatch.syspath_prepend(str(ambient))
    runtime.load_private_sdk_context(private)
    assert importlib.metadata.version("microsandbox") == "0.8.2"
    assert importlib.metadata.version("microsandbox-core") == "0.8.2"


@pytest.mark.parametrize("target_pkg,suffix", [
    ("microsandbox", '\n__file__ = "/ambient/__init__.py"\n'),
    ("microsandbox", '\n__path__ = ["/ambient"]\n'),
    ("microsandbox_core", '\n__file__ = "/ambient/__init__.py"\n'),
    ("microsandbox_core", '\n__path__ = ["/ambient"]\n'),
    (
        "microsandbox",
        '\nimport sys, types\nm = types.ModuleType("microsandbox.cross")\n'
        'm.__file__ = __file__.replace("/microsandbox/", "/microsandbox_core/")\n'
        'sys.modules["microsandbox.cross"] = m\n',
    ),
    ("microsandbox_core", '\ndef version():\n    return "0.8.1"\n'),
    (
        "microsandbox_core",
        '\nclass _PositionalOnly(Context):\n'
        '    def __init__(self, home=None, config_path=None, /):\n'
        '        self.kind = ContextKind.LOCAL\n'
        '        self.sandboxes = SimpleNamespace(context=self)\n'
        'LocalContext = _PositionalOnly\n',
    ),
    (
        "microsandbox_core",
        '\nclass LocalContext:\n'
        '    def __init__(self, *, home=None, config_path=None):\n'
        '        self.kind = "local"\n',
    ),
    (
        "microsandbox_core",
        '\nclass _Bad(Context):\n'
        '    def __init__(self, *, home=None, config_path=None):\n'
        '        self.kind = "remote"\n'
        '        self.sandboxes = SimpleNamespace(context=self)\n'
        'LocalContext = _Bad\n',
    ),
    (
        "microsandbox_core",
        '\nclass _BadSb(Context):\n'
        '    def __init__(self, *, home=None, config_path=None):\n'
        '        self.kind = ContextKind.LOCAL\n'
        '        self.sandboxes = SimpleNamespace(context=SimpleNamespace(kind="remote"))\n'
        'LocalContext = _BadSb\n',
    ),
    (
        "microsandbox_core",
        '\ndef resolve_runtime():\n'
        '    return SimpleNamespace(msb_path="/wrong", libkrunfw_path="/wrong")\n',
    ),
])
def test_origin_or_context_selection_mismatch_poison(private, target_pkg, suffix):
    root = Path(private.payload_root)
    base_code = FAKE_SDK if target_pkg == "microsandbox" else FAKE_CORE
    (root / target_pkg / "__init__.py").write_text(base_code + suffix)
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
        assert json.loads(stdout.getvalue()) == {
            "ok": False,
            "error": "sdk-context-runtime-refused",
        }
        assert len(stdout.getvalue()) < 128


def test_probe_refuses_if_catalog_created_in_home(private, monkeypatch):
    (Path(private.home) / "db").mkdir()
    raw = json.dumps({"operation": "load", "config": asdict(private)}).encode()
    stdin = type("Input", (), {"buffer": io.BytesIO(raw)})()
    stdout = io.StringIO()
    monkeypatch.setattr(sys, "stdin", stdin)
    monkeypatch.setattr(sys, "stdout", stdout)
    assert runtime._probe() == 1
    assert json.loads(stdout.getvalue()) == {
        "ok": False,
        "error": "sdk-context-runtime-refused",
    }


def run_probe(config, executable):
    request = json.dumps({"operation": "load", "config": asdict(config)}).encode()
    # Timeout here belongs to the parent test harness, not a generic RPC layer.
    result = subprocess.run([executable, "-B", "-s", "-P", "-m", "acq_py.sdk_context_runtime"],
                            input=request, capture_output=True, timeout=30,
                            env=child_environment(config), check=False)
    assert len(result.stdout) <= 1024 and len(result.stderr) <= 4096
    assert result.returncode == 0, "isolated 0.8.2 load-only context probe refused"
    assert json.loads(result.stdout) == {"ok": True, "version": "0.8.2", "context": "local"}


def test_fake_probe_fresh_subprocess(private):
    run_probe(private, sys.executable)
    assert os.listdir(private.home) == []


@pytest.mark.skipif(not REAL_CONFIG, reason="explicit private 0.8.2 SDK probe config not supplied")
def test_optional_actual_082_wheels_load_only():
    assert REAL_PYTHON, "supply explicit PRIVATE_SDK082_PROBE_PYTHON"
    path = Path(REAL_CONFIG)
    assert path.is_absolute() and path.stat().st_size <= runtime.MAX_PROBE
    config = runtime.SDKContextRuntimeConfig(**json.loads(path.read_bytes()))
    run_probe(config, REAL_PYTHON)
    assert os.listdir(config.home) == []
