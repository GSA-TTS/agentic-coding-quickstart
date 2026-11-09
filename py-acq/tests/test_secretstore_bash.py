"""Bash <-> Python round trip over the shared acq secret store.

Each test sources the real ``acq.backends/secret-store.sh`` in a Bash child
and drives ``acq_py.secretstore`` in-process against the same environment, so
a value, endpoint sidecar or index entry written by one implementation must
read back identically on the other. Keychain backends use the offline fakes
from ``secret_fakes`` on both sides (Bash calls them through its usual PATH
lookup or test override, with ``_acq_secret_backend`` pinned the way its own
bats suite does). Nothing reaches a real keychain: conftest pins
``ACQ_SECRET_STORE_DIR`` and an unreachable session bus.

The Bash ``acq secret import`` / Python ``secret import`` parity check runs
both CLIs on the same host environment and compares the resulting stores
byte for byte.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import secretstore
from secret_fakes import POWERSHELL, SECRET_TOOL, SECURITY, apply_env, fake_env, logged_argv, plant, prepend_path

REPO_ROOT = Path(__file__).resolve().parents[2]
STORE_SH = REPO_ROOT / "acq.backends" / "secret-store.sh"
BASH = shutil.which("bash")

pytestmark = pytest.mark.skipif(BASH is None or sys.platform == "win32", reason="needs a POSIX bash")

# Bash pins its backend the way its own bats suite does: ACQ_SECRET_STORE_DIR
# forces `file` at source time, so a keychain test unsets the force flag and
# overrides the selector.
_PIN = {
    "file": "",
    "keychain-linux": 'unset ACQ_SECRET_FORCE_FILE; _acq_secret_backend() { printf "keychain-linux\\n"; }',
    "keychain-macos": 'unset ACQ_SECRET_FORCE_FILE; _acq_secret_backend() { printf "keychain-macos\\n"; }',
    "keychain-windows": 'unset ACQ_SECRET_FORCE_FILE; _acq_secret_backend() { printf "keychain-windows\\n"; }',
}


def _bash(backend: str, script: str, **env: str) -> str:
    """Run ``script`` with secret-store.sh sourced; return stdout. Values reach
    Bash only through the environment, never its argv."""
    full = f'. "{STORE_SH}"\n{_PIN[backend]}\n{script}'
    proc = subprocess.run(
        [BASH, "-c", full],
        env={**os.environ, **env},
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    return proc.stdout


def _store_dir() -> Path:
    return Path(os.environ["ACQ_SECRET_STORE_DIR"])


def _snapshot(root: Path) -> dict[str, bytes]:
    return {
        str(p.relative_to(root)): p.read_bytes()
        for p in sorted(root.rglob("*"))
        if p.is_file() and not p.name.endswith(".log")
    }


_BASH_WRITES = """
printf '%s\\n' "$V_GLOBAL" | acq_secret_store "$(_acq_secret_key usai)"
printf '%s\\n' "$V_SCOPED" | acq_secret_store "$(_acq_secret_key github global)"
acq_secret_meta_store gitlab "" workshop.cloud.gov GITLAB_TOKEN
printf '%s\\n' "$V_GITLAB" | acq_secret_store "$(_acq_secret_key gitlab)"
"""

_BASH_READS = """
printf 'usai=%s\\n' "$(acq_secret_resolve usai)"
printf 'github-global-box=%s\\n' "$(acq_secret_resolve github global)"
printf 'github-fallback=%s\\n' "$(acq_secret_resolve github otherbox)"
printf 'meta=%s\\n' "$(acq_secret_meta_resolve gitlab)"
printf 'keys=%s\\n' "$(acq_secret_list_keys | sort | tr '\\n' ' ')"
"""

VALUES = {
    "V_GLOBAL": 'usai value with spaces "quotes" \\backslash',
    "V_SCOPED": "gh-scoped-ÄÖ-unicode",
    "V_GITLAB": "glpat-xyz",
}


def _python_writes() -> None:
    secretstore.set_secret("usai", None, VALUES["V_GLOBAL"])
    secretstore.set_secret("github", "global", VALUES["V_SCOPED"])
    secretstore.set_secret("gitlab", None, VALUES["V_GITLAB"], "workshop.cloud.gov", "GITLAB_TOKEN")


def _assert_python_reads() -> None:
    assert secretstore.resolve("usai") == VALUES["V_GLOBAL"]
    assert secretstore.resolve("github", "global") == VALUES["V_SCOPED"]
    # The sandbox named `global` is a sandbox scope on both sides: no global
    # github entry exists, so another sandbox resolves nothing.
    assert secretstore.resolve("github") is None
    assert secretstore.resolve("github", "otherbox") is None
    assert secretstore.meta_resolve("gitlab") == ("workshop.cloud.gov", "GITLAB_TOKEN")
    assert sorted(secretstore.list_keys()) == sorted(["acq.global.github", "acq.usai", "acq.gitlab"])


def _assert_bash_reads(out: str) -> None:
    assert f"usai={VALUES['V_GLOBAL']}\n" in out
    assert f"github-global-box={VALUES['V_SCOPED']}\n" in out
    assert "github-fallback=\n" in out
    assert "meta=workshop.cloud.gov\tGITLAB_TOKEN\n" in out
    assert "keys=acq.gitlab acq.global.github acq.usai \n" in out


def _roundtrip(backend: str) -> tuple[dict[str, bytes], dict[str, bytes]]:
    """Bash writes -> Python reads; Python writes -> Bash reads. Returns the two
    on-disk snapshots (acq store + fake keychain) for byte comparison."""
    root = _store_dir().parent
    _bash(backend, _BASH_WRITES, **VALUES)
    _assert_python_reads()
    bash_written = _snapshot(root)
    shutil.rmtree(_store_dir())
    if (root / "keychain").exists():
        shutil.rmtree(root / "keychain")
    _python_writes()
    _assert_bash_reads(_bash(backend, _BASH_READS))
    python_written = _snapshot(root)
    # Deletes cross over too: Python deletes what Bash lists, and vice versa.
    _bash(backend, 'acq_secret_delete "$(_acq_secret_key usai)"; acq_secret_meta_delete gitlab ""')
    assert secretstore.resolve("usai") is None
    assert secretstore.meta_resolve("gitlab") is None
    secretstore.delete("acq.global.github")
    assert "acq.global.github" not in _bash(backend, _BASH_READS)
    return bash_written, python_written


def _pin_python(monkeypatch, backend: str) -> None:
    monkeypatch.setattr(secretstore, "backend_name", lambda: backend)


def test_roundtrip_file_backend(monkeypatch):
    bash_written, python_written = _roundtrip("file")
    assert bash_written == python_written
    assert f"{_store_dir().name}/index" not in bash_written
    assert f"{_store_dir().name}/meta/acq.gitlab" in bash_written


def test_roundtrip_keychain_linux(monkeypatch, tmp_path):
    env = fake_env(_store_dir().parent)
    apply_env(monkeypatch, env)
    plant(tmp_path / "bin", "secret-tool", SECRET_TOOL)
    prepend_path(monkeypatch, tmp_path / "bin")
    _pin_python(monkeypatch, "keychain-linux")
    bash_written, python_written = _roundtrip("keychain-linux")
    # Bash's acq_secret_store indexes every keychain write; so does Python.
    assert bash_written == python_written
    assert python_written[f"{_store_dir().name}/index"] == b"acq.usai\nacq.global.github\nacq.gitlab\n"
    argv = logged_argv(Path(env["FAKE_KEYCHAIN_LOG"]))
    assert all(v not in argv for v in VALUES.values())


def test_roundtrip_keychain_macos(monkeypatch, tmp_path):
    env = fake_env(_store_dir().parent)
    apply_env(monkeypatch, env)
    fake = plant(tmp_path / "bin", "security", SECURITY)
    monkeypatch.setenv("ACQ_SECRET_SECURITY_BIN", str(fake))
    _pin_python(monkeypatch, "keychain-macos")
    bash_written, python_written = _roundtrip("keychain-macos")
    assert bash_written == python_written
    argv = logged_argv(Path(env["FAKE_KEYCHAIN_LOG"]))
    assert all(v not in argv for v in VALUES.values())


def test_roundtrip_keychain_windows_envelope(monkeypatch, tmp_path):
    env = fake_env(_store_dir().parent)
    apply_env(monkeypatch, env)
    fake = plant(tmp_path / "bin", "powershell.exe", POWERSHELL)
    monkeypatch.setenv("ACQ_SECRET_POWERSHELL_BIN", str(fake))
    monkeypatch.setattr(secretstore, "IS_WINDOWS", True)
    bash_written, python_written = _roundtrip("keychain-windows")
    # The fake DPAPI is deterministic, so the envelopes are byte-identical.
    assert bash_written == python_written
    assert python_written[f"{_store_dir().name}/acq.usai"].startswith(b"acq-dpapi-v1\n")
    argv = logged_argv(Path(env["FAKE_KEYCHAIN_LOG"]))
    assert all(v not in argv for v in VALUES.values())


def test_windows_legacy_migration_crosses_implementations(monkeypatch, tmp_path):
    """A plaintext value the Bash file backend left behind is read by Python's
    DPAPI backend and re-encrypted; Bash's DPAPI backend then reads the envelope."""
    apply_env(monkeypatch, fake_env(_store_dir().parent))
    fake = plant(tmp_path / "bin", "powershell.exe", POWERSHELL)
    monkeypatch.setenv("ACQ_SECRET_POWERSHELL_BIN", str(fake))
    _bash("file", 'printf "LEGACY-PLAIN\\n" | acq_secret_store "$(_acq_secret_key usai)"')
    assert (_store_dir() / "acq.usai").read_bytes() == b"LEGACY-PLAIN"
    monkeypatch.setattr(secretstore, "IS_WINDOWS", True)
    assert secretstore.resolve("usai") == "LEGACY-PLAIN"
    assert (_store_dir() / "acq.usai").read_bytes().startswith(b"acq-dpapi-v1\n")
    assert _bash("keychain-windows", 'acq_secret_resolve usai') == "LEGACY-PLAIN"
    # And Bash's plaintext backend fails closed on the envelope rather than
    # returning ciphertext as the secret.
    assert _bash("file", 'acq_secret_resolve usai || printf "ABSENT"') == "ABSENT"


def test_bash_refuses_what_python_refuses():
    """Names Python refuses are the names Bash's key function refuses."""
    for name in ("a.b", "a b", "a;b"):
        out = _bash("file", f'_acq_secret_key "{name}" >/dev/null 2>&1 && echo ok || echo refused')
        assert out == "refused\n"
        assert not secretstore.name_ok(name)


# ---------------------------------------------------------------------------
# `secret import` parity: Bash acq vs Python acq on the same environment.
# ---------------------------------------------------------------------------

_TOKEN_VARS = ("USAI_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "GITLAB_TOKEN", "OPENCODE_API_KEY")
# Store-layout and backend knobs a developer's or runner's shell could carry in.
_PINNED_AWAY = (
    "ACQ_SECRET_IMPORT_ASSUME_YES", "ACQ_PROVIDER_CREDENTIAL_BINDINGS", "ACQ_SECRET_FORCE_FILE",
    "ACQ_SECRET_FILE_DIR", "ACQ_SECRET_META_DIR", "ACQ_SECRET_INDEX_FILE", "ACQ_BACKEND",
)

# Bash `acq` resolves a backend before it dispatches any verb, `secret import`
# included, even though import never calls it. A host without msb or sbx (a CI
# runner) would make Bash exit 1 before importing anything, so the Bash side
# gets a fake msb that answers only `--version`, on every host alike.
_FAKE_MSB = '#!/bin/sh\n[ "${1:-}" = "--version" ] && { echo "msb 0.7.11"; exit 0; }\nexit 1\n'


def _import_env(store: Path, tokens: dict[str, str], fake_bin: Path) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in _TOKEN_VARS + _PINNED_AWAY}
    env.update(tokens)
    # Both sides use the forced file backend under their own directory, so a
    # host secret-tool or keychain can never be chosen.
    env["ACQ_SECRET_STORE_DIR"] = str(store)
    env["ACQ_BACKEND"] = "msb"
    env["PATH"] = f"{fake_bin}{os.pathsep}{env.get('PATH', '')}"
    return env


def _run_import(cmd: list[str], args: str, env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        [*cmd, "secret", "import", *args.split()],
        env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120, check=False,
    )


@pytest.mark.parametrize(
    ("args", "tokens", "seed", "expected"),
    [
        ("--all", {"USAI_API_KEY": "usai-1", "GITHUB_TOKEN": "gh-1"}, {}, {"acq.usai": b"usai-1", "acq.github": b"gh-1"}),
        ("--all", {"GH_TOKEN": "gh-fb", "GITLAB_TOKEN": "gl-1"}, {}, {"acq.github": b"gh-fb", "acq.gitlab": b"gl-1"}),
        ("--all", {"USAI_API_KEY": "usai-new"}, {"acq.usai": b"usai-old"}, {"acq.usai": b"usai-old"}),
        ("--force", {"USAI_API_KEY": "usai-new"}, {"acq.usai": b"usai-old"}, {"acq.usai": b"usai-new"}),
        ("--dry-run --force", {"USAI_API_KEY": "usai-new"}, {}, {}),
        ("", {"USAI_API_KEY": "usai-1"}, {}, {}),  # interactive, no TTY: skipped
        ("github mybox --all", {"GITHUB_TOKEN": "gh-1", "USAI_API_KEY": "u"}, {}, {"acq.mybox.github": b"gh-1"}),
        ("global --all", {"GITHUB_TOKEN": "gh-1"}, {}, {"acq.global.github": b"gh-1"}),
        ("--all", {"USAI_API_KEY": "two\nlines", "GITHUB_TOKEN": "gh-1"}, {}, {"acq.github": b"gh-1"}),
        (
            "--all",
            {"OPENCODE_API_KEY": "oc-1", "ACQ_PROVIDER_CREDENTIAL_BINDINGS": "opencode-go=OPENCODE_API_KEY"},
            {},
            {"acq.opencode-go": b"oc-1"},
        ),
        ("--bogus", {"USAI_API_KEY": "usai-1"}, {}, {}),
    ],
)
def test_secret_import_matches_bash(tmp_path, args, tokens, seed, expected):
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    (fake_bin / "msb").write_text(_FAKE_MSB, encoding="utf-8")
    (fake_bin / "msb").chmod(0o755)
    stores = {}
    procs = {}
    for impl, cmd in (("bash", [BASH, str(REPO_ROOT / "acq")]), ("python", [sys.executable, "-m", "acq_py"])):
        store = tmp_path / impl
        for key, value in seed.items():
            store.mkdir(exist_ok=True)
            (store / key).write_bytes(value)
        procs[impl] = _run_import(cmd, args, _import_env(store, tokens, fake_bin))
        stores[impl] = _snapshot(store) if store.exists() else {}
    diag = json.dumps({k: {n: v.decode() for n, v in s.items()} for k, s in stores.items()})
    diag += "".join(f"\n--- {impl} rc={p.returncode} stderr:\n{p.stderr}" for impl, p in procs.items())
    assert stores["python"] == stores["bash"], diag
    assert stores["python"] == expected, diag
    # Bash exits 1 on a usage error; Python's contract uses 2 (ADR-0038m).
    assert (procs["python"].returncode == 0) == (procs["bash"].returncode == 0), diag
    if procs["bash"].returncode != 0:
        # Both refuse the flag as a usage error, never for a missing backend.
        assert "unknown flag" in procs["bash"].stderr and procs["python"].returncode == 2, diag
