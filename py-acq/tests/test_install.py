"""Tier-2 tests for the acq v1 installer (``install.sh``), ADR-0042m.

These drive the POSIX installer as a subprocess against a fully offline,
generated fixture (a tiny release archive + ``SHA256SUMS``) and assert the
fail-closed checksum / dry-run / consent behavior and the user-scope
(no-elevation) guarantees.

They are Tier-2 implementation detail (ADR-0039m): contract evidence is the
language-neutral ``installer/*`` vectors under ``test/vectors/installer``, run by
both the pytest and Bash runners — never these tests. They are skipped on hosts
without a POSIX shell/toolchain (e.g. Windows), where the Windows installer
(``install.ps1``) is covered by the bats suite instead.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
INSTALL_SH = REPO_ROOT / "install.sh"


def _have_tools() -> bool:
    return bool(
        shutil.which("sh")
        and shutil.which("tar")
        and (shutil.which("sha256sum") or shutil.which("shasum"))
    )


pytestmark = pytest.mark.skipif(not _have_tools(), reason="POSIX shell/toolchain unavailable")


def _make_release(root: Path, *, bad: bool = False, drop_entry: bool = False) -> Path:
    """Create an offline release dir (``SHA256SUMS`` + archive); returns the dir."""
    root.mkdir(parents=True, exist_ok=True)
    release = root / "release"
    release.mkdir()
    stage = root / "stage"
    for rel in ("py-acq/runtime/bin", "py-acq/src/acq_py", "wheelhouse"):
        (stage / rel).mkdir(parents=True)
    (stage / "acq").write_text("#!/bin/sh\necho acq test launcher\n")
    (stage / "py-acq/runtime/bin/python3").write_text("#!/bin/sh\necho acq test runtime\n")
    (stage / "py-acq/src/acq_py/__init__.py").write_text('__version__ = "0.1.0"\n')
    (stage / "wheelhouse/placeholder.whl").write_text("placeholder wheel\n")

    archive = release / "acq-linux-x86_64.tar.gz"
    with tarfile.open(archive, "w:gz") as tf:
        for path in sorted(p for p in stage.rglob("*") if p.is_file()):
            tf.add(path, arcname=path.relative_to(stage).as_posix())

    sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    if drop_entry:
        (release / "SHA256SUMS").write_text(f"{sha}  some-other-asset.tar.gz\n")
    else:
        recorded = "0" * 64 if bad else sha
        (release / "SHA256SUMS").write_text(f"{recorded}  acq-linux-x86_64.tar.gz\n")
    return release


def _run_installer(tmp_path: Path, *args: str, stdin: bytes = b"") -> subprocess.CompletedProcess:
    home = tmp_path / "home"
    home.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["HOME"] = str(home)
    for name in ("XDG_DATA_HOME", "ACQ_INSTALL_DIR", "ACQ_INSTALL_BIN_DIR", "ACQ_INSTALL_SOURCE"):
        env.pop(name, None)
    return subprocess.run(
        ["sh", str(INSTALL_SH), *args],
        cwd=str(REPO_ROOT),
        env=env,
        input=stdin,
        capture_output=True,
        timeout=30,
    )


def _install_dir(tmp_path: Path) -> Path:
    return tmp_path / "home" / ".local" / "share" / "acq"


def _bin_dir(tmp_path: Path) -> Path:
    return tmp_path / "home" / ".local" / "bin"


def test_help_exits_zero(tmp_path):
    proc = _run_installer(tmp_path, "--help")
    assert proc.returncode == 0
    assert "install acq" in proc.stdout.decode()


def test_version_exits_zero(tmp_path):
    proc = _run_installer(tmp_path, "--version")
    assert proc.returncode == 0
    assert "install.sh" in proc.stdout.decode()


def test_unknown_option_is_a_usage_error(tmp_path):
    proc = _run_installer(tmp_path, "--bogus")
    assert proc.returncode == 2
    assert "unknown option" in proc.stderr.decode()


def test_dry_run_performs_no_writes(tmp_path):
    proc = _run_installer(tmp_path, "--dry-run")
    assert proc.returncode == 0
    assert "[dry-run]" in proc.stdout.decode()
    # A dry run must not create the install dir, the bin dir, or any file.
    assert not _install_dir(tmp_path).exists()
    assert not _bin_dir(tmp_path).exists()


def test_offline_install_succeeds(tmp_path):
    release = _make_release(tmp_path)
    proc = _run_installer(tmp_path, "--source", str(release), "--yes")
    assert proc.returncode == 0
    assert "verified acq-linux-x86_64.tar.gz" in proc.stdout.decode()
    # The bundled runtime and the launcher are laid down.
    assert (_install_dir(tmp_path) / "py-acq" / "runtime" / "bin" / "python3").exists()
    assert (_bin_dir(tmp_path) / "acq").is_symlink()


def test_checksum_mismatch_fails_closed(tmp_path):
    release = _make_release(tmp_path, bad=True)
    proc = _run_installer(tmp_path, "--source", str(release), "--yes")
    assert proc.returncode == 1
    assert "checksum mismatch" in proc.stderr.decode()
    assert not _install_dir(tmp_path).exists()


def test_missing_checksum_entry_fails_closed(tmp_path):
    release = _make_release(tmp_path, drop_entry=True)
    proc = _run_installer(tmp_path, "--source", str(release), "--yes")
    assert proc.returncode == 1
    assert "no entry" in proc.stderr.decode()
    assert not _install_dir(tmp_path).exists()


def test_consent_is_not_inferred_when_noninteractive(tmp_path):
    release = _make_release(tmp_path)
    # No --yes and a non-interactive stdin: consent must decline (fail closed).
    proc = _run_installer(tmp_path, "--source", str(release), stdin=b"")
    assert proc.returncode == 0  # the install itself still succeeds
    assert "Not changing your PATH" in proc.stderr.decode()
    # No rc file was written.
    rc_files = [f for f in (tmp_path / "home").glob(".*rc")] + [
        tmp_path / "home" / ".profile",
        tmp_path / "home" / ".bash_profile",
    ]
    assert not any(p.exists() for p in rc_files)


def test_unsupported_platform_fails_closed(tmp_path):
    stub = tmp_path / "stub"
    stub.mkdir()
    uname = stub / "uname"
    uname.write_text(
        '#!/bin/sh\ncase "$1" in\n  -s) echo SunOS ;;\n  -m) echo sparc ;;\n  *) echo unknown ;;\nesac\n'
    )
    uname.chmod(0o755)
    env = dict(os.environ)
    env["PATH"] = str(stub) + os.pathsep + env.get("PATH", "")
    proc = subprocess.run(
        ["sh", str(INSTALL_SH), "--dry-run"],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        timeout=30,
    )
    assert proc.returncode == 1
    assert "unsupported platform" in proc.stderr.decode()


def test_installer_never_elevates():
    source = INSTALL_SH.read_text(encoding="utf-8")
    # Mutation proof: any reintroduction of privilege escalation fails this test.
    assert "sudo" not in source
    assert "pkexec" not in source


def test_installer_has_no_secret_literals():
    source = INSTALL_SH.read_text(encoding="utf-8")
    # Mutation proof: no secret value or environment dump is ever introduced.
    assert "printenv" not in source
    for line in source.splitlines():
        assert not any(
            token in line.upper() for token in ("API_KEY=", "TOKEN=", "PASSWORD=", "SECRET=")
        ), line


def test_gen_install_assets_writes_complete_sha256sums(tmp_path):
    # gen-install-assets needs python3 (to read the manifest) and sha256sum.
    if not (shutil.which("python3") and shutil.which("sha256sum")):
        pytest.skip("python3/sha256sum unavailable")
    dist = tmp_path / "dist"
    dist.mkdir()
    shutil.copy(INSTALL_SH, dist / "install.sh")
    shutil.copy(REPO_ROOT / "install.ps1", dist / "install.ps1")
    # The enumerated archive names from installer/assets.json; gen-install-assets
    # only hashes them, so the bodies need not be a real runtime.
    for name, body in (
        ("acq-linux-x86_64.tar.gz", b"linux-x86_64\n"),
        ("acq-linux-aarch64.tar.gz", b"linux-aarch64\n"),
        ("acq-macos-arm64.tar.gz", b"macos-arm64\n"),
        ("acq-macos-x86_64.tar.gz", b"macos-x86_64\n"),
        ("acq-windows-x64.zip", b"windows\n"),
    ):
        (dist / name).write_bytes(body)
    proc = subprocess.run(
        ["sh", str(REPO_ROOT / "scripts" / "gen-install-assets"), str(dist)],
        cwd=str(REPO_ROOT),
        capture_output=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr.decode()
    sums = (dist / "SHA256SUMS").read_text(encoding="utf-8")
    for name in (
        "install.sh",
        "install.ps1",
        "acq-linux-x86_64.tar.gz",
        "acq-linux-aarch64.tar.gz",
        "acq-macos-arm64.tar.gz",
        "acq-macos-x86_64.tar.gz",
        "acq-windows-x64.zip",
    ):
        assert f"  {name}" in sums
