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
    assert result.returncode == 1 and b"non-identical existing preview file" in result.stderr
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
    assert result.returncode == 1
    assert b"could not download" in result.stderr
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


def _repack_release_with_links(tmp_path, links):
    release = _make_release(tmp_path)
    archive = next(release.glob("acq-linux-*.tar.gz"))
    unpacked = tmp_path / "unpacked"
    import tarfile

    with tarfile.open(archive, "r:gz") as tf:
        tf.extractall(unpacked, filter="data")
    runtime = unpacked / "py-acq/runtime/bin"
    (runtime / "python3").unlink()
    (runtime / "python3.14").write_text("runtime\n")
    (runtime / "python3").symlink_to("python3.14")
    for path, target in links:
        link = unpacked / path
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target)
    with tarfile.open(archive, "w:gz") as tf:
        for item in sorted(unpacked.rglob("*")):
            tf.add(item, item.relative_to(unpacked).as_posix(), recursive=False)
    import hashlib

    sums = release / "SHA256SUMS"
    sums.write_text(
        "\n".join(
            f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}"
            if line.endswith(f"  {archive.name}")
            else line
            for line in sums.read_text().splitlines()
        )
        + "\n"
    )
    return release


@pytest.mark.parametrize(
    "links, targets",
    [
        ([("py-acq/runtime/bin/idle3", "idle3.14")], ["py-acq/runtime/bin/idle3.14"]),
        ([("py-acq/runtime/share/terminfo/P/P7", "../p/prism7")], ["py-acq/runtime/share/terminfo/p/prism7"]),
    ],
    ids=["sibling-target", "parent-relative-target"],
)
def test_runtime_contained_relative_symlink_in_release_is_allowed(tmp_path, links, targets):
    release = _repack_release_with_links(tmp_path, links)
    archive = next(release.glob("acq-linux-*.tar.gz"))
    # The small fixture has no complete supplier tree, so add the link targets
    # that a real runtime carries and regenerate its checksum-valid archive.
    import tarfile

    expanded = tmp_path / "targets"
    with tarfile.open(archive, "r:gz") as tf:
        tf.extractall(expanded, filter="data")
    for target in targets:
        path = expanded / target
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("target\n")
    with tarfile.open(archive, "w:gz") as tf:
        for item in sorted(expanded.rglob("*")):
            tf.add(item, item.relative_to(expanded).as_posix(), recursive=False)
    import hashlib

    sums = release / "SHA256SUMS"
    sums.write_text(
        "\n".join(
            f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}"
            if line.endswith(f"  {archive.name}") else line
            for line in sums.read_text().splitlines()
        ) + "\n"
    )
    result = _run_installer(
        tmp_path, "--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release)
    )
    assert result.returncode == 0, result.stderr.decode()
    assert (tmp_path / "home/.local/share/acq-python-preview/py-acq/runtime/bin/python3").exists()


def test_reinstall_and_backout_validate_every_owned_runtime_link(tmp_path):
    links = [("py-acq/runtime/bin/idle3", "idle3.14")]
    targets = ["py-acq/runtime/bin/idle3.14"]
    release = _repack_release_with_links(tmp_path, links)
    archive = next(release.glob("acq-linux-*.tar.gz"))
    import tarfile
    import hashlib

    expanded = tmp_path / "link-target"
    with tarfile.open(archive, "r:gz") as tf:
        tf.extractall(expanded, filter="data")
    target = expanded / targets[0]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("target\n")
    with tarfile.open(archive, "w:gz") as tf:
        for item in sorted(expanded.rglob("*")):
            tf.add(item, item.relative_to(expanded).as_posix(), recursive=False)
    sums = release / "SHA256SUMS"
    sums.write_text("\n".join(
        f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}"
        if line.endswith(f"  {archive.name}") else line for line in sums.read_text().splitlines()
    ) + "\n")
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    runtime_link = root / "py-acq/runtime/bin/idle3"
    runtime_link.unlink()
    runtime_link.symlink_to("../../../../outside")
    result = _run_installer(tmp_path, *args)
    assert result.returncode == 1
    assert b"unsupported links" in result.stderr
    result = _run_installer(tmp_path, "--channel", "python", "--remove-preview")
    assert result.returncode == 0
    assert runtime_link.is_symlink(), "backout must preserve every preview-tree link"


def test_unmodified_owned_runtime_link_allows_reinstall_and_backout(tmp_path):
    links = [("py-acq/runtime/bin/idle3", "idle3.14")]
    targets = ["py-acq/runtime/bin/idle3.14"]
    release = _repack_release_with_links(tmp_path, links)
    archive = next(release.glob("acq-linux-*.tar.gz"))
    import tarfile
    import hashlib

    expanded = tmp_path / "unchanged-link"
    with tarfile.open(archive, "r:gz") as tf:
        tf.extractall(expanded, filter="data")
    target = expanded / targets[0]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("target\n")
    with tarfile.open(archive, "w:gz") as tf:
        for item in sorted(expanded.rglob("*")):
            tf.add(item, item.relative_to(expanded).as_posix(), recursive=False)
    sums = release / "SHA256SUMS"
    sums.write_text("\n".join(
        f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}"
        if line.endswith(f"  {archive.name}") else line for line in sums.read_text().splitlines()
    ) + "\n")
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    assert _run_installer(tmp_path, "--channel", "python", "--remove-preview").returncode == 0
    assert (root / "py-acq/runtime/bin/idle3").is_symlink()


def test_tampered_runtime_link_receipt_cannot_unlink_outside_runtime(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    victim = root / "victim"
    victim.symlink_to("py-acq/runtime/bin/python3")
    manifest = root / ".acq-python-preview-files"
    manifest.write_text(manifest.read_text() + "- @link:py-acq/runtime/../../victim@py-acq/runtime/bin/python3\n")
    result = _run_installer(tmp_path, "--channel", "python", "--remove-preview")
    assert result.returncode == 0
    assert victim.is_symlink(), "tampered receipt must not unlink an unowned link"


def test_tampered_manifest_cannot_delete_unknown_regular_file(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    unknown = root / "user-project.txt"
    unknown.write_text("preserve me\n")
    manifest = root / ".acq-python-preview-files"
    import hashlib

    manifest.write_text(
        manifest.read_text()
        + f"{hashlib.sha256(unknown.read_bytes()).hexdigest()} user-project.txt\n"
    )
    result = _run_installer(tmp_path, "--channel", "python", "--remove-preview")
    assert result.returncode == 0
    assert unknown.read_text() == "preserve me\n"


def test_reinstall_refuses_nonidentical_existing_preview_file_without_manifest_authority(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    (root / "acq-python").write_text("user replacement\n")
    result = _run_installer(tmp_path, *args)
    assert result.returncode == 1
    assert b"non-identical existing preview file" in result.stderr


def test_reinstall_refuses_existing_file_where_archive_requires_directory(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    import shutil

    shutil.rmtree(root / "py-acq")
    (root / "py-acq").write_text("not a directory\n")
    result = _run_installer(tmp_path, *args)
    assert result.returncode == 1
    assert b"incompatible existing entry: py-acq" in result.stderr
    assert (root / "py-acq").read_text() == "not a directory\n"


def test_reinstall_refuses_symlink_where_archive_requires_directory(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    target = tmp_path / "external-wheelhouse"
    target.mkdir()
    sentinel = target / "sentinel"
    sentinel.write_text("preserve\n")
    import shutil

    shutil.rmtree(root / "wheelhouse")
    (root / "wheelhouse").symlink_to(target, target_is_directory=True)
    result = _run_installer(tmp_path, *args)
    assert result.returncode == 1
    assert b"preview path contains a symlink" in result.stderr
    assert sentinel.read_text() == "preserve\n"


def test_reinstall_refuses_inserted_existing_runtime_escape_link(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    escape = root / "py-acq/runtime/bin/escape"
    escape.symlink_to("../..")
    result = _run_installer(tmp_path, *args)
    assert result.returncode == 1
    assert b"existing preview runtime contains unsupported links" in result.stderr
    assert escape.is_symlink()


def test_backout_works_when_manifest_is_missing_or_forged(tmp_path):
    release = _make_release(tmp_path)
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    manifest = root / ".acq-python-preview-files"
    manifest.unlink()
    result = _run_installer(tmp_path, "--channel", "python", "--remove-preview")
    assert result.returncode == 0
    assert not (tmp_path / "home/.local/bin/acq-python").exists()
    assert (root / "acq-python").exists()


def test_malformed_runtime_link_marker_is_not_owned_for_backout(tmp_path):
    links = [("py-acq/runtime/bin/idle3", "idle3.14")]
    targets = ["py-acq/runtime/bin/idle3.14"]
    release = _repack_release_with_links(tmp_path, links)
    archive = next(release.glob("acq-linux-*.tar.gz"))
    import tarfile
    import hashlib

    expanded = tmp_path / "forged-marker"
    with tarfile.open(archive, "r:gz") as tf:
        tf.extractall(expanded, filter="data")
    path = expanded / targets[0]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("target\n")
    with tarfile.open(archive, "w:gz") as tf:
        for item in sorted(expanded.rglob("*")):
            tf.add(item, item.relative_to(expanded).as_posix(), recursive=False)
    sums = release / "SHA256SUMS"
    sums.write_text("\n".join(
        f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}"
        if line.endswith(f"  {archive.name}") else line for line in sums.read_text().splitlines()
    ) + "\n")
    args = ("--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release))
    assert _run_installer(tmp_path, *args).returncode == 0
    root = tmp_path / "home/.local/share/acq-python-preview"
    link = root / "py-acq/runtime/bin/idle3"
    manifest = root / ".acq-python-preview-files"
    manifest.write_text(manifest.read_text().replace("- @link:", "forged @link:"))
    result = _run_installer(tmp_path, "--channel", "python", "--remove-preview")
    assert result.returncode == 0
    assert link.is_symlink(), "malformed link marker must not authorize removal"


@pytest.mark.parametrize(
    "links",
    [
        [("py-acq/runtime/bin/absolute", "/outside")],
        [("py-acq/runtime/bin/boundary-escape", "../..")],
        [("py-acq/runtime/bin/escape", "../../../../acq")],
        [("unexpected-link", "py-acq/runtime/bin/python3.14")],
    ],
    ids=["absolute-target", "boundary-escape-target", "escaping-target", "outside-runtime"],
)
def test_unsafe_release_symlink_fails_closed(tmp_path, links):
    release = _repack_release_with_links(tmp_path, links)
    result = _run_installer(
        tmp_path, "--channel", "python", "--ref", "5.0.0-rc.1", "--source", str(release)
    )
    assert result.returncode == 1
    assert b"unsupported links" in result.stderr
    assert not (tmp_path / "home/.local/share/acq-python-preview").exists()


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
