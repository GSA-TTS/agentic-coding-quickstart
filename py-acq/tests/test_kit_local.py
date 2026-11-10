"""Tier-2 tests for local kit directories (``kit_fetch.copy_local``) and their use by both backends.

A local kit is copied into acq's private kit cache, without following links on
the way, and every check runs on the copy: links must stay inside the kit, the
tree must hold only files, directories and links, and the kit must be a neutral
``hybrid/v1`` kit with a plain name. The backends then read only the copy.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

from acq_py import cli, errors, kit_fetch, kit_sbx, msb, sbx, security, state

posix_only = pytest.mark.skipif(sys.platform == "win32", reason="POSIX links, modes and FIFOs")

TEAM_SPEC = """schemaVersion: "hybrid/v1"
kind: mixin
name: team-kit
displayName: Team Kit
description: A kit from a local directory
caps:
  network:
    allow:
      - team.example.test
files:
  - path: /home/agent/team.txt
    mode: "0644"
    source: files/team.txt
"""


def _kit(root: Path, spec: str = TEAM_SPEC) -> Path:
    kit = root / "team"
    (kit / "files").mkdir(parents=True)
    (kit / "spec.yaml").write_bytes(spec.encode("utf-8"))  # LF on every host
    (kit / "files" / "team.txt").write_text("first\n", encoding="utf-8")
    return kit


def _cache() -> Path:
    return Path(os.environ["XDG_CACHE_HOME"]) / "acq" / "kits" / kit_fetch.PY_DIR


def _refused(ref, code=errors.VALIDATION_FAILED, backend="msb") -> str:
    with pytest.raises(kit_fetch.KitFetchError) as info:
        kit_fetch.load(str(ref), backend)
    assert info.value.code == code, info.value.message
    return info.value.message


# ---------------------------------------------------------------------------
# The copy.
# ---------------------------------------------------------------------------


def test_a_local_kit_is_read_from_a_private_copy(tmp_path):
    kit = _kit(tmp_path)
    name, spec = kit_fetch.load(str(kit), "msb")
    assert name == "team-kit"
    copy = Path(spec.kit_dir)
    assert _cache() in copy.parents and kit not in copy.parents
    assert (copy / "files" / "team.txt").read_text(encoding="utf-8") == "first\n"
    # Changing the source afterwards does not change what was checked and applied.
    (kit / "files" / "team.txt").write_text("changed\n", encoding="utf-8")
    assert (copy / "files" / "team.txt").read_text(encoding="utf-8") == "first\n"
    again = Path(kit_fetch.load(str(kit), "msb")[1].kit_dir)
    assert again != copy and (again / "files" / "team.txt").read_text(encoding="utf-8") == "changed\n"
    # The same content is the same copy.
    assert Path(kit_fetch.load(str(kit), "msb")[1].kit_dir) == again


@posix_only
def test_modes_and_links_inside_the_kit_are_kept(tmp_path):
    kit = _kit(tmp_path)
    tool = kit / "files" / "tool"
    tool.write_text("#!/bin/sh\n", encoding="utf-8")
    tool.chmod(0o755)
    (kit / "files" / "link").symlink_to("tool")
    copy = Path(kit_fetch.load(str(kit), "msb")[1].kit_dir)
    assert os.access(copy / "files" / "tool", os.X_OK)
    assert not os.access(copy / "files" / "team.txt", os.X_OK)
    assert os.readlink(copy / "files" / "link") == "tool"


@posix_only
@pytest.mark.parametrize("target", ["../../../secret", "absolute"])
def test_a_link_that_leaves_the_copy_is_refused_and_nothing_is_kept(tmp_path, target):
    secret = tmp_path / "secret"
    secret.write_text("not for the guest\n", encoding="utf-8")
    kit = _kit(tmp_path)
    # An absolute link even to a file inside the source kit leaves the copy.
    link_target = str(kit / "files" / "team.txt") if target == "absolute" else target
    (kit / "files" / "out").symlink_to(link_target)
    message = _refused(kit)
    assert "points outside the kit" in message
    trees = _cache() / "tree"
    assert [p for p in trees.iterdir()] == []  # the refused copy was removed


@posix_only
def test_a_linked_directory_is_copied_as_a_link_never_followed(tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "id_key").write_text("private\n", encoding="utf-8")
    kit = _kit(tmp_path)
    (kit / "files" / "dir").symlink_to(outside, target_is_directory=True)
    assert "points outside the kit" in _refused(kit)
    assert not any(p.name == "id_key" for p in _cache().rglob("*"))


@posix_only
def test_a_fifo_in_the_kit_is_refused(tmp_path):
    kit = _kit(tmp_path)
    os.mkfifo(kit / "files" / "pipe")
    assert "is not a regular file" in _refused(kit)


@pytest.mark.parametrize("by_fd", [True, False], ids=["fd-walk", "path-walk"])
@pytest.mark.parametrize("inside", [False, True], ids=["from-outside", "twin-in-kit"])
def test_a_hard_linked_file_is_refused_with_the_plain_copy_remedy(tmp_path, monkeypatch, by_fd, inside):
    # On NTFS too: os.link makes a hard link there, and fstat reports it.
    if by_fd and not kit_fetch._WALK_BY_FD:
        pytest.skip("this host has no fd walk")
    monkeypatch.setattr(kit_fetch, "_WALK_BY_FD", by_fd)
    kit = _kit(tmp_path)
    (kit / "files" / "sub").mkdir()
    source = kit / "files" / "team.txt" if inside else tmp_path / "elsewhere.txt"
    if not inside:
        source.write_text("host file\n", encoding="utf-8")
    os.link(source, kit / "files" / "sub" / "linked.txt")
    with pytest.raises(kit_fetch.KitFetchError) as info:
        kit_fetch.load(str(kit), "msb")
    assert info.value.code == errors.VALIDATION_FAILED
    assert "has more than one hard link" in info.value.message
    # Entries are walked in name order, so files/sub/ comes before files/team.txt.
    assert "files/sub/linked.txt has more than one hard link" in info.value.message
    assert "cp -R" in info.value.remediation
    assert "elsewhere" not in info.value.message
    cache = _cache()
    assert not cache.exists() or not list(cache.glob("*/kit"))  # nothing was kept


def test_a_plain_copy_of_a_hard_linked_kit_passes(tmp_path):
    import shutil

    kit = _kit(tmp_path)
    (tmp_path / "elsewhere.txt").write_text("x\n", encoding="utf-8")
    os.link(tmp_path / "elsewhere.txt", kit / "files" / "linked.txt")
    copy = tmp_path / "copy"
    shutil.copytree(kit, copy)  # what 'cp -R' gives: one link per file
    assert kit_fetch.load(str(copy), "msb")[0] == "team-kit"


def test_the_windows_walk_refuses_links_and_copies_files(tmp_path, monkeypatch):
    # The path-based walk Windows uses (no O_NOFOLLOW opens there), run on any host.
    monkeypatch.setattr(kit_fetch, "_WALK_BY_FD", False)
    kit = _kit(tmp_path)
    copy = Path(kit_fetch.load(str(kit), "msb")[1].kit_dir)
    assert (copy / "files" / "team.txt").read_text(encoding="utf-8") == "first\n"
    if sys.platform != "win32":
        (kit / "files" / "link").symlink_to("team.txt")
        assert "link or junction" in _refused(kit)


def test_an_oversized_tree_is_refused(tmp_path, monkeypatch):
    monkeypatch.setattr(kit_fetch, "_LOCAL_MAX_ENTRIES", 2)
    assert "more than 2 entries" in _refused(_kit(tmp_path))
    monkeypatch.setattr(kit_fetch, "_LOCAL_MAX_ENTRIES", 100)
    monkeypatch.setattr(kit_fetch, "_LOCAL_MAX_BYTES", 4)
    assert "MiB" in _refused(_kit(tmp_path / "big"))


@pytest.mark.parametrize("by_fd", [True, False], ids=["fd-walk", "path-walk"])
def test_a_tree_nested_too_deep_is_refused_not_a_recursion_error(tmp_path, monkeypatch, by_fd):
    if by_fd and not kit_fetch._WALK_BY_FD:
        pytest.skip("no fd-relative walk on this host")
    monkeypatch.setattr(kit_fetch, "_WALK_BY_FD", by_fd)
    if sys.platform == "win32":
        # 64 levels under the kit cache would pass MAX_PATH (260) first, which
        # fails the copy as a plain error before the cap is reached.
        monkeypatch.setattr(kit_fetch, "_LOCAL_MAX_DEPTH", 8)
    kit = _kit(tmp_path)
    deep = kit / "files"
    for _ in range(kit_fetch._LOCAL_MAX_DEPTH):  # files/ itself is the first level
        deep = deep / "d"
    deep.mkdir(parents=True)
    assert f"more than {kit_fetch._LOCAL_MAX_DEPTH} deep" in _refused(kit)
    # One level less is still a kit.
    deep.rmdir()
    assert kit_fetch.load(str(kit), "msb")[0] == "team-kit"


def test_the_path_walk_refuses_a_file_whose_handle_resolves_outside_the_kit(tmp_path, monkeypatch):
    # A directory swapped for a junction after it was listed: the file opened
    # through it is somewhere else, which the handle's final path shows.
    monkeypatch.setattr(kit_fetch, "_WALK_BY_FD", False)
    monkeypatch.setattr(kit_fetch, "_CHECK_FINAL_PATH", True)
    kit = _kit(tmp_path)
    monkeypatch.setattr(kit_fetch, "_final_path", lambda fd: str(tmp_path / "elsewhere" / "team.txt"))
    assert "resolves outside the kit directory" in _refused(kit)
    real_root = os.path.realpath(kit)
    monkeypatch.setattr(kit_fetch, "_final_path", lambda fd: os.path.join(real_root, "files", "team.txt"))
    assert kit_fetch.load(str(kit), "msb")[0] == "team-kit"


@pytest.mark.skipif(sys.platform != "win32", reason="Windows handles and junctions")
def test_final_path_names_the_file_behind_a_junction(tmp_path):
    import subprocess

    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "f.txt").write_text("x", encoding="utf-8")
    junction = tmp_path / "kit" / "j"
    junction.parent.mkdir()
    made = subprocess.run(["cmd", "/c", "mklink", "/J", str(junction), str(outside)], capture_output=True)
    if made.returncode != 0:
        pytest.skip("cannot create a junction here")
    fd = os.open(junction / "f.txt", os.O_RDONLY)
    try:
        final = kit_fetch._final_path(fd)
    finally:
        os.close(fd)
    assert kit_fetch._within(final, os.path.realpath(outside))
    assert not kit_fetch._within(final, os.path.realpath(tmp_path / "kit"))


@posix_only
def test_payload_files_are_opened_without_taking_a_controlling_terminal():
    assert kit_fetch._FILE_FLAGS & os.O_NOCTTY and kit_fetch._FILE_FLAGS & os.O_NOFOLLOW


def test_a_crlf_spec_is_refused_with_its_real_reason(tmp_path):
    kit = _kit(tmp_path, TEAM_SPEC.replace("\n", "\r\n"))
    message = _refused(kit)
    assert "CRLF line endings" in message and "hybrid/v1" not in message


def test_a_missing_directory_is_refused(tmp_path):
    assert "was not found" in _refused(tmp_path / "absent")
    assert "was not found" in _refused("relative-kit")


@pytest.mark.parametrize(("spec", "code", "phrase"), [
    ('schemaVersion: "2"\nkind: mixin\nname: native-kit\n', errors.UNSUPPORTED, "not a neutral hybrid/v1 kit"),
    (TEAM_SPEC.replace("name: team-kit", "name: ../team"), errors.VALIDATION_FAILED, "unsafe or missing name"),
])
def test_a_local_kit_faces_the_fetched_kits_spec_checks(tmp_path, spec, code, phrase):
    message = _refused(_kit(tmp_path, spec), code)
    assert phrase in message and message.startswith("local kit")


# ---------------------------------------------------------------------------
# Both backends apply a local kit from its copy.
# ---------------------------------------------------------------------------


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    captured = capsys.readouterr()
    out = captured.out.strip()
    return rc, (json.loads(out.splitlines()[-1]) if out else None), captured.err


def _spy(monkeypatch, module) -> list[list[str]]:
    seen: list[list[str]] = []
    real = module._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(module, "_run", spy)
    return seen


@pytest.mark.provider_key
def test_msb_create_applies_a_local_extra_kit_with_its_own_egress(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(security, "WINDOWS", False)
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_MSB_RO_INSPECT_RETRY_SLEEP", "0")
    ws = tmp_path / "ws"
    ws.mkdir()
    kit = _kit(tmp_path)
    seen = _spy(monkeypatch, msb)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "lk",
                           "--kit", str(kit), "--json")
    assert rc == 0, err
    assert "team-kit" in doc["data"]["kits"]
    (create,) = [a for a in seen if a[0] == "create"]
    assert "allow@team.example.test" in create  # read from the kit's own spec
    assert not [a for a in seen if any(str(kit) in token for token in a)]  # msb never reads the source


@pytest.mark.provider_key
def test_sbx_create_hands_sbx_only_the_translated_local_kit(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setenv(kit_sbx.BARRIER_TIMEOUT_ENV, "5")
    monkeypatch.setattr(kit_sbx, "BARRIER_POLL_S", 0.01)
    ws = tmp_path / "ws"
    ws.mkdir()
    kit = _kit(tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KITS", str(kit))
    seen = _spy(monkeypatch, sbx)
    rc, doc, err = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "ls", "--json")
    assert rc == 0, err
    assert "team-kit" in doc["data"]["kits"]
    (create,) = [a for a in seen if a[0] == "create"]
    kit_dirs = [Path(create[i + 1]) for i, a in enumerate(create[:-1]) if a == "--kit"]
    team = [d for d in kit_dirs if d.name.startswith("team-kit.")]
    assert len(team) == 1 and kit_sbx.kit_root() in team[0].parents
    assert not [a for a in seen if any(str(kit) in token for token in a)]
    assert state.record_read("sbx", "ls") is not None
