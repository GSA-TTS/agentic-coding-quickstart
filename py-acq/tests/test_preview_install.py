"""M1 installer command/ownership contracts, using only offline fixtures."""

import os
import subprocess
from pathlib import Path

import pytest

from test_install import _make_release
from test_install import _run_raw_installer as _run_installer

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("channel", ["", "Python", "BASH", "bogus"])
def test_invalid_channel_has_no_side_effects(tmp_path, channel):
    result = _run_installer(tmp_path, "--channel", channel)
    assert result.returncode == 2
    assert not list((tmp_path / "home").iterdir())


def test_preview_requires_explicit_rc_pin(tmp_path):
    result = _run_installer(tmp_path, "--channel", "python", "--dry-run")
    assert result.returncode == 2
    assert "explicit" in result.stderr.decode()


def test_preview_isolated_command_and_receipt(tmp_path):
    release = _make_release(tmp_path)
    home = tmp_path / "home"
    ordinary = home / ".local/bin/acq"
    ordinary.parent.mkdir(parents=True)
    ordinary.write_text("keep Bash\n")
    result = _run_installer(tmp_path, "--channel", "python", "--ref", "5.0.0-rc.1",
                            "--source", str(release), "--yes", "--no-prereq-check")
    assert result.returncode == 0, result.stderr.decode()
    root = home / ".local/share/acq-python-preview"
    assert (root / "py-acq/runtime/bin/python3").exists()
    assert (ordinary.parent / "acq-python").resolve() == root / "acq-python"
    assert ordinary.read_text() == "keep Bash\n"
    assert not (home / ".local/share/acq").exists()
    receipt = (root / ".acq-python-preview-receipt").read_text()
    assert "channel=python" in receipt and "version=5.0.0-rc.1" in receipt
    assert "archive=acq-" in receipt and "sha256=" in receipt
    assert not (home / ".profile").exists()


@pytest.mark.parametrize("dangling", [False, True])
def test_preview_refuses_foreign_command_before_install(tmp_path, dangling):
    release = _make_release(tmp_path)
    command = tmp_path / "home/.local/bin/acq-python"
    command.parent.mkdir(parents=True)
    if dangling:
        command.symlink_to(tmp_path / "absent")
    else:
        command.write_text("foreign\n")
    result = _run_installer(tmp_path, "--channel", "python", "--ref", "5.0.0-rc.1",
                            "--source", str(release), "--yes")
    assert result.returncode == 1
    assert not (tmp_path / "home/.local/share/acq-python-preview").exists()
    assert command.is_symlink() if dangling else command.read_text() == "foreign\n"


def test_preview_owned_reinstall_and_backout_preserve_unknown(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release), "--yes")
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    (root / "user-project.txt").write_text("preserve\n")
    assert _run_installer(tmp_path, *args).returncode == 0
    (root / "acq-python").write_text("modified\n")
    result = _run_installer(tmp_path, *args)
    assert result.returncode == 1 and b"modified" in result.stderr
    result = _run_installer(tmp_path, "--channel", "python", "--remove-preview")
    assert result.returncode == 0, result.stderr
    assert (root / "user-project.txt").read_text() == "preserve\n"
    assert (root / "acq-python").read_text() == "modified\n"
    assert not (tmp_path / "home/.local/bin/acq-python").is_symlink()


@pytest.mark.parametrize("part", ["root", "parent", "dot"])
def test_preview_refuses_symlink_and_traversal_roots(tmp_path, part):
    outside = tmp_path / "outside"
    outside.mkdir()
    link = tmp_path / "linked"
    link.symlink_to(outside, target_is_directory=True)
    root = {"root": link, "parent": link / "child", "dot": tmp_path / "../other"}[part]
    result = _run_installer(tmp_path, "--channel", "python", "--ref", "5.0.0-rc.1",
                            "--install-dir", str(root))
    assert result.returncode == 1
    assert not list(outside.iterdir())


@pytest.mark.parametrize("option", ["--install-dir", "--bin-dir"])
@pytest.mark.parametrize("value", ["", "relative", "relative/child"])
def test_preview_relative_path_refused_before_download(tmp_path, option, value):
    result = _run_installer(tmp_path, "--channel", "python", "--ref", "5.0.0-rc.1", option, value)
    assert result.returncode == 1
    assert b"absolute" in result.stderr
    assert not list((tmp_path / "home").iterdir())


def test_preview_http_refused_without_download_or_writes(tmp_path):
    result = _run_installer(tmp_path, "--channel", "python", "--ref", "5.0.0-rc.1",
                            "--source", "http://example.invalid/release")
    assert result.returncode == 2
    assert b"plaintext" in result.stderr
    assert not list((tmp_path / "home").iterdir())


def test_modified_owned_launcher_refuses_before_remote_download(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    (root / "acq-python").write_text("modified\n")
    result = _run_installer(tmp_path, "--channel", "python", "--ref", "5.0.0-rc.1",
                            "--source", "https://example.invalid/no-network")
    assert result.returncode == 1 and b"modified" in result.stderr
    assert b"Downloading" not in result.stdout
    assert (root / "acq-python").read_text() == "modified\n"


def test_backup_only_recovery_preserves_receipt_and_unknown_files(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    (root / "user-project").write_text("keep\n")
    backup = root.with_name(root.name + ".acq-python-preview-previous")
    root.rename(backup)
    assert _run_installer(tmp_path, *args).returncode == 0
    assert (root / "user-project").read_text() == "keep\n"
    assert not backup.exists()


def test_foreign_command_prevents_backup_recovery_without_writes(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    backup = root.with_name(root.name + ".acq-python-preview-previous")
    root.rename(backup)
    command = tmp_path / "home/.local/bin/acq-python"
    command.unlink()
    command.write_text("foreign\n")
    result = _run_installer(tmp_path, *args)
    assert result.returncode == 1 and b"foreign" in result.stderr
    assert backup.exists() and not root.exists()
    assert command.read_text() == "foreign\n"


def test_failed_owned_update_restores_old_root(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    receipt = (root / ".acq-python-preview-receipt").read_bytes()
    (root / "unknown").write_text("keep\n")
    shim = tmp_path / "shim"
    shim.mkdir()
    mv = shim / "mv"
    mv.write_text('#!/bin/sh\ncase "$1" in */publish) exit 1 ;; esac\nexec /bin/mv "$@"\n')
    mv.chmod(0o755)
    env = {**os.environ, "HOME": str(tmp_path / "home"), "PATH": f"{shim}:{os.environ['PATH']}"}
    for key in tuple(env):
        if key.startswith("ACQ_INSTALL_") or key == "XDG_DATA_HOME":
            env.pop(key)
    result = subprocess.run(["sh", str(ROOT / "install.sh"), *args], env=env, capture_output=True, timeout=30)
    assert result.returncode == 1 and b"restored" in result.stderr
    assert (root / ".acq-python-preview-receipt").read_bytes() == receipt
    assert (root / "unknown").read_text() == "keep\n"
    assert (tmp_path / "home/.local/bin/acq-python").exists()


@pytest.mark.parametrize("args", [
    ("--method", "brew", "--dry-run", "--no-msb"),
    ("--method", "npm", "--ref", "v4.2.0", "--dry-run", "--no-msb"),
    ("--method", "clone", "--ref", "v4.2.0", "--dry-run", "--no-msb"),
    ("--method", "brew", "--ref", "v4.2.0", "--dry-run", "--no-msb"),
    ("--sha", "invalid", "--dry-run"),
    ("--unknown",),
])
def test_stable_default_and_explicit_bash_match_main(tmp_path, args):
    stable = tmp_path / "stable.sh"
    stable.write_bytes(subprocess.check_output(["git", "show", "origin/main:install.sh"], cwd=ROOT))
    home = tmp_path / "home"
    home.mkdir()
    env = {**os.environ, "HOME": str(home)}
    for name in tuple(env):
        if name.startswith("ACQ_INSTALL_"):
            env.pop(name)
    expected = subprocess.run(["sh", str(stable), *args], env=env, capture_output=True)
    for selection in [(), ("--channel", "bash"), ("--channel=bash",)]:
        actual = subprocess.run(["sh", str(ROOT / "install.sh"), *selection, *args], env=env, capture_output=True)
        assert (actual.returncode, actual.stdout, actual.stderr) == (expected.returncode, expected.stdout, expected.stderr)
