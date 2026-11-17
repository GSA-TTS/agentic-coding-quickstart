"""scripts/stage-windows-runtime: the managed Windows runtime in the release zip.

The embedded CPython ignores PYTHONPATH and the current directory when its
._pth file is present, so the staged ._pth must name acq's source and nothing
from the user's workspace (ADR-0042m).
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "stage-windows-runtime"

pytestmark = pytest.mark.skipif(
    sys.platform == "win32" or shutil.which("sh") is None,
    reason="drives the POSIX build script through sh; on Windows CI it runs under Git Bash in the release smoke step",
)


def _fake_embed(
    path: Path,
    *,
    tag: str = "python314",
    extra: dict[str, bytes] | None = None,
    drop: tuple[str, ...] = (),
) -> str:
    members = {
        "python.exe": b"MZ fake",
        f"{tag}.zip": b"PK fake stdlib",
        f"{tag}._pth": f"{tag}.zip\r\n.\r\n\r\n# Uncomment to run site.main() automatically\r\n#import site\r\n".encode(),
        "LICENSE.txt": b"PSF license",
        "python3.dll": b"MZ dll",
    }
    members.update(extra or {})
    with zipfile.ZipFile(path, "w") as z:
        for name, data in members.items():
            if name not in drop:
                z.writestr(name, data)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(SCRIPT), *args], capture_output=True, text=True, cwd=REPO_ROOT
    )


def test_stages_runtime_pth_and_source(tmp_path: Path) -> None:
    embed = tmp_path / "embed.zip"
    sha = _fake_embed(embed)
    tree = tmp_path / "acq-windows-x64"
    tree.mkdir()
    result = _run(str(embed), sha, str(tree))
    assert result.returncode == 0, result.stderr
    runtime = tree / "py-acq" / "runtime"
    assert (runtime / "python.exe").is_file()
    assert (runtime / "LICENSE.txt").is_file()
    # Exactly the stdlib zip, the runtime dir and acq's source; no site, no cwd.
    assert (
        runtime / "python314._pth"
    ).read_bytes() == b"python314.zip\r\n.\r\n..\\src\r\n"
    src = tree / "py-acq" / "src" / "acq_py"
    assert (src / "__init__.py").is_file() and (src / "__main__.py").is_file()
    assert not list((tree / "py-acq" / "src").rglob("__pycache__"))
    assert not list((tree / "py-acq").glob(".staging*"))
    # The test-only backend stubs are not shipped.
    assert not list(src.glob("_stub_*.py"))


@pytest.mark.parametrize("sha", ["0" * 64, "A" * 64, "abc", ""])
def test_refuses_wrong_or_malformed_hash(tmp_path: Path, sha: str) -> None:
    embed = tmp_path / "embed.zip"
    _fake_embed(embed)
    tree = tmp_path / "t"
    tree.mkdir()
    result = _run(str(embed), sha, str(tree))
    assert result.returncode != 0
    assert not (tree / "py-acq" / "runtime").exists()


@pytest.mark.parametrize(
    "kwargs",
    [
        {"drop": ("python314._pth",)},
        {"extra": {"python313._pth": b"x"}},
        {"drop": ("python.exe",)},
        {"drop": ("LICENSE.txt",)},
        {"drop": ("python314.zip",)},
    ],
)
def test_refuses_unexpected_layout(tmp_path: Path, kwargs: dict) -> None:
    embed = tmp_path / "embed.zip"
    sha = _fake_embed(embed, **kwargs)
    tree = tmp_path / "t"
    tree.mkdir()
    result = _run(str(embed), sha, str(tree))
    assert result.returncode != 0
    assert not (tree / "py-acq" / "runtime").exists()
    # Nothing is left behind, not even an empty py-acq directory.
    assert not (tree / "py-acq").exists()


def test_refuses_to_overwrite_an_existing_runtime(tmp_path: Path) -> None:
    embed = tmp_path / "embed.zip"
    sha = _fake_embed(embed)
    tree = tmp_path / "t"
    (tree / "py-acq" / "runtime").mkdir(parents=True)
    (tree / "py-acq" / "runtime" / "keep").write_text("keep")
    result = _run(str(embed), sha, str(tree))
    assert result.returncode != 0
    assert (tree / "py-acq" / "runtime" / "keep").read_text() == "keep"


def test_refuses_to_overwrite_an_existing_source_dir(tmp_path: Path) -> None:
    embed = tmp_path / "embed.zip"
    sha = _fake_embed(embed)
    tree = tmp_path / "t"
    (tree / "py-acq" / "src").mkdir(parents=True)
    result = _run(str(embed), sha, str(tree))
    assert result.returncode != 0
    assert not (tree / "py-acq" / "runtime").exists()


def test_refuses_backslash_entry_names(tmp_path: Path) -> None:
    embed = tmp_path / "embed.zip"
    sha = _fake_embed(embed, extra={"..\\..\\evil.txt": b"x"})
    tree = tmp_path / "t"
    tree.mkdir()
    result = _run(str(embed), sha, str(tree))
    assert result.returncode != 0
    assert not (tree / "py-acq" / "runtime").exists()


def test_traversal_entries_stay_inside_the_tree(tmp_path: Path) -> None:
    embed = tmp_path / "embed.zip"
    sha = _fake_embed(embed, extra={"../escape.txt": b"x"})
    tree = tmp_path / "t"
    tree.mkdir()
    _run(str(embed), sha, str(tree))
    assert not (tmp_path / "escape.txt").exists()
    assert not (tree / "py-acq" / "escape.txt").exists()


def test_release_workflow_pins_the_runtime_and_calls_the_script() -> None:
    text = (REPO_ROOT / ".github/workflows/build-assets.yml").read_text()
    assert "python-3.14.10-embed-amd64.zip" in text
    assert re.search(r"runtime_sha256: [0-9a-f]{64}", text)
    assert "--stage release-tree" in text
    assert "--pack release-tree" in text
    assert text.index("--stage release-tree") < text.index("--pack release-tree")
    assert "unpacked/py-acq/runtime/python.exe -I -m acq_py version" in text
    assembler = (REPO_ROOT / "scripts/assemble-release").read_text()
    assert "stage-windows-runtime" in assembler


def test_assets_manifest_matches_the_staged_layout() -> None:
    assets = json.loads(
        (REPO_ROOT / "installer" / "assets.json").read_text(encoding="utf-8")
    )
    win = assets["platforms"]["windows-x86_64"]["components"]
    assert win["runtime"]["path"] == "py-acq/runtime/python.exe"
    assert win["source"] == "py-acq/src/acq_py/"


def test_assembly_preserves_modified_staged_bytes(tmp_path: Path) -> None:
    embed = tmp_path / 'embed.zip'
    sha = _fake_embed(embed)
    wheels = tmp_path / 'wheelhouse'
    wheels.mkdir()
    (wheels / 'fake.whl').write_bytes(b'wheel')
    (wheels / 'SHA256SUMS').write_text('placeholder\n')
    dist, tree = tmp_path / 'dist', tmp_path / 'tree'
    args = ['sh', str(REPO_ROOT / 'scripts/assemble-release'), 'windows-x86_64',
            str(embed), sha, str(wheels), str(dist)]
    stage = subprocess.run([*args, '--stage', str(tree)], capture_output=True, text=True)
    assert stage.returncode == 0, stage.stderr
    assert not list(dist.glob('*.zip'))
    signed = (tree / 'acq.ps1').read_bytes() + b'\n# simulated signature\n'
    (tree / 'acq.ps1').write_bytes(signed)
    packed = subprocess.run([*args, '--pack', str(tree)], capture_output=True, text=True)
    assert packed.returncode == 0, packed.stderr
    with zipfile.ZipFile(dist / 'acq-windows-x64.zip') as archive:
        assert archive.read('acq.ps1') == signed
        assert archive.read('wheelhouse/fake.whl') == b'wheel'
