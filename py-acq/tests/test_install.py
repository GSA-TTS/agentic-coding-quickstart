"""Tier-2 tests for the acq v1 installer (``install.sh``), ADR-0042m.

These drive the POSIX installer as a subprocess against a fully offline,
generated fixture (a tiny release archive + ``SHA256SUMS``) and assert the
fail-closed checksum / dry-run / consent behavior and the user-scope
(no-elevation) guarantees.

They are Tier-2 implementation detail (ADR-0039m): contract evidence is the
language-neutral ``installer/*`` vectors under ``test/vectors/installer``, run by
both the pytest and Bash runners — never these tests. They are skipped on hosts
without a POSIX shell/toolchain. On Windows, where Git Bash supplies one,
install.sh refuses the host as an unsupported platform, so the tests that need a
supported platform are skipped there too: the Windows installer
(``install.ps1``) has its own -DryRun smoke step in .github/workflows/windows.yml
and source checks in the bats suite.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
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

# install.sh supports macOS and Linux only and refuses a Git Bash (MINGW) host,
# so a test that needs it to reach the install path cannot run on Windows.
supported_platform_only = pytest.mark.skipif(
    sys.platform == "win32",
    reason="install.sh refuses Windows hosts; install.ps1 is the Windows installer",
)


# The archive's enumerated components (ADR-0042m), keyed by the name the installer
# reports in its fail-closed "missing" diagnostic.
_COMPONENTS = {
    "launcher": ("acq", "#!/bin/sh\necho acq test launcher\n"),
    "acq-python": ("acq-python", "#!/bin/sh\necho acq-python test launcher\n"),
    "runtime": ("py-acq/runtime/bin/python3", "#!/bin/sh\necho acq test runtime\n"),
    "source": ("py-acq/src/acq_py/__init__.py", '__version__ = "0.1.0"\n'),
    "wheelhouse": ("wheelhouse/placeholder.whl", "placeholder wheel\n"),
}


_ARCHIVES = (
    "acq-macos-arm64.tar.gz",
    "acq-macos-x86_64.tar.gz",
    "acq-linux-x86_64.tar.gz",
    "acq-linux-aarch64.tar.gz",
)
_VERIFIED = re.compile(r"verified acq-(macos|linux)-(arm64|x86_64|aarch64)\.tar\.gz")


def _make_release(
    root: Path, *, bad: bool = False, drop_entry: bool = False, omit: str | None = None
) -> Path:
    """Create an offline release dir (SHA256SUMS + provenance + archive).

    ``omit`` names a component to leave OUT of the archive, so the completeness
    fail-closed tests can build a release that is checksum-valid but incomplete.
    """
    root.mkdir(parents=True, exist_ok=True)
    release = root / "release"
    release.mkdir()
    stage = root / "stage"
    for name, (rel, body) in _COMPONENTS.items():
        if name == omit:
            continue
        path = stage / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)

    # install.sh selects the archive from the host's uname, so the fixture ships one
    # per supported platform and the tests pass on any of them.
    sums = []
    for name in _ARCHIVES:
        archive = release / name
        with tarfile.open(archive, "w:gz") as tf:
            for path in sorted(p for p in stage.rglob("*") if p.is_file()):
                tf.add(path, arcname=path.relative_to(stage).as_posix())
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        sums.append(f"{'0' * 64 if bad else sha}  {name}\n")
    if drop_entry:
        (release / "SHA256SUMS").write_text(f"{sha}  some-other-asset.tar.gz\n")
    else:
        (release / "SHA256SUMS").write_text("".join(sums))
    # The provenance manifest travels alongside SHA256SUMS (a separate asset).
    (release / "provenance.json").write_text(
        '{"schema": 1, "note": "test fixture provenance (no secrets)"}\n'
    )
    return release


def _run_installer(tmp_path: Path, *args: str, stdin: bytes = b"") -> subprocess.CompletedProcess:
    home = tmp_path / "home"
    home.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["HOME"] = str(home)
    for name in ("XDG_DATA_HOME", "ACQ_INSTALL_DIR", "ACQ_INSTALL_BIN_DIR", "ACQ_INSTALL_SOURCE", "ACQ_INSTALL_CHANNEL"):
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


# An elevation command token (sudo/pkexec on POSIX, runas on Windows) followed by
# an argument. Requiring a trailing whitespace (i.e. the command has arguments)
# distinguishes an invocation from prose naming the word — "no sudo," (comma) or
# "(no sudo)" (paren) do not match — while still catching elevation through a
# wrapper (`run sudo …`) or a command substitution (`$(sudo …)`). The installer may
# legitimately mention "no sudo" in comments and --help prose, so a bare substring
# match is wrong (and is exactly what failed in CI).
_ELEVATION_COMMAND = re.compile(r"\b(sudo|pkexec|runas)\s")


def _elevation_invocations(source: str) -> list[str]:
    """Lines that *invoke* privilege elevation, ignoring comments/documentation."""
    offending: list[str] = []
    for line in source.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if _ELEVATION_COMMAND.search(line):
            offending.append(line)
        elif "osascript" in stripped and "with administrator privileges" in stripped:
            offending.append(line)
    return offending


def _secret_literal_lines(source: str) -> list[str]:
    """Lines that dump the environment or hardcode a secret-looking value."""
    return [
        line
        for line in source.splitlines()
        if "printenv" in line
        or any(tok in line.upper() for tok in ("API_KEY=", "TOKEN=", "PASSWORD=", "SECRET="))
    ]


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


@supported_platform_only
def test_channel_python_dry_run_surfaces_channel(tmp_path):
    # ADR-0047m: --channel python is the only (and default) channel; it parses,
    # surfaces the channel in the plan, and installs exactly what the no-flag
    # default installs today.
    proc = _run_installer(tmp_path, "--channel", "python", "--dry-run")
    assert proc.returncode == 0
    assert "channel:" in proc.stdout.decode()


def test_channel_unknown_is_a_usage_error(tmp_path):
    proc = _run_installer(tmp_path, "--channel", "bogus")
    assert proc.returncode == 2
    assert "unknown channel" in proc.stderr.decode()


@supported_platform_only
def test_channel_python_offline_install_succeeds(tmp_path):
    release = _make_release(tmp_path)
    proc = _run_installer(tmp_path, "--source", str(release), "--channel", "python", "--yes")
    assert proc.returncode == 0
    assert _VERIFIED.search(proc.stdout.decode())
    assert (_bin_dir(tmp_path) / "acq").is_symlink()
    # The coexistence seam also links the Python implementation's distinct
    # identity (ADR-0047m).
    assert (_bin_dir(tmp_path) / "acq-python").is_symlink()


@supported_platform_only
def test_dry_run_performs_no_writes(tmp_path):
    proc = _run_installer(tmp_path, "--dry-run")
    assert proc.returncode == 0
    assert "[dry-run]" in proc.stdout.decode()
    # A dry run must not create the install dir, the bin dir, or any file.
    assert not _install_dir(tmp_path).exists()
    assert not _bin_dir(tmp_path).exists()


@supported_platform_only
def test_offline_install_succeeds(tmp_path):
    release = _make_release(tmp_path)
    proc = _run_installer(tmp_path, "--source", str(release), "--yes")
    assert proc.returncode == 0
    assert _VERIFIED.search(proc.stdout.decode())
    # The bundled runtime and the launcher are laid down.
    assert (_install_dir(tmp_path) / "py-acq" / "runtime" / "bin" / "python3").exists()
    assert (_bin_dir(tmp_path) / "acq").is_symlink()
    # The coexistence seam links the Python implementation's distinct identity
    # (ADR-0047m): `acq-python` points at its OWN launcher, never an alias of
    # `acq`. The two installed names must resolve to distinct files.
    assert (_bin_dir(tmp_path) / "acq-python").is_symlink()
    assert (_bin_dir(tmp_path) / "acq").resolve() == (_install_dir(tmp_path) / "acq").resolve()
    assert (_bin_dir(tmp_path) / "acq-python").resolve() == (_install_dir(tmp_path) / "acq-python").resolve()
    assert (_bin_dir(tmp_path) / "acq").resolve() != (_bin_dir(tmp_path) / "acq-python").resolve()


@supported_platform_only
def test_checksum_mismatch_fails_closed(tmp_path):
    release = _make_release(tmp_path, bad=True)
    proc = _run_installer(tmp_path, "--source", str(release), "--yes")
    assert proc.returncode == 1
    assert "checksum mismatch" in proc.stderr.decode()
    assert not _install_dir(tmp_path).exists()


@supported_platform_only
def test_missing_checksum_entry_fails_closed(tmp_path):
    release = _make_release(tmp_path, drop_entry=True)
    proc = _run_installer(tmp_path, "--source", str(release), "--yes")
    assert proc.returncode == 1
    assert "no entry" in proc.stderr.decode()
    assert not _install_dir(tmp_path).exists()


@supported_platform_only
@pytest.mark.parametrize(
    "omit,needle",
    [
        ("launcher", "launcher"),
        ("acq-python", "acq-python"),
        ("runtime", "runtime"),
        ("source", "source tree"),
        ("wheelhouse", "wheelhouse"),
    ],
)
def test_missing_component_fails_closed(tmp_path, omit, needle):
    # A checksum-valid archive that is nonetheless missing an enumerated component
    # must fail closed before publishing, not install and fail later.
    release = _make_release(tmp_path, omit=omit)
    proc = _run_installer(tmp_path, "--source", str(release), "--yes")
    assert proc.returncode == 1
    assert needle in proc.stderr.decode()
    assert not _install_dir(tmp_path).exists()


@supported_platform_only
def test_missing_provenance_fails_closed(tmp_path):
    release = _make_release(tmp_path)
    (release / "provenance.json").unlink()
    proc = _run_installer(tmp_path, "--source", str(release), "--yes")
    assert proc.returncode == 1
    assert "provenance" in proc.stderr.decode()
    assert not _install_dir(tmp_path).exists()


@supported_platform_only
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
    # The installer documents non-elevation ("no sudo") in comments and --help
    # prose; that wording must not read as an elevation invocation.
    assert "sudo" in source
    assert _elevation_invocations(source) == []


def test_elevation_guard_is_a_mutation_proof():
    source = INSTALL_SH.read_text(encoding="utf-8")
    # Positive control: an introduced elevation command is detected — directly,
    # through a wrapper (`run sudo …`), and through command substitution — while
    # the clean installer (with its "no sudo" documentation) is not.
    assert _elevation_invocations(source + "\nsudo true\n") == ["sudo true"]
    assert _elevation_invocations(source + "\nrun sudo true\n") == ["run sudo true"]
    assert _elevation_invocations(source + '\nx="$(sudo true)"\n') == ['x="$(sudo true)"']
    assert _elevation_invocations(source) == []


def test_installer_has_no_secret_literals():
    source = INSTALL_SH.read_text(encoding="utf-8")
    # Mutation proof: no secret value or environment dump is ever introduced.
    assert _secret_literal_lines(source) == []


def test_windows_installer_has_no_secret_literals():
    source = (REPO_ROOT / "install.ps1").read_text(encoding="utf-8")
    # Coverage symmetry with install.sh: the Windows installer is just as free of
    # secret literals and environment dumps.
    assert _secret_literal_lines(source) == []


_GEN_ASSETS = (
    "install.sh",
    "install.ps1",
    "provenance.json",
    "acq-linux-x86_64.tar.gz",
    "acq-linux-aarch64.tar.gz",
    "acq-macos-arm64.tar.gz",
    "acq-macos-x86_64.tar.gz",
    "acq-windows-x64.zip",
)
# The only line form SHA256SUMS may contain: "HASH  name", two spaces, no "*".
_SUMS_LINE = re.compile(r"[0-9a-f]{64}  [^ *][^\r]*")


def _run_gen_install_assets(tmp_path, env=None):
    dist = tmp_path / "dist"
    dist.mkdir()
    shutil.copy(INSTALL_SH, dist / "install.sh")
    shutil.copy(REPO_ROOT / "install.ps1", dist / "install.ps1")
    shutil.copy(REPO_ROOT / "installer" / "provenance.json", dist / "provenance.json")
    # The enumerated archive names from installer/assets.json; gen-install-assets
    # only hashes them, so the bodies need not be a real runtime.
    for name in _GEN_ASSETS[3:]:
        (dist / name).write_bytes(name.encode() + b"\n")
    proc = subprocess.run(
        ["sh", str(REPO_ROOT / "scripts" / "gen-install-assets"), str(dist)],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr.decode()
    return dist, (dist / "SHA256SUMS").read_bytes().decode("utf-8")


def _assert_text_form_sums(dist, sums):
    lines = sums.split("\n")
    assert lines[-1] == "", "SHA256SUMS must end with a newline"
    lines = lines[:-1]
    for line in lines:
        assert _SUMS_LINE.fullmatch(line), f"not 'HASH  name': {line!r}"
    recorded = {line[66:]: line[:64] for line in lines}
    assert sorted(recorded) == sorted(_GEN_ASSETS)
    for name, digest in recorded.items():
        assert hashlib.sha256((dist / name).read_bytes()).hexdigest() == digest


def test_gen_install_assets_writes_complete_sha256sums(tmp_path):
    # gen-install-assets needs python3 (to read the manifest) and sha256sum.
    if not (shutil.which("python3") and shutil.which("sha256sum")):
        pytest.skip("python3/sha256sum unavailable")
    dist, sums = _run_gen_install_assets(tmp_path)
    _assert_text_form_sums(dist, sums)


@pytest.mark.skipif(sys.platform == "win32", reason="the fake sha256sum is a POSIX script")
def test_gen_install_assets_normalizes_binary_mode_sha256sum(tmp_path):
    # Git for Windows' sha256sum writes the binary-mode form "HASH *name". A fake
    # that does the same must not get a "*" into SHA256SUMS.
    if not shutil.which("python3"):
        pytest.skip("python3 unavailable")
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    fake = fake_bin / "sha256sum"
    fake.write_text(
        f"#!{sys.executable}\n"
        "import hashlib, sys\n"
        "for name in sys.argv[1:]:\n"
        "    with open(name, 'rb') as fh:\n"
        "        print(hashlib.sha256(fh.read()).hexdigest() + ' *' + name)\n"
    )
    fake.chmod(0o755)
    env = {**os.environ, "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}"}
    dist, sums = _run_gen_install_assets(tmp_path, env=env)
    assert "*" not in sums
    _assert_text_form_sums(dist, sums)
