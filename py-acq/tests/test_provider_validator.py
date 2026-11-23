"""Synthetic host executables exercise real bounded pipes, not provider code.

Asset integration tests require the sibling preparation-assets implementation;
the primary combines both lanes before running this suite in isolation.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from acq_py import provider_validator as validator

POSIX = pytest.mark.skipif(os.name != "posix", reason="POSIX bounded execution only")


def write_manifest(path):
    """Real referenced files for adapter tests, not upstream schema fixtures."""
    facts = path.with_name(f"{path.stem}-facts.json")
    catalog = path.with_name(f"{path.stem}-catalog.json")
    facts.write_text('{"synthetic": "facts"}')
    catalog.write_text('{"synthetic": "catalog"}')
    path.write_text(json.dumps({
        "schemaVersion": "acq-provider-input-bundle/v3",
        "factsPath": facts.name, "snapshotPath": catalog.name,
    }))
    return facts, catalog


@pytest.fixture
def manifests(tmp_path):
    paths = [tmp_path / "first.json", tmp_path / "second.json"]
    for path in paths:
        write_manifest(path)
    return paths


@pytest.fixture
def synthetic_assets(tmp_path, monkeypatch):
    from acq_py import preparation_assets

    assets = SimpleNamespace(
        validator_script=tmp_path / "host-assets/validator.py",
        schema_dir=tmp_path / "host-assets/schemas",
        credential_bindings=tmp_path / "host-assets/bindings.json",
    )
    assets.credential_bindings.parent.mkdir(parents=True)
    assets.credential_bindings.write_text('{"synthetic": "packaged-default"}')
    monkeypatch.setattr(preparation_assets, "verify_assets", lambda: assets)
    return assets


def executable(tmp_path, body):
    """A test-only interpreter stand-in with an absolute, no-PATH shebang."""
    path = tmp_path / "synthetic-python"
    path.write_text(f"#!{sys.executable}\n" + body)
    path.chmod(0o700)
    return path


@POSIX
def test_setwide_command_shape_real_synthetic_executable(tmp_path, manifests, synthetic_assets):
    log = tmp_path / "argv.jsonl"
    python = executable(tmp_path, f"""import json, sys
with open({str(log)!r}, 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
""")
    validator.validate_bundles(manifests, python_override=str(python))
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert calls == [
        ["-I", "-c", validator._PROBE],
        ["-I", str(synthetic_assets.validator_script),
         "--schema-dir", str(synthetic_assets.schema_dir),
         "--credential-bindings", str(synthetic_assets.credential_bindings),
         "--bundle", str(manifests[0]), "--bundle", str(manifests[1])],
    ]


def test_empty_selection_has_no_effect(monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail("empty selection must not resolve, discover, or execute")

    monkeypatch.setattr(validator, "resolve_python", forbidden)
    monkeypatch.setattr(validator, "_explicit_paths", forbidden)
    monkeypatch.setattr(validator, "_run_bounded", forbidden)
    assert validator.validate_empty_selection() is None


@POSIX
@pytest.mark.parametrize("selection", [None, [], (), "manifest.json", {}, [""], ["relative.json"]])
def test_ambiguous_selection_refused_before_execution(selection, monkeypatch):
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError):
        validator.validate_bundles(selection)


@POSIX
@pytest.mark.parametrize("kind", ["missing", "empty", "v2", "duplicate-key", "symlink", "directory", "fifo", "large"])
def test_invalid_manifest_refused_before_execution(tmp_path, kind, monkeypatch):
    path = tmp_path / "manifest.json"
    if kind == "empty":
        path.touch()
    elif kind == "v2":
        path.write_text('{"schemaVersion":"acq-provider-input-bundle/v2"}')
    elif kind == "duplicate-key":
        path.write_text('{"schemaVersion":"wrong","schemaVersion":"acq-provider-input-bundle/v3"}')
    elif kind == "symlink":
        target = tmp_path / "target.json"
        target.write_text('{"schemaVersion":"acq-provider-input-bundle/v3"}')
        path.symlink_to(target)
    elif kind == "directory":
        path.mkdir()
    elif kind == "fifo":
        os.mkfifo(path)
    elif kind == "large":
        path.write_bytes(b" " * (validator._MANIFEST_LIMIT + 1))
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError):
        validator.validate_bundles([path])


@POSIX
@pytest.mark.parametrize("alias", ["same", "dotdot", "hardlink"])
def test_duplicate_manifest_identity(manifests, alias, tmp_path):
    other = manifests[0]
    if alias == "dotdot":
        (tmp_path / "sub").mkdir()
        other = tmp_path / "sub/../first.json"
    elif alias == "hardlink":
        other = tmp_path / "alias.json"
        os.link(manifests[0], other)
    with pytest.raises(validator.ValidatorError, match="duplicate"):
        validator.validate_bundles([manifests[0], other])


@POSIX
@pytest.mark.parametrize("value", ["python3", "./python", "", "/missing/python -I"])
def test_bad_override_never_uses_path(tmp_path, monkeypatch, value):
    python = executable(tmp_path, "raise SystemExit(0)\n")
    monkeypatch.setenv("PATH", str(python.parent))
    with pytest.raises(validator.ValidatorError):
        validator.resolve_python(value)


@POSIX
def test_override_preserves_venv_symlink_and_spaces(tmp_path, monkeypatch):
    path = tmp_path / "private venv/bin/python3"
    path.parent.mkdir(parents=True)
    path.symlink_to(sys.executable)
    monkeypatch.setenv("ACQ_PROVIDER_INPUT_PYTHON", str(path))
    assert validator.resolve_python() == path
    assert validator.resolve_python(str(path)) == path


@POSIX
@pytest.mark.parametrize("inspection", ["is_file", "access"])
def test_interpreter_inspection_errors_are_sanitized(tmp_path, monkeypatch, inspection):
    path = tmp_path / "private-interpreter-path"

    def inaccessible(*args, **kwargs):
        raise PermissionError(f"private diagnostic: {path}")

    if inspection == "is_file":
        monkeypatch.setattr(Path, "is_file", inaccessible)
    else:
        monkeypatch.setattr(Path, "is_file", lambda self: True)
        monkeypatch.setattr(validator.os, "access", inaccessible)
    with pytest.raises(validator.ValidatorError) as error:
        validator.resolve_python(str(path))
    assert str(error.value) == "preinstalled provider validator Python is unavailable"
    assert error.value.__suppress_context__


@POSIX
@pytest.mark.skipif(not hasattr(os, "geteuid") or os.geteuid() == 0,
                    reason="requires enforced POSIX directory permissions")
def test_inaccessible_interpreter_directory_is_fixed_refusal(tmp_path):
    directory = tmp_path / "private-directory"
    directory.mkdir()
    directory.chmod(0)
    try:
        with pytest.raises(validator.ValidatorError) as error:
            validator.resolve_python(str(directory / "python"))
        assert str(error.value) == "preinstalled provider validator Python is unavailable"
    finally:
        directory.chmod(0o700)


@POSIX
@pytest.mark.parametrize("mode", ["xdg", "relative-xdg", "data-override"])
def test_preinstalled_default_locations(tmp_path, monkeypatch, mode):
    monkeypatch.delenv("ACQ_PROVIDER_INPUT_PYTHON", raising=False)
    monkeypatch.delenv("ACQ_PROVIDER_INPUT_DATA_DIR", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    if mode == "xdg":
        monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
        root = tmp_path / "data/acq/provider-input-validator"
    elif mode == "relative-xdg":
        monkeypatch.setenv("XDG_DATA_HOME", "relative-untrusted")
        root = tmp_path / ".local/share/acq/provider-input-validator"
    else:
        root = tmp_path / "custom"
        monkeypatch.setenv("ACQ_PROVIDER_INPUT_DATA_DIR", str(root))
    python = root / "provider-input-validator.current/bin/python3"
    python.parent.mkdir(parents=True)
    python.symlink_to(sys.executable)
    assert validator.resolve_python() == python


@POSIX
def test_bad_data_directory_and_unavailable_runtime(tmp_path, monkeypatch):
    monkeypatch.delenv("ACQ_PROVIDER_INPUT_PYTHON", raising=False)
    monkeypatch.setenv("ACQ_PROVIDER_INPUT_DATA_DIR", "relative")
    with pytest.raises(validator.ValidatorError, match="absolute"):
        validator.resolve_python()
    monkeypatch.setenv("ACQ_PROVIDER_INPUT_DATA_DIR", str(tmp_path / "missing"))
    with pytest.raises(validator.ValidatorError, match="unavailable"):
        validator.resolve_python()


@POSIX
@pytest.mark.parametrize("yaml_version,schema_version,expected", [
    ("6.0.3", "4.26.0", 0), ("6.0.2", "4.26.0", 2), ("6.0.3", "4.25.1", 2),
])
def test_actual_isolated_metadata_probe(tmp_path, yaml_version, schema_version, expected):
    # Synthetic dist-info only: no dependency installation or package execution.
    for name, version in [("PyYAML", yaml_version), ("jsonschema", schema_version)]:
        dist = tmp_path / f"{name}-{version}.dist-info"
        dist.mkdir()
        (dist / "METADATA").write_text(f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n")
    code = f"import sys; sys.path.insert(0, {str(tmp_path)!r})\n" + validator._PROBE
    status, _ = validator._run_bounded([sys.executable, "-I", "-S", "-c", code], time.monotonic() + 5)
    assert status == expected


@POSIX
def test_missing_metadata_probe():
    status, _ = validator._run_bounded(
        [sys.executable, "-I", "-S", "-c", validator._PROBE], time.monotonic() + 5,
    )
    assert status == 2


@POSIX
@pytest.mark.parametrize("phase", ["probe", "validation"])
def test_nonzero_diagnostics_sanitized(tmp_path, manifests, synthetic_assets, phase):
    python = executable(tmp_path, f"""import sys
if ('-c' in sys.argv) == {phase == 'probe'!r}:
    print('UNTRUSTED-CANDIDATE-OUTPUT', file=sys.stderr)
    raise SystemExit(2)
""")
    with pytest.raises(validator.ValidatorError) as caught:
        validator.validate_bundles(manifests, python_override=str(python))
    assert "UNTRUSTED" not in str(caught.value)
    assert str(tmp_path) not in str(caught.value)
    assert ("requires PyYAML" if phase == "probe" else "contract validation") in str(caught.value)


@POSIX
@pytest.mark.parametrize("phase", ["probe", "validation"])
@pytest.mark.parametrize("mode", ["sleep", "stdout", "stderr", "both", "closed-pipes"])
def test_actual_timeout_and_output_bounds(tmp_path, manifests, synthetic_assets, phase, mode):
    actions = {
        "sleep": "time.sleep(60)",
        "stdout": "os.write(1, b'x' * 70000)",
        "stderr": "os.write(2, b'x' * 70000)",
        "both": "os.write(1, b'x' * 40000); os.write(2, b'x' * 40000)",
        "closed-pipes": "os.close(1); os.close(2); time.sleep(60)",
    }
    python = executable(tmp_path, f"""import os, sys, time
if ('-c' in sys.argv) == {phase == 'probe'!r}:
    {actions[mode]}
""")
    start = time.monotonic()
    expected = "deadline" if mode in ("sleep", "closed-pipes") else "output limit"
    with pytest.raises(validator.ValidatorError, match=expected):
        validator.validate_bundles(manifests, python_override=str(python), timeout=1.5)
    assert time.monotonic() - start < 5


@POSIX
def test_child_holding_pipes_does_not_extend_deadline(tmp_path):
    code = "import os,time\nif os.fork() == 0: time.sleep(60)\nelse: os._exit(0)"
    start = time.monotonic()
    with pytest.raises(validator.ValidatorError, match="deadline"):
        validator._run_bounded([sys.executable, "-I", "-c", code], start + 0.5)
    assert time.monotonic() - start < 3


@POSIX
def test_real_capture_positive_boundary(monkeypatch):
    monkeypatch.setattr(validator, "_OUTPUT_LIMIT", 10)
    status, output = validator._run_bounded(
        [sys.executable, "-I", "-c", "import os; os.write(1,b'12345'); os.write(2,b'67890')"],
        time.monotonic() + 5,
    )
    assert (status, output) == (0, b"12345")


@POSIX
@pytest.mark.parametrize("timeout", [0, -1, float("nan"), float("inf"), 301, True, None, "30"])
def test_invalid_deadline_refused(manifests, timeout):
    with pytest.raises(validator.ValidatorError, match="timeout"):
        validator.validate_bundles(manifests, timeout=timeout)


def test_windows_refused_before_effect(monkeypatch):
    monkeypatch.setattr(validator.sys, "platform", "win32")
    monkeypatch.setattr(validator.subprocess, "Popen", lambda *a, **k: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError, match="POSIX"):
        validator.validate_bundles([])
    with pytest.raises(validator.ValidatorError, match="POSIX"):
        validator.resolve_python("C:\\Python\\python.exe")


@POSIX
def test_asset_verification_failure_prevents_probe(manifests, monkeypatch):
    from acq_py import preparation_assets

    def reject():
        raise preparation_assets.AssetError("synthetic tampered asset refusal")

    monkeypatch.setattr(preparation_assets, "verify_assets", reject)
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(preparation_assets.AssetError):
        validator.validate_bundles(manifests)


@POSIX
def test_actual_packaged_asset_tamper_prevents_probe(tmp_path, manifests, monkeypatch):
    from acq_py import preparation_assets

    # Copy only host-owned package assets, never change the installed package.
    verified = preparation_assets.verify_assets()
    original = preparation_assets._BUNDLE_ROOT
    copied = tmp_path / "tampered-assets"
    shutil.copytree(original, copied)
    script = copied / verified.validator_script.relative_to(original)
    script.write_bytes(script.read_bytes() + b"\n# synthetic tamper\n")
    monkeypatch.setattr(preparation_assets, "_BUNDLE_ROOT", copied)
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(preparation_assets.AssetError):
        validator.validate_bundles(manifests)


@POSIX
def test_minimal_environment_real_synthetic_executable(tmp_path, monkeypatch):
    for name in ("SYNTHETIC_SECRET_CANARY", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES",
                 "HTTP_PROXY", "HTTPS_PROXY", "PYTHONPATH", "PYTHONHOME", "BASH_ENV"):
        monkeypatch.setenv(name, "synthetic-must-not-reach-child")
    python = executable(tmp_path, "import json, os; print(json.dumps(dict(os.environ)))\n")
    status, output = validator._run_bounded([str(python)], time.monotonic() + 5)
    assert status == 0
    assert json.loads(output) == {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
    assert b"synthetic-must-not-reach-child" not in output


@POSIX
def test_host_owned_bindings_override(tmp_path, manifests, synthetic_assets):
    bindings = tmp_path / "merged-bindings.json"
    bindings.write_text('{"synthetic": "host-merged"}')
    log = tmp_path / "argv.jsonl"
    python = executable(tmp_path, f"""import json, sys
with open({str(log)!r}, 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
""")
    validator.validate_bundles(
        manifests, python_override=str(python), credential_bindings=bindings,
    )
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert len(calls) == 2
    assert calls[1][calls[1].index("--credential-bindings") + 1] == str(bindings)
    assert str(synthetic_assets.credential_bindings) not in calls[1]


@POSIX
@pytest.mark.parametrize("kind", ["relative", "empty-path", "missing", "empty-file", "large",
                                  "symlink", "directory", "fifo"])
def test_invalid_bindings_before_probe(tmp_path, manifests, synthetic_assets, monkeypatch, kind):
    path = tmp_path / "merged.json"
    if kind == "relative":
        path = "relative.json"
    elif kind == "empty-path":
        path = ""
    elif kind == "empty-file":
        path.touch()
    elif kind == "large":
        path.write_bytes(b" " * (validator._BINDINGS_LIMIT + 1))
    elif kind == "symlink":
        path.symlink_to(synthetic_assets.credential_bindings)
    elif kind == "directory":
        path.mkdir()
    elif kind == "fifo":
        os.mkfifo(path)
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError, match="credential bindings"):
        validator.validate_bundles(manifests, credential_bindings=path)


@POSIX
def test_provider_count_limit_before_file_inspection(manifests, monkeypatch):
    monkeypatch.setattr(validator, "_manifest_identity", lambda *args: pytest.fail("read manifest"))
    with pytest.raises(validator.ValidatorError, match="limit of eight"):
        validator.validate_bundles([manifests[0]] * 9)


@POSIX
def test_eight_explicit_manifests_accepted(tmp_path, synthetic_assets):
    paths = [tmp_path / f"manifest-{i}.json" for i in range(8)]
    for path in paths:
        write_manifest(path)
    python = executable(tmp_path, "raise SystemExit(0)\n")
    validator.validate_bundles(paths, python_override=str(python))


@POSIX
def test_input_inspection_consumes_shared_deadline(manifests, monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(validator.time, "monotonic", lambda: clock[0])
    inspect = validator._manifest_identity

    def slow_inspection(path, budget, deadline):
        result = inspect(path, budget, deadline)
        clock[0] += 2
        return result

    monkeypatch.setattr(validator, "_manifest_identity", slow_inspection)
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError, match="deadline"):
        validator.validate_bundles(manifests, timeout=1)


def input_files(manifest, bindings):
    value = json.loads(manifest.read_text())
    return {
        "manifest": (manifest, validator._MANIFEST_LIMIT),
        "facts": (manifest.parent / value["factsPath"], validator._FACTS_LIMIT),
        "catalog": (manifest.parent / value["snapshotPath"], validator._CATALOG_LIMIT),
        "spec": (manifest.parent / "spec.yaml", validator._SPEC_LIMIT),
        "bindings": (bindings, validator._BINDINGS_LIMIT),
    }


@POSIX
@pytest.mark.parametrize("role", ["manifest", "facts", "catalog", "spec", "bindings"])
def test_input_file_exact_limit_and_one_byte_over(
    tmp_path, manifests, synthetic_assets, monkeypatch, role,
):
    path, limit = input_files(manifests[0], synthetic_assets.credential_bindings)[role]
    initial = path.read_bytes() if path.exists() else b"caps: {}\n"
    path.write_bytes(initial + b" " * (limit - len(initial)))
    python = executable(tmp_path, "raise SystemExit(0)\n")
    validator.validate_bundles([manifests[0]], python_override=str(python))
    with path.open("ab") as stream:
        stream.write(b" ")
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError, match="bounded regular file"):
        validator.validate_bundles([manifests[0]], python_override=str(python))


@POSIX
@pytest.mark.parametrize("role", ["manifest", "facts", "catalog", "spec", "bindings"])
def test_sparse_huge_input_refused_before_probe(manifests, synthetic_assets, monkeypatch, role):
    path, _ = input_files(manifests[0], synthetic_assets.credential_bindings)[role]
    # Logical size, not allocated blocks, must be checked before read allocation.
    with path.open("wb") as stream:
        stream.truncate(16 * 1024 * 1024 * 1024)
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError, match="bounded regular file"):
        validator.validate_bundles([manifests[0]])


@POSIX
@pytest.mark.parametrize("field", ["factsPath", "snapshotPath"])
@pytest.mark.parametrize("relative", [
    None, 1, [], "", ".", "..", "../outside.json", "sub/../facts.json",
    "/absolute.json", "//absolute.json", "./facts.json", "sub/./facts.json",
    "sub//facts.json", "facts.json/", "sub\\facts.json", "facts\x00.json",
    "facts\n.json", "facts\t.json", "facts\x7f.json", "facts\x85.json", "a" * 257,
])
def test_unsafe_artifact_paths_refused(manifests, monkeypatch, field, relative):
    value = json.loads(manifests[0].read_text())
    value[field] = relative
    manifests[0].write_text(json.dumps(value))
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError, match="strict relative path"):
        validator.validate_bundles([manifests[0]])


@POSIX
@pytest.mark.parametrize("field", ["factsPath", "snapshotPath"])
@pytest.mark.parametrize("kind", ["missing", "directory", "fifo", "symlink", "dangling", "parent-link"])
def test_unsafe_referenced_files_refused(tmp_path, manifests, monkeypatch, field, kind):
    path = tmp_path / "unsafe.json"
    if kind == "directory":
        path.mkdir()
    elif kind == "fifo":
        os.mkfifo(path)
    elif kind == "symlink":
        path.symlink_to(manifests[1])
    elif kind == "dangling":
        path.symlink_to(tmp_path / "absent")
    elif kind == "parent-link":
        path.symlink_to(tmp_path, target_is_directory=True)
    value = json.loads(manifests[0].read_text())
    value[field] = path.name + ("/second.json" if kind == "parent-link" else "")
    manifests[0].write_text(json.dumps(value))
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError):
        validator.validate_bundles([manifests[0]])


@POSIX
@pytest.mark.parametrize("kind", ["directory", "fifo", "symlink", "dangling"])
def test_existing_unsafe_optional_spec_is_not_absent(tmp_path, manifests, monkeypatch, kind):
    spec = tmp_path / "spec.yaml"
    if kind == "directory":
        spec.mkdir()
    elif kind == "fifo":
        os.mkfifo(spec)
    else:
        spec.symlink_to(manifests[0] if kind == "symlink" else tmp_path / "absent")
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError):
        validator.validate_bundles(manifests)


@POSIX
@pytest.mark.parametrize("spec_present", [False, True])
def test_aggregate_exact_limit_and_one_byte_over(
    tmp_path, manifests, synthetic_assets, monkeypatch, spec_present,
):
    # Share facts/catalog across manifests: the budget must count each consumption,
    # just as it counts the adjacent shared spec once for each manifest.
    manifests[1].write_bytes(manifests[0].read_bytes())
    if spec_present:
        (tmp_path / "spec.yaml").write_text("caps: {}\n")
    total = synthetic_assets.credential_bindings.stat().st_size
    for manifest in manifests:
        for role, (path, _) in input_files(manifest, synthetic_assets.credential_bindings).items():
            if role != "bindings" and (role != "spec" or spec_present):
                total += path.stat().st_size
    monkeypatch.setattr(validator, "_INPUT_LIMIT", total)
    python = executable(tmp_path, "raise SystemExit(0)\n")
    validator.validate_bundles(manifests, python_override=str(python))
    monkeypatch.setattr(validator, "_INPUT_LIMIT", total - 1)
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError, match="aggregate input byte limit"):
        validator.validate_bundles(manifests, python_override=str(python))


@POSIX
def test_aggregate_rejects_individually_legal_catalogs(tmp_path, synthetic_assets, monkeypatch):
    paths = [tmp_path / f"manifest-{i}.json" for i in range(4)]
    for path in paths:
        _, catalog = write_manifest(path)
        with catalog.open("wb") as stream:
            stream.truncate(validator._CATALOG_LIMIT)
    monkeypatch.setattr(validator, "_run_bounded", lambda *args: pytest.fail("executed"))
    with pytest.raises(validator.ValidatorError, match="aggregate input byte limit"):
        validator.validate_bundles(paths)


@POSIX
def test_nested_regular_artifacts_accepted(tmp_path, manifests, synthetic_assets):
    directory = tmp_path / "nested/data"
    directory.mkdir(parents=True)
    value = json.loads(manifests[0].read_text())
    for field in ("factsPath", "snapshotPath"):
        target = directory / value[field]
        (tmp_path / value[field]).rename(target)
        value[field] = target.relative_to(tmp_path).as_posix()
    manifests[0].write_text(json.dumps(value))
    python = executable(tmp_path, "raise SystemExit(0)\n")
    validator.validate_bundles([manifests[0]], python_override=str(python))


@POSIX
@pytest.mark.parametrize("file_limit,budget_limit", [(32, 64), (64, 32)])
def test_bounded_read_rejects_growth_after_stat(tmp_path, monkeypatch, file_limit, budget_limit):
    path = tmp_path / "growing-input"
    path.write_bytes(b"x" * 33)
    original_stat = validator.os.fstat
    original_fdopen = validator.os.fdopen
    reads = []

    def old_size(fd):
        info = original_stat(fd)
        return SimpleNamespace(st_mode=info.st_mode, st_size=32)

    class ObservedStream:
        def __init__(self, fd, mode):
            self.stream = original_fdopen(fd, mode)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.stream.close()

        def fileno(self):
            return self.stream.fileno()

        def read(self, size):
            reads.append(size)
            assert size == 33  # Smaller of the per-file and remaining budget, plus one.
            return self.stream.read(size)

    monkeypatch.setattr(validator.os, "fstat", old_size)
    monkeypatch.setattr(validator.os, "fdopen", ObservedStream)
    monkeypatch.setattr(validator, "_INPUT_LIMIT", budget_limit)
    with pytest.raises(validator.ValidatorError, match="bounded immutable regular file"):
        validator._read_input(
            path, file_limit, validator._InputBudget(), time.monotonic() + 5, "provider artifact",
        )
    assert reads == [33]
