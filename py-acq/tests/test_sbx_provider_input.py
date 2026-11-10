"""Tier-2 tests for the provider-input projection on sbx, and the Windows ``current`` pointer file.

On sbx the provider-input generation is mounted read-only as an extra
workspace (``PATH:ro``), after the primary workspace, and
``ACQ_PROVIDER_INPUT_ROOT`` names it, as Bash ``acq_provider_input_sbx_mount``
does. It is staged before the create, published only after the create
succeeded, and discarded only once sbx confirms no sandbox can be mounting it.
"""

from __future__ import annotations

import json
import os
import stat
from pathlib import Path

import pytest

from acq_py import backends, cli, errors, kit_sbx, provider_input, sbx, state
from acq_py.commands import lifecycle

pytestmark = pytest.mark.provider_key
POSIX = os.name != "nt"
# The POSIX projection, run for real: on a Windows host every state path holds
# a drive's ':', which sbx_mount refuses (Windows takes the WINDOWS seam path).
posix_only = pytest.mark.skipif(not POSIX, reason="the POSIX projection needs a host path without a drive")


def _env(monkeypatch, tmp_path) -> Path:
    monkeypatch.setattr(lifecycle, "WINDOWS", False)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setenv(kit_sbx.BARRIER_TIMEOUT_ENV, "5")
    monkeypatch.setattr(kit_sbx, "BARRIER_POLL_S", 0.01)
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    return ws


def _spy(monkeypatch) -> list[list[str]]:
    seen: list[list[str]] = []
    real = sbx._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(sbx, "_run", spy)
    return seen


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    captured = capsys.readouterr()
    out = captured.out.strip()
    return rc, (json.loads(out.splitlines()[-1]) if out else None), captured.err


def _create(capsys, ws: Path, name: str = "pi", *extra: str):
    return _invoke(capsys, "--backend", "sbx", "create", "opencode", str(ws), "--name", name, *extra, "--json")


def _generations(name: str = "pi") -> list[Path]:
    root = provider_input.input_root("sbx", name) / "generations"
    return sorted(root.iterdir()) if root.is_dir() else []


@pytest.mark.skipif(not POSIX, reason="file modes and the current symlink are POSIX")
def test_create_mounts_the_generation_read_only_after_the_workspace(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch)
    rc, doc, err = _create(capsys, ws)
    assert rc == 0, err
    (create,) = [a for a in seen if a[0] == "create"]
    (generation,) = _generations()
    # sbx create AGENT WORKSPACE GENERATION:ro …: the primary workspace stays
    # first (sbx requires it writable), the generation follows it, read-only.
    assert create[1:4] == ["shell", doc["data"]["workspace"], f"{generation}:ro"]
    assert create[create.index("--env") + 1] == f"ACQ_PROVIDER_INPUT_ROOT={generation}"
    facts = generation / "models" / "providers" / "usai" / "facts.json"
    assert json.loads(facts.read_text(encoding="utf-8"))["host"] == "api.gsa.usai.gov"
    assert stat.S_IMODE(facts.stat().st_mode) == 0o444
    assert (generation / "models" / "providers" / "usai" / "snapshot.json").is_file()
    current = provider_input.input_root("sbx", "pi") / "current"
    assert os.readlink(current) == f"generations/{generation.name}"
    assert [f.provider for f in provider_input.recorded("sbx", "pi")] == ["usai"]


@posix_only
def test_no_provider_kits_mounts_an_empty_authoritative_generation(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch)
    rc, _doc, err = _create(capsys, ws, "pi", "--no-provider-kits")
    assert rc == 0, err
    (create,) = [a for a in seen if a[0] == "create"]
    (generation,) = _generations()
    assert f"{generation}:ro" in create
    assert list((generation / "models" / "providers").iterdir()) == []


@posix_only
def test_a_failed_create_discards_the_unpublished_generation(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "create")
    rc, doc, _err = _create(capsys, ws)
    assert rc == 1 and doc["error"]["code"] == errors.FAILURE
    assert _generations() == []
    assert not os.path.lexists(provider_input.input_root("sbx", "pi") / "current")


@posix_only
def test_a_generation_is_kept_when_sbx_cannot_confirm_the_sandbox_is_gone(monkeypatch, tmp_path, capsys):
    # The create failed, but a sandbox mounting the generation may exist: sbx
    # could not list its sandboxes, so the generation is not discarded.
    ws = _env(monkeypatch, tmp_path)
    attempted: list[bool] = []
    real_list = sbx.list_names

    def failed_create(*_args, **_kwargs):
        attempted.append(True)
        raise sbx.SbxError(errors.FAILURE, "sbx create failed for sandbox 'pi'", "retry")

    monkeypatch.setattr(sbx, "create", failed_create)
    monkeypatch.setattr(sbx, "list_names", lambda *a, **k: None if attempted else real_list(*a, **k))
    rc, doc, _err = _create(capsys, ws)
    assert rc == 1, doc
    assert "sbx create failed" in doc["error"]["message"]
    assert len(_generations()) == 1
    assert not os.path.lexists(provider_input.input_root("sbx", "pi") / "current")  # never published


@posix_only
def test_a_kit_that_cannot_be_prepared_discards_the_generation(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)

    def broken(_kit):
        raise kit_sbx.KitTranslateError("kit-translate: kit payload symlink points outside the kit: files/x")

    monkeypatch.setattr(kit_sbx, "translated_kit", broken)
    rc, _doc, _err = _create(capsys, ws)
    assert rc == 1
    assert _generations() == []


def test_on_windows_nothing_is_mounted_and_the_facts_are_still_recorded(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setattr(lifecycle, "WINDOWS", True)
    seen = _spy(monkeypatch)
    rc, _doc, err = _create(capsys, ws)
    assert rc == 0, err
    (create,) = [a for a in seen if a[0] == "create"]
    assert "--env" not in create and not [a for a in create if a.endswith(":ro")]
    assert _generations() == []
    assert [f.provider for f in provider_input.recorded("sbx", "pi")] == ["usai"]


@posix_only
def test_a_state_path_sbx_would_split_is_refused_before_create(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVENANCE_DIR", str(tmp_path / "prov:enance"))
    seen = _spy(monkeypatch)
    rc, doc, _err = _create(capsys, ws)
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "cannot mount the provider input" in doc["error"]["message"]
    assert not [a for a in seen if a[0] == "create"]
    assert _generations() == []
    assert state.record_read("sbx", "pi") is None


def test_the_env_flag_needs_sbx_0_39_which_the_floor_enforces():
    # `sbx create --env` first exists in sbx 0.39.0, and an older sbx fails the
    # whole create on the unknown flag (Bash MIN_SBX_VERSION, same reason). The
    # adapter floor is what keeps such an sbx from ever seeing the flag; do not
    # lower it below 0.39.0 without gating ACQ_PROVIDER_INPUT_ROOT on the version.
    assert backends.SBX_MIN_VERSION >= (0, 39, 0)


@pytest.mark.parametrize("version", ["0.38.9", "garbled"])
def test_an_sbx_below_the_floor_is_refused_before_anything_is_staged(monkeypatch, tmp_path, capsys, version):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_VERSION", version)
    seen = _spy(monkeypatch)
    rc, doc, _err = _create(capsys, ws)
    assert rc == 1
    if version == "garbled":
        assert doc["error"]["code"] == errors.BACKEND_VERSION_UNKNOWN  # unknown fails closed (Bash warns)
    else:
        assert doc["error"]["code"] == errors.BACKEND_VERSION_UNSUPPORTED
        assert "sbx >= 0.39.0, but found 0.38.9" in doc["error"]["message"]
    assert not [a for a in seen if a and a[0] == "create"]
    assert _generations() == []


@posix_only
def test_sbx_mount_refuses_what_it_cannot_express(tmp_path):
    good = tmp_path / "generations" / "generation.abc"
    assert provider_input.sbx_mount(good) == (f"{good}:ro", f"ACQ_PROVIDER_INPUT_ROOT={good}")
    for bad in (tmp_path / "a:b" / "generation.abc", tmp_path / "x\ny" / "generation.abc",
                tmp_path / "generations" / "current", Path("generations/generation.abc")):
        with pytest.raises(provider_input.ProviderInputError):
            provider_input.sbx_mount(bad)


# ---------------------------------------------------------------------------
# publish: the Windows pointer file (KNOWN_FAILURE_MODES section 61).
# ---------------------------------------------------------------------------


def _staged(monkeypatch, tmp_path) -> Path:
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    return provider_input.prepare("sbx", "pp", [])


def test_publish_on_windows_writes_the_pointer_file_bash_reads(monkeypatch, tmp_path):
    generation = _staged(monkeypatch, tmp_path)
    monkeypatch.setattr(provider_input, "WINDOWS", True)
    provider_input.publish("sbx", "pp", generation)
    current = provider_input.input_root("sbx", "pp") / "current"
    assert not current.is_symlink()
    assert current.read_bytes() == f"generations/{generation.name}\n".encode()
    later = provider_input.prepare("sbx", "pp", [])
    provider_input.publish("sbx", "pp", later)  # an atomic replace of the pointer
    assert current.read_bytes() == f"generations/{later.name}\n".encode()
    assert generation.is_dir()  # earlier generations are kept


@pytest.mark.skipif(not POSIX, reason="needs a symlink without Developer Mode")
def test_publish_on_windows_replaces_a_link_but_never_its_target(monkeypatch, tmp_path):
    generation = _staged(monkeypatch, tmp_path)
    provider_input.publish("sbx", "pp", generation)  # POSIX: a symlink
    current = provider_input.input_root("sbx", "pp") / "current"
    assert current.is_symlink()
    real_replace = os.replace

    def replace(src, dst):  # Windows cannot rename a file over a directory link
        if Path(dst) == current and current.is_symlink():
            raise PermissionError(13, "Access is denied")
        return real_replace(src, dst)

    monkeypatch.setattr(provider_input.os, "replace", replace)
    monkeypatch.setattr(provider_input, "WINDOWS", True)
    later = provider_input.prepare("sbx", "pp", [])
    provider_input.publish("sbx", "pp", later)
    assert current.read_bytes() == f"generations/{later.name}\n".encode()
    assert generation.is_dir() and (generation / "models" / "providers").is_dir()


def test_publish_refuses_a_real_directory_named_current(monkeypatch, tmp_path):
    generation = _staged(monkeypatch, tmp_path)
    monkeypatch.setattr(provider_input, "WINDOWS", True)
    current = provider_input.input_root("sbx", "pp") / "current"
    current.mkdir()
    (current / "keep").write_text("x", encoding="utf-8")
    with pytest.raises(OSError):
        provider_input.publish("sbx", "pp", generation)
    assert (current / "keep").read_text(encoding="utf-8") == "x"
    assert [p.name for p in current.parent.iterdir() if p.name.startswith(".current")] == []
