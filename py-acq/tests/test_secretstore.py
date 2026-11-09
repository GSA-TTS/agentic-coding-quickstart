"""Tier-2 tests for the acq secret store (``acq_py.secretstore``).

Each backend runs against an offline fake (``secret_fakes``): ``secret-tool``
and macOS ``security`` as executables on PATH or behind the test-only override,
and Windows DPAPI both through the injectable ``dpapi_encrypt``/``dpapi_decrypt``
seam and through a fake ``powershell.exe``. The conftest pins
``ACQ_SECRET_STORE_DIR`` to a throwaway directory, so no test reaches a real
keychain. The paramount assertion throughout: a value never reaches argv.
"""

from __future__ import annotations

import os
import re
import stat
import sys
from pathlib import Path

import pytest

from acq_py import secretstore
from acq_py.secretstore import GLOBAL, Scope, SecretStoreError
from secret_fakes import POWERSHELL, SECRET_TOOL, SECURITY, apply_env, fake_env, logged_argv, plant, prepend_path

REPO_ROOT = Path(__file__).resolve().parents[2]
POSIX = os.name == "posix"
# The fakes are scripts with a shebang line, runnable only on POSIX hosts.
posix_fakes = pytest.mark.skipif(not POSIX, reason="the fake keychain tools are POSIX scripts")


def _store_dir() -> Path:
    return Path(os.environ["ACQ_SECRET_STORE_DIR"])


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


# ---------------------------------------------------------------------------
# Keys, names, values.
# ---------------------------------------------------------------------------

def test_key_layout_matches_bash():
    assert secretstore.key_for("usai") == "acq.usai"
    assert secretstore.key_for("github", "my-box_1") == "acq.my-box_1.github"
    # A sandbox literally named `global` is a sandbox key, never the global one.
    assert secretstore.key_for("github", "global") == "acq.global.github"
    for bad in ("", "a.b", "a b", "a\nb", "a/b", "a;b", "ü"):
        with pytest.raises(SecretStoreError):
            secretstore.key_for(bad)
        with pytest.raises(SecretStoreError):
            secretstore.key_for("usai", bad or "x.y")


def test_scope_is_structural():
    assert GLOBAL.is_global and GLOBAL.label == "global" and GLOBAL.describe() == "global"
    named = Scope("global")
    assert not named.is_global and named != GLOBAL
    assert named.label == "global" and named.describe() == "sandbox 'global'"
    # Legacy string callers keep their old meaning; typed callers do not.
    assert secretstore.as_scope("global") == GLOBAL
    assert secretstore.as_scope(named) is named


def test_decode_key():
    assert secretstore.decode_key("acq.usai") == ("-g", "usai")
    assert secretstore.decode_key("acq.box.github") == ("box", "github")
    assert secretstore.decode_key("acq.a.b.c") == ("?", "a.b.c")
    assert secretstore.decode_key("other") is None


@pytest.mark.parametrize(
    "value",
    ["", "two\nlines", "tab\there", "acq-dpapi-v1", "acq-dpapi-v1\r"],
)
def test_unstorable_values_are_refused_before_any_write(value):
    assert secretstore.value_problem(value) is not None
    with pytest.raises(SecretStoreError) as info:
        secretstore.store("acq.usai", value)
    if value:
        assert value.strip() not in info.value.message
    assert not _store_dir().exists()


# ---------------------------------------------------------------------------
# Layout and backend selection.
# ---------------------------------------------------------------------------

def test_default_layout_follows_bash(monkeypatch, tmp_path):
    monkeypatch.delenv("ACQ_SECRET_STORE_DIR")
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    layout = secretstore._layout()
    assert layout.file_dir == tmp_path / "data" / "acq" / "secrets"
    assert layout.meta_dir == tmp_path / "data" / "acq" / "secret-meta"
    assert layout.index_file == tmp_path / "data" / "acq" / "secret-index"
    # ACQ_SECRET_FILE_DIR without a /secrets suffix keeps the sidecars inside it.
    monkeypatch.setenv("ACQ_SECRET_FILE_DIR", str(tmp_path / "vault"))
    assert secretstore._layout().meta_dir == tmp_path / "vault" / "secret-meta"
    # The store-dir escape hatch keeps everything beside the forced file store.
    monkeypatch.setenv("ACQ_SECRET_STORE_DIR", str(tmp_path / "s"))
    layout = secretstore._layout()
    assert (layout.file_dir, layout.meta_dir, layout.index_file, layout.force_file) == (
        tmp_path / "s", tmp_path / "s" / "meta", tmp_path / "s" / "index", True,
    )


@pytest.mark.parametrize("var", ["ACQ_SECRET_STORE_DIR", "ACQ_SECRET_FILE_DIR", "ACQ_SECRET_META_DIR"])
def test_relative_layout_override_is_refused(monkeypatch, var):
    if var != "ACQ_SECRET_STORE_DIR":
        monkeypatch.delenv("ACQ_SECRET_STORE_DIR")
    monkeypatch.setenv(var, "relative/dir")
    with pytest.raises(SecretStoreError) as info:
        secretstore.backend_name()
    assert var in info.value.message


@posix_fakes
def test_backend_detection_linux(monkeypatch, tmp_path):
    monkeypatch.delenv("ACQ_SECRET_STORE_DIR")
    monkeypatch.setenv("ACQ_SECRET_FILE_DIR", str(tmp_path / "secrets"))
    monkeypatch.setattr(secretstore, "IS_WINDOWS", False)
    monkeypatch.setattr(secretstore, "IS_MACOS", False)
    empty = tmp_path / "empty-bin"
    empty.mkdir()
    monkeypatch.setenv("PATH", str(empty))
    assert secretstore.backend_name() == "file"
    plant(tmp_path / "bin", "secret-tool", SECRET_TOOL)
    prepend_path(monkeypatch, tmp_path / "bin")
    assert secretstore.backend_name() == "keychain-linux"
    monkeypatch.setenv("ACQ_SECRET_FORCE_FILE", "1")
    assert secretstore.backend_name() == "file"


@posix_fakes
def test_backend_detection_macos(monkeypatch, tmp_path):
    monkeypatch.delenv("ACQ_SECRET_STORE_DIR")
    monkeypatch.setenv("ACQ_SECRET_FILE_DIR", str(tmp_path / "secrets"))
    monkeypatch.setattr(secretstore, "IS_WINDOWS", False)
    monkeypatch.setattr(secretstore, "IS_MACOS", True)
    monkeypatch.setattr(secretstore, "_SECURITY_DEFAULT", str(tmp_path / "missing-security"))
    assert secretstore.backend_name() == "file"
    fake = plant(tmp_path / "bin", "security", SECURITY)
    monkeypatch.setattr(secretstore, "_SECURITY_DEFAULT", str(fake))
    assert secretstore.backend_name() == "keychain-macos"
    # The override is test-only: without ACQ_SECRET_STORE_DIR it is ignored.
    monkeypatch.setattr(secretstore, "_SECURITY_DEFAULT", str(tmp_path / "missing-security"))
    monkeypatch.setenv("ACQ_SECRET_SECURITY_BIN", str(fake))
    assert secretstore.backend_name() == "file"


@posix_fakes
def test_windows_never_uses_the_plaintext_file(monkeypatch, tmp_path):
    monkeypatch.setattr(secretstore, "IS_WINDOWS", True)
    # The forced-file escape hatch (ACQ_SECRET_STORE_DIR) is set by conftest and
    # ACQ_SECRET_FORCE_FILE here; with no PowerShell the store refuses outright.
    monkeypatch.setenv("ACQ_SECRET_FORCE_FILE", "1")
    monkeypatch.setenv("ACQ_SECRET_POWERSHELL_BIN", str(tmp_path / "no-powershell.exe"))
    monkeypatch.setenv("PATH", str(tmp_path))
    with pytest.raises(SecretStoreError) as info:
        secretstore.store("acq.usai", "WIN-VALUE-1")
    assert "plaintext" in info.value.message
    assert not _store_dir().exists()
    plant(tmp_path / "bin", "powershell.exe", POWERSHELL)
    monkeypatch.setenv("ACQ_SECRET_POWERSHELL_BIN", str(tmp_path / "bin" / "powershell.exe"))
    assert secretstore.backend_name() == "keychain-windows"


# ---------------------------------------------------------------------------
# File backend.
# ---------------------------------------------------------------------------

def test_file_backend_roundtrip_scopes_and_perms():
    assert secretstore.backend_name() == "file"
    secretstore.store(secretstore.key_for("usai"), "GLOBALV")
    secretstore.store(secretstore.key_for("usai", "mybox"), "SBXV")
    assert secretstore.resolve("usai") == "GLOBALV"
    assert secretstore.resolve("usai", "mybox") == "SBXV"
    assert secretstore.resolve("usai", "otherbox") == "GLOBALV"
    assert secretstore.has("usai") and not secretstore.has("nope")
    assert secretstore.exists("usai", "mybox") and not secretstore.exists("usai", "otherbox")
    value_file = _store_dir() / "acq.usai"
    assert value_file.read_bytes() == b"GLOBALV"  # no trailing newline, like Bash
    if POSIX:
        assert _mode(value_file) == 0o600
        assert _mode(_store_dir()) == 0o700
    assert not (_store_dir() / "index").exists()  # the file backend keeps no index
    assert sorted(secretstore.list_keys()) == ["acq.mybox.usai", "acq.usai"]
    secretstore.delete(secretstore.key_for("usai", "mybox"))
    secretstore.delete(secretstore.key_for("usai", "mybox"))  # idempotent
    assert secretstore.resolve("usai", "mybox") == "GLOBALV"


def test_file_backend_overwrite_is_atomic_and_cleans_leftovers():
    key = secretstore.key_for("github")
    secretstore.store(key, "FIRST")
    leftover = _store_dir() / f".{key}.tmp.99999"
    leftover.write_text("STALE")
    secretstore.store(key, "SECOND")
    assert secretstore.get(key) == "SECOND"
    assert not list(_store_dir().glob(f".{key}.tmp.{os.getpid()}"))
    secretstore.delete(key)
    assert not leftover.exists()
    assert secretstore.get(key) is None


def test_file_backend_fails_closed_on_a_dpapi_envelope():
    _store_dir().mkdir(parents=True)
    (_store_dir() / "acq.usai").write_bytes(b"acq-dpapi-v1\nQUJD")
    assert secretstore.get("acq.usai") is None
    assert not secretstore.has("usai")
    assert secretstore.unreadable("usai")
    assert secretstore.exists("usai")
    assert secretstore.list_entries() == [{"scope": "global", "service": "usai", "value_state": "unreadable"}]


# ---------------------------------------------------------------------------
# keychain-linux (secret-tool).
# ---------------------------------------------------------------------------

@pytest.fixture
def linux_keychain(monkeypatch, tmp_path):
    if not POSIX:
        pytest.skip("the fake keychain tools are POSIX scripts")
    env = fake_env(tmp_path)
    apply_env(monkeypatch, env)
    plant(tmp_path / "bin", "secret-tool", SECRET_TOOL)
    prepend_path(monkeypatch, tmp_path / "bin")
    assert secretstore.hostexec.which("secret-tool") == str(tmp_path / "bin" / "secret-tool")
    monkeypatch.setattr(secretstore, "backend_name", lambda: "keychain-linux")
    return tmp_path


def test_keychain_linux_value_on_stdin_index_and_delete(linux_keychain):
    log = linux_keychain / "keychain.log"
    secretstore.set_secret("usai", None, "KL-USAI-VALUE")
    secretstore.set_secret("github", "klbox", "KL-GITHUB-VALUE")
    assert secretstore.resolve("usai") == "KL-USAI-VALUE"
    assert secretstore.resolve("github", "klbox") == "KL-GITHUB-VALUE"
    argv = logged_argv(log)
    assert '"store", "--label=acq-secret-store", "acq_key", "acq.usai"' in argv
    assert "KL-USAI-VALUE" not in argv and "KL-GITHUB-VALUE" not in argv
    assert not list(_store_dir().glob("acq.*"))  # values live in the keychain only
    assert (_store_dir() / "index").read_text() == "acq.usai\nacq.klbox.github\n"
    if POSIX:
        assert _mode(_store_dir() / "index") == 0o600
    secretstore.set_secret("usai", None, "KL-USAI-VALUE-2")  # index stays deduplicated
    assert (_store_dir() / "index").read_text() == "acq.usai\nacq.klbox.github\n"
    assert sorted(secretstore.list_keys()) == ["acq.klbox.github", "acq.usai"]
    secretstore.delete("acq.klbox.github")
    assert secretstore.list_keys() == ["acq.usai"]
    assert (_store_dir() / "index").read_text() == "acq.usai\n"


def test_keychain_linux_lost_index_relists_sidecar_keys_only(linux_keychain):
    secretstore.set_secret("gitlab", None, "KL-GL-VALUE", "workshop.cloud.gov", "GITLAB_TOKEN")
    secretstore.set_secret("usai", None, "KL-USAI-VALUE")
    (_store_dir() / "index").unlink()
    assert secretstore.list_keys() == ["acq.gitlab"]


def test_keychain_linux_stale_index_entry_is_dropped(linux_keychain):
    secretstore.set_secret("usai", None, "V1")
    (linux_keychain / "keychain" / "acq.usai").unlink()  # removed behind acq's back
    assert secretstore.list_keys() == []
    assert not secretstore.has("usai")


# ---------------------------------------------------------------------------
# keychain-macos (security -i).
# ---------------------------------------------------------------------------

@pytest.fixture
def macos_keychain(monkeypatch, tmp_path):
    if not POSIX:
        pytest.skip("the fake keychain tools are POSIX scripts")
    apply_env(monkeypatch, fake_env(tmp_path))
    fake = plant(tmp_path / "bin", "security", SECURITY)
    monkeypatch.setenv("ACQ_SECRET_SECURITY_BIN", str(fake))
    monkeypatch.setattr(secretstore, "backend_name", lambda: "keychain-macos")
    return tmp_path


def test_keychain_macos_stores_via_security_i_and_falls_back_to_legacy_file(macos_keychain):
    log = macos_keychain / "keychain.log"
    _store_dir().mkdir(parents=True)
    (_store_dir() / "acq.usai").write_text("OLD-USAI")
    tricky = 'MAC VALUE quote" backslash\\ end'
    secretstore.set_secret("usai", None, tricky)
    assert secretstore.resolve("usai") == tricky
    assert not (_store_dir() / "acq.usai").exists()  # the legacy copy is removed
    argv = logged_argv(log)
    assert '["security", "-i"]' in argv
    assert "MAC VALUE" not in argv
    assert secretstore.list_keys() == ["acq.usai"]
    (_store_dir() / "acq.legacy").write_text("LEGACY")
    assert secretstore.resolve("legacy") == "LEGACY"
    assert sorted(secretstore.list_keys()) == ["acq.legacy", "acq.usai"]
    secretstore.delete("acq.usai")
    assert not secretstore.has("usai")
    assert "acq.usai" not in (_store_dir() / "index").read_text()


def test_security_i_quoting():
    assert secretstore._security_i_quote('a"b\\c') == '"a\\"b\\\\c"'


# ---------------------------------------------------------------------------
# keychain-windows (DPAPI envelope), through the injectable seam.
# ---------------------------------------------------------------------------

@pytest.fixture
def dpapi_seam(monkeypatch):
    calls = {"encrypt": 0}

    def encrypt(plaintext):
        calls["encrypt"] += 1
        return "".join(reversed(plaintext)).encode().hex()

    def decrypt(ciphertext):
        try:
            return "".join(reversed(bytes.fromhex(ciphertext.strip()).decode()))
        except ValueError:
            return None

    monkeypatch.setattr(secretstore, "IS_WINDOWS", True)
    monkeypatch.setattr(secretstore, "backend_name", lambda: "keychain-windows")
    monkeypatch.setattr(secretstore, "dpapi_encrypt", encrypt)
    monkeypatch.setattr(secretstore, "dpapi_decrypt", decrypt)
    return calls


def test_windows_envelope_roundtrip(dpapi_seam):
    secretstore.set_secret("usai", None, "WIN-VALUE")
    raw = (_store_dir() / "acq.usai").read_bytes()
    assert raw == b"acq-dpapi-v1\n" + "EULAV-NIW".encode().hex().encode()
    assert b"WIN-VALUE" not in raw
    assert secretstore.resolve("usai") == "WIN-VALUE"
    assert secretstore.list_keys() == ["acq.usai"]
    assert not (_store_dir() / "index").exists()  # the file lister enumerates directly


def test_windows_crlf_mangled_envelope_is_still_an_envelope(dpapi_seam):
    secretstore.set_secret("usai", None, "WIN-VALUE")
    path = _store_dir() / "acq.usai"
    path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n") + b"\r\n")
    assert secretstore.resolve("usai") == "WIN-VALUE"


def test_windows_migrates_a_legacy_plaintext_value(dpapi_seam):
    _store_dir().mkdir(parents=True)
    path = _store_dir() / "acq.github"
    path.write_bytes(b"LEGACY-PLAIN\n")
    assert secretstore.resolve("github") == "LEGACY-PLAIN"
    assert path.read_bytes().startswith(b"acq-dpapi-v1\n")
    assert secretstore.resolve("github") == "LEGACY-PLAIN"


def test_windows_failed_migration_warns_once_and_keeps_the_value(dpapi_seam, monkeypatch, capsys):
    monkeypatch.setattr(secretstore, "dpapi_encrypt", lambda plaintext: None)
    _store_dir().mkdir(parents=True)
    path = _store_dir() / "acq.github"
    path.write_bytes(b"LEGACY-PLAIN")
    assert secretstore.resolve("github") == "LEGACY-PLAIN"
    assert secretstore.resolve("github") == "LEGACY-PLAIN"
    err = capsys.readouterr().err
    assert err.count("could not encrypt the 'acq.github' secret") == 1
    assert "LEGACY-PLAIN" not in err
    assert path.read_bytes() == b"LEGACY-PLAIN"
    assert (_store_dir() / ".acq.github.warned").exists()
    secretstore.delete("acq.github")
    assert not (_store_dir() / ".acq.github.warned").exists()


def test_windows_migration_never_clobbers_a_concurrent_write(dpapi_seam, monkeypatch):
    _store_dir().mkdir(parents=True)
    path = _store_dir() / "acq.github"
    path.write_bytes(b"LEGACY-PLAIN")
    real_encrypt = secretstore.dpapi_encrypt

    def racing_encrypt(plaintext):
        path.write_bytes(b"acq-dpapi-v1\n" + "WEN".encode().hex().encode())  # a concurrent set
        return real_encrypt(plaintext)

    monkeypatch.setattr(secretstore, "dpapi_encrypt", racing_encrypt)
    assert secretstore.resolve("github") == "LEGACY-PLAIN"
    assert secretstore.get("acq.github") == "NEW"
    assert not list(_store_dir().glob(".acq.github.tmp.*"))


def test_windows_undecryptable_envelope_is_unreadable_not_absent(dpapi_seam):
    _store_dir().mkdir(parents=True)
    (_store_dir() / "acq.usai").write_bytes(b"acq-dpapi-v1\nnot-hex")
    assert not secretstore.has("usai")
    assert secretstore.unreadable("usai")


# ---------------------------------------------------------------------------
# keychain-windows through a fake powershell.exe (the real subprocess path).
# ---------------------------------------------------------------------------

@posix_fakes
def test_windows_powershell_path_keeps_the_value_off_argv(monkeypatch, tmp_path):
    apply_env(monkeypatch, fake_env(tmp_path))
    fake = plant(tmp_path / "bin", "powershell.exe", POWERSHELL)
    monkeypatch.setenv("ACQ_SECRET_POWERSHELL_BIN", str(fake))
    monkeypatch.setattr(secretstore, "IS_WINDOWS", True)
    assert secretstore.backend_name() == "keychain-windows"
    secretstore.set_secret("usai", None, "PS-SECRET-VALUE")
    assert secretstore.resolve("usai") == "PS-SECRET-VALUE"
    assert b"PS-SECRET-VALUE" not in (_store_dir() / "acq.usai").read_bytes()
    argv = logged_argv(tmp_path / "keychain.log")
    assert "PS-SECRET-VALUE" not in argv
    assert "Protect" in argv and "Unprotect" in argv
    monkeypatch.setenv("FAKE_DPAPI_FAIL", "1")
    with pytest.raises(SecretStoreError):
        secretstore.store("acq.usai", "OTHER")
    assert secretstore.unreadable("usai")


def test_powershell_one_liners_are_byte_identical_to_bash():
    bash = (REPO_ROOT / "acq.backends" / "secret-store.sh").read_text(encoding="utf-8")
    one_liners = re.findall(r"-NoLogo -NoProfile -Command '([^']*)'", bash)
    assert one_liners == [secretstore._PS_ENCRYPT, secretstore._PS_DECRYPT]


# ---------------------------------------------------------------------------
# Endpoint metadata sidecar.
# ---------------------------------------------------------------------------

def test_meta_sidecar_layout_precedence_and_list():
    secretstore.meta_store("gitlab", None, "workshop.cloud.gov", "GITLAB_TOKEN")
    secretstore.meta_store("gitlab", "box", "gitlab.example.gov,alt.example.gov", "GL_TOKEN")
    meta = _store_dir() / "meta"
    assert (meta / "acq.gitlab").read_bytes() == b"workshop.cloud.gov\tGITLAB_TOKEN\n"
    if POSIX:
        assert _mode(meta / "acq.gitlab") == 0o600
        assert _mode(meta) == 0o700
    assert secretstore.meta_resolve("gitlab") == ("workshop.cloud.gov", "GITLAB_TOKEN")
    assert secretstore.meta_resolve("gitlab", "box").host == "gitlab.example.gov,alt.example.gov"
    assert secretstore.meta_resolve("gitlab", "other") == ("workshop.cloud.gov", "GITLAB_TOKEN")
    assert secretstore.meta_resolve_exact("gitlab", "other") is None
    (meta / "acq.otherbox.svc").write_text("h\tE\n")
    (meta / "acq.foo.bar.baz").write_text("h\tE\n")
    assert secretstore.meta_list() == ["gitlab"]
    assert secretstore.meta_list("box") == ["gitlab"]
    assert secretstore.meta_list("otherbox") == ["gitlab", "svc"]
    secretstore.meta_delete("gitlab", "box")
    assert secretstore.meta_resolve_exact("gitlab", "box") is None


@pytest.mark.parametrize(("host", "env"), [("bad host", "E"), ("h", "BAD-ENV"), ("h;rm", "E"), ("h", "E\n")])
def test_unsafe_binding_stores_nothing(host, env):
    with pytest.raises(SecretStoreError):
        secretstore.set_secret("svc", None, "VALUE-1", host, env)
    assert not _store_dir().exists()


def test_empty_binding_half_is_a_noop():
    secretstore.set_secret("usai", None, "V", "api.gsa.usai.gov", "")
    assert secretstore.meta_resolve("usai") is None
    assert secretstore.resolve("usai") == "V"


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
def test_private_dirs_created_0700_including_parents(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_SECRET_STORE_DIR", str(tmp_path / "a" / "b" / "store"))
    secretstore.store("acq.usai", "V")
    for path in (tmp_path / "a", tmp_path / "a" / "b", tmp_path / "a" / "b" / "store"):
        assert _mode(path) == 0o700


@posix_fakes
def test_windows_powershell_runs_from_systemroot_only(monkeypatch, tmp_path):
    apply_env(monkeypatch, fake_env(tmp_path))
    monkeypatch.setattr(secretstore, "IS_WINDOWS", True)
    monkeypatch.delenv("ACQ_SECRET_POWERSHELL_BIN", raising=False)
    # A powershell.exe on PATH (or in the current directory) is never used.
    marker = tmp_path / "planted-ran"
    planted_on_path = f"open({str(marker)!r}, 'w').close()\nimport sys\nsys.exit(1)\n"
    plant(tmp_path / "pathbin", "powershell.exe", planted_on_path)
    plant(tmp_path, "powershell.exe", planted_on_path)
    monkeypatch.setenv("PATH", str(tmp_path / "pathbin"))
    monkeypatch.delenv("SystemRoot", raising=False)
    with pytest.raises(SecretStoreError):
        secretstore.backend_name()
    planted = tmp_path / "Windows" / "System32" / "WindowsPowerShell" / "v1.0"
    plant(planted, "powershell.exe", POWERSHELL)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("SystemRoot", "Windows")  # relative: refused, cwd never consulted
    with pytest.raises(SecretStoreError):
        secretstore.backend_name()
    monkeypatch.setenv("ACQ_SECRET_POWERSHELL_BIN", "powershell.exe")  # override must be absolute
    with pytest.raises(SecretStoreError):
        secretstore.backend_name()
    monkeypatch.delenv("ACQ_SECRET_POWERSHELL_BIN")
    monkeypatch.setenv("SystemRoot", str(tmp_path / "Windows"))
    assert secretstore._powershell(secretstore._layout()) == str(planted / "powershell.exe")
    secretstore.set_secret("usai", None, "SYSROOT-VALUE")
    assert secretstore.resolve("usai") == "SYSROOT-VALUE"
    assert not marker.exists()
