"""Tier-2 tests: user directory resolution follows the XDG Base Directory spec.

The spec requires XDG base directory variables to be absolute and says an
implementation should treat a relative value as invalid and ignore it. A relative
value would resolve against the current directory (normally the agent-writable
workspace), so acq must fall back to the documented default under HOME instead.
``ACQ_STATE_DIR`` is acq's own explicit override: a relative value is refused.

Every test here chdirs into a throwaway workspace under ``tmp_path`` so a
regression resolves into that directory, never into the real tree. The
password-database home fallback is always stubbed, so no test can resolve to
the developer's real home.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path, PurePosixPath, PureWindowsPath

import pytest

from acq_py import cli, config, doctor, state, userdirs

BAD_VALUES = ("", "relative", "./relative", "rel/nested")


@pytest.fixture
def workspace(tmp_path, monkeypatch):
    ws = tmp_path / "workspace"
    ws.mkdir()
    monkeypatch.chdir(ws)
    return ws


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = tmp_path / "home"
    path.mkdir()
    monkeypatch.setenv("HOME", str(path))
    monkeypatch.delenv("ACQ_STATE_DIR", raising=False)
    fallback = tmp_path / "account-home"
    monkeypatch.setattr(userdirs, "_account_home", lambda: fallback)
    return path


# --- XDG_STATE_HOME / XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_CACHE_HOME ------------


@pytest.mark.parametrize(
    ("var", "default"),
    [
        ("XDG_STATE_HOME", (".local", "state")),
        ("XDG_CONFIG_HOME", (".config",)),
        ("XDG_DATA_HOME", (".local", "share")),
        ("XDG_CACHE_HOME", (".cache",)),
    ],
)
@pytest.mark.parametrize("value", BAD_VALUES)
def test_xdg_base_ignores_empty_or_relative(
    monkeypatch, workspace, home, var, default, value
):
    monkeypatch.setenv(var, value)
    assert userdirs.xdg_base(var, *default) == home.joinpath(*default)


@pytest.mark.parametrize(
    "var", ["XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"]
)
def test_xdg_base_unset_uses_home_default(monkeypatch, workspace, home, var):
    monkeypatch.delenv(var, raising=False)
    assert userdirs.xdg_base(var, ".x") == home / ".x"


def test_xdg_base_honors_absolute(monkeypatch, workspace, home, tmp_path):
    target = tmp_path / "xdg-abs"
    monkeypatch.setenv("XDG_STATE_HOME", str(target))
    assert userdirs.xdg_base("XDG_STATE_HOME", ".local", "state") == target


@pytest.mark.parametrize("value", BAD_VALUES)
def test_state_dir_ignores_empty_or_relative_xdg_state_home(
    monkeypatch, workspace, home, value
):
    monkeypatch.setenv("XDG_STATE_HOME", value)
    root = state.state_dir()
    assert root == home / ".local" / "state" / "acq"
    assert root.is_absolute()


def test_state_dir_defaults_under_home(monkeypatch, workspace, home):
    monkeypatch.delenv("XDG_STATE_HOME", raising=False)
    assert state.state_dir() == home / ".local" / "state" / "acq"


@pytest.mark.parametrize("value", BAD_VALUES)
def test_config_path_ignores_empty_or_relative_xdg_config_home(
    monkeypatch, workspace, home, value
):
    monkeypatch.setenv("XDG_CONFIG_HOME", value)
    path = config.config_path()
    assert path == home / ".config" / "acq" / "config.yaml"
    assert path.is_absolute()


def test_config_path_defaults_under_home(monkeypatch, workspace, home):
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    assert config.config_path() == home / ".config" / "acq" / "config.yaml"


def test_workspace_config_is_not_read_through_relative_xdg(
    monkeypatch, workspace, home
):
    # A config planted in the workspace must not be picked up via a relative
    # XDG_CONFIG_HOME; a newer schema there would otherwise refuse every verb.
    planted = workspace / "cfg" / "acq" / "config.yaml"
    planted.parent.mkdir(parents=True)
    planted.write_text("schema: 99\n", encoding="utf-8")
    monkeypatch.setenv("XDG_CONFIG_HOME", "cfg")
    assert config.config_schema() is None


def test_workspace_record_is_not_read_through_relative_xdg(
    monkeypatch, workspace, home
):
    monkeypatch.setenv("XDG_STATE_HOME", str(workspace / "st"))
    state.record_write("msb", "victim", agent="planted", workspace="/planted")
    monkeypatch.setenv("XDG_STATE_HOME", "st")
    assert state.record_read("msb", "victim") is None


# --- HOME --------------------------------------------------------------------------


@pytest.mark.parametrize("value", BAD_VALUES)
def test_relative_or_empty_home_uses_account_home(
    monkeypatch, workspace, tmp_path, value
):
    fallback = tmp_path / "account-home"
    monkeypatch.setattr(userdirs, "_account_home", lambda: fallback)
    monkeypatch.setenv("HOME", value)
    monkeypatch.delenv("XDG_STATE_HOME", raising=False)
    monkeypatch.delenv("ACQ_STATE_DIR", raising=False)
    assert userdirs.home_dir() == fallback
    assert state.state_dir() == fallback / ".local" / "state" / "acq"


def test_unset_home_uses_account_home(monkeypatch, workspace, tmp_path):
    fallback = tmp_path / "account-home"
    monkeypatch.setattr(userdirs, "_account_home", lambda: fallback)
    monkeypatch.delenv("HOME", raising=False)
    assert userdirs.home_dir() == fallback


def test_no_absolute_home_fails_closed(monkeypatch, workspace):
    monkeypatch.setattr(userdirs, "_account_home", lambda: None)
    monkeypatch.setenv("HOME", "relative")
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    with pytest.raises(userdirs.UserDirError) as excinfo:
        config.config_path()
    assert "HOME" in excinfo.value.remediation


def test_account_home_is_absolute_and_ignores_home(monkeypatch):
    # Resolution only: nothing is read from or written to the returned path.
    monkeypatch.setenv("HOME", "relative")
    result = userdirs._account_home()
    assert result is None or result.is_absolute()
    assert result != Path("relative")


# --- ACQ_STATE_DIR -----------------------------------------------------------------


@pytest.mark.parametrize("value", ["relative", "./relative", "rel/nested"])
def test_relative_acq_state_dir_is_refused(monkeypatch, workspace, home, value):
    monkeypatch.setenv("ACQ_STATE_DIR", value)
    with pytest.raises(userdirs.UserDirError) as excinfo:
        state.state_dir()
    assert "ACQ_STATE_DIR" in excinfo.value.message
    assert "absolute" in excinfo.value.message


def test_empty_acq_state_dir_counts_as_unset(monkeypatch, workspace, home):
    monkeypatch.setenv("ACQ_STATE_DIR", "")
    monkeypatch.delenv("XDG_STATE_HOME", raising=False)
    assert state.state_dir() == home / ".local" / "state" / "acq"


def test_absolute_acq_state_dir_is_honored(monkeypatch, workspace, home, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "override"))
    assert state.state_dir() == tmp_path / "override"


def test_cli_refuses_relative_acq_state_dir_json(monkeypatch, workspace, home, capsys):
    monkeypatch.setenv("ACQ_STATE_DIR", "relative-state")
    rc = cli.main(["ls", "--json"])
    doc = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    assert "ACQ_STATE_DIR" in doc["error"]["message"]
    assert doc["error"]["remediation"]
    assert list(workspace.iterdir()) == []


def test_cli_refuses_relative_acq_state_dir_subprocess(workspace, acq_cmd):
    # Mutating verb: the refusal must come before the migration pre-step writes
    # anything relative to the current directory.
    env = dict(os.environ, ACQ_STATE_DIR="relative-state", ACQ_BACKEND="msb")
    proc = subprocess.run(
        [*acq_cmd, "secret", "set", "x", "--json"],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    assert proc.returncode == 1, proc.stderr
    doc = json.loads(proc.stdout.strip().splitlines()[-1])
    assert doc["error"]["code"] == "validation_failed"
    assert doc["command"] == "secret set"
    assert list(workspace.iterdir()) == []


def test_cli_human_refusal_goes_to_stderr(workspace, acq_cmd):
    env = dict(os.environ, ACQ_STATE_DIR="relative-state")
    proc = subprocess.run(
        [*acq_cmd, "ls"],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    assert proc.returncode == 1
    assert proc.stdout == ""
    assert "ACQ_STATE_DIR must be an absolute path" in proc.stderr


def test_cli_version_unaffected_by_relative_acq_state_dir(workspace, acq_cmd):
    env = dict(os.environ, ACQ_STATE_DIR="relative-state")
    proc = subprocess.run(
        [*acq_cmd, "version"],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0


def test_cli_relative_xdg_state_home_writes_nothing_in_workspace(
    workspace, acq_cmd, tmp_path
):
    # A mutating verb runs the migration pre-step (generation marker, lock); with
    # a relative XDG_STATE_HOME it must land under HOME, not the workspace.
    home = tmp_path / "home"
    home.mkdir()
    env = dict(
        os.environ,
        HOME=str(home),
        XDG_STATE_HOME="st",
        XDG_CONFIG_HOME="cfg",
        ACQ_BACKEND="msb",
    )
    env.pop("ACQ_STATE_DIR", None)
    subprocess.run(
        [*acq_cmd, "secret", "set", "x", "--json"],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    assert list(workspace.iterdir()) == []
    assert (home / ".local" / "state" / "acq").is_dir()


# --- absoluteness rules (Windows flavor exercised on any host) ---------------------


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("\\foo", False),  # rooted, no drive: resolves against the current drive
        ("/c/x", False),  # Git Bash style, no drive
        ("C:foo", False),  # drive-relative
        ("C:\\x", True),
        ("C:/x", True),
        ("\\\\server\\share\\x", True),  # UNC
        ("", False),
        ("rel", False),
    ],
)
def test_is_absolute_windows_rules(monkeypatch, value, expected):
    monkeypatch.setattr(userdirs, "_PATH", PureWindowsPath)
    assert userdirs.is_absolute(value) is expected


def test_windows_driveless_xdg_value_is_ignored(monkeypatch, tmp_path):
    monkeypatch.setattr(userdirs, "_PATH", PureWindowsPath)
    monkeypatch.setattr(userdirs, "_account_home", lambda: None)
    monkeypatch.setenv("HOME", "C:\\Users\\x")
    monkeypatch.setenv("XDG_STATE_HOME", "/c/Users/x/state")
    assert userdirs.xdg_base("XDG_STATE_HOME", ".local", "state") == Path(
        "C:\\Users\\x", ".local", "state"
    )


@pytest.mark.parametrize(
    ("value", "expected"),
    [("/abs", True), ("rel", False), ("", False), (None, False)],
)
def test_is_absolute_posix_rules(monkeypatch, value, expected):
    monkeypatch.setattr(userdirs, "_PATH", PurePosixPath)
    assert userdirs.is_absolute(value) is expected


# --- doctor reports instead of crashing --------------------------------------------


def test_doctor_state_check_fails_on_relative_acq_state_dir(
    monkeypatch, workspace, home
):
    monkeypatch.setenv("ACQ_STATE_DIR", "relative-state")
    check = doctor.state_check()
    assert check["id"] == "state"
    assert check["status"] == "fail"
    assert "ACQ_STATE_DIR" in check["message"]
    assert check["remediation"]
    assert list(workspace.iterdir()) == []


def test_doctor_state_check_fails_without_absolute_home(monkeypatch, workspace):
    monkeypatch.setattr(userdirs, "_account_home", lambda: None)
    monkeypatch.setenv("HOME", "relative")
    monkeypatch.delenv("ACQ_STATE_DIR", raising=False)
    monkeypatch.delenv("XDG_STATE_HOME", raising=False)
    check = doctor.state_check()
    assert check["status"] == "fail"
    assert "home directory" in check["message"]
    assert check["remediation"]


def test_doctor_json_reports_relative_acq_state_dir(workspace, acq_cmd):
    env = dict(os.environ, ACQ_STATE_DIR="relative-state")
    proc = subprocess.run(
        [*acq_cmd, "doctor", "--json"],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    assert "Traceback" not in proc.stderr
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    checks = {c["id"]: c for c in doc["data"]["checks"]}
    assert checks["state"]["status"] == "fail"
    assert "ACQ_STATE_DIR" in checks["state"]["message"]
    assert list(workspace.iterdir()) == []


def test_doctor_human_reports_relative_acq_state_dir(workspace, acq_cmd):
    env = dict(os.environ, ACQ_STATE_DIR="relative-state")
    proc = subprocess.run(
        [*acq_cmd, "doctor"],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    assert "Traceback" not in proc.stderr
    assert "ACQ_STATE_DIR" in proc.stdout + proc.stderr


# --- pre-step envelopes name the full verb -----------------------------------------


@pytest.mark.parametrize(
    ("argv", "label"),
    [
        (["secret", "set", "x"], "secret set"),
        (["kit-source", "ls"], "kit-source ls"),
        (["provider-credential", "rm", "usai"], "provider-credential rm"),
        (["ls"], "ls"),
    ],
)
def test_user_dirs_refusal_names_full_verb(
    monkeypatch, workspace, home, capsys, argv, label
):
    monkeypatch.setenv("ACQ_STATE_DIR", "relative-state")
    rc = cli.main([*argv, "--json"])
    doc = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert rc == 1
    assert doc["command"] == label


def test_migration_refusal_names_full_verb(
    monkeypatch, workspace, home, capsys, tmp_path
):
    root = tmp_path / "state"
    monkeypatch.setenv("ACQ_STATE_DIR", str(root))
    record = state.record_path("msb", "future")
    record.parent.mkdir(parents=True)
    record.write_text(
        json.dumps({"schema": 99, "name": "future", "backend": "msb"}), encoding="utf-8"
    )
    rc = cli.main(["provider-credential", "rm", "usai", "--json"])
    doc = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert rc == 1
    assert doc["error"]["code"] == "state_schema_unsupported"
    assert doc["command"] == "provider-credential rm"


# --- per-path overrides (ACQ_PROVENANCE_DIR, ACQ_MSB_*, ACQ_*_KIT_CACHE) ----------

# Each override py-acq honours, with the default its remediation names (the same
# text Bash prints, acq.backends/userdirs.sh).
PATH_OVERRIDES = {
    "ACQ_SECRET_STORE_DIR": "the default secret store",
    "ACQ_SECRET_FILE_DIR": "the default secret store",
    "ACQ_PROVENANCE_DIR": "the default",
    "ACQ_SECRET_META_DIR": "the default",
    "ACQ_SECRET_INDEX_FILE": "the default",
    "ACQ_SBX_KIT_CACHE": "the default",
    "ACQ_MSB_KIT_CACHE": "the default",
    "ACQ_MSB_STARTUP_STAGE_DIR": "the default",
    "ACQ_MSB_BALANCED_HOSTS_FILE": "the default",
}


@pytest.mark.parametrize(("var", "default"), PATH_OVERRIDES.items())
@pytest.mark.parametrize("value", ["relative", "./relative", "rel/nested"])
def test_relative_path_override_is_refused(monkeypatch, workspace, home, var, default, value):
    monkeypatch.delenv("ACQ_SECRET_STORE_DIR", raising=False)
    monkeypatch.setenv(var, value)
    with pytest.raises(userdirs.UserDirError) as exc:
        userdirs.check_path_overrides()
    assert exc.value.message == f"{var} must be an absolute path, got {value!r}"
    assert exc.value.remediation == f"set {var} to an absolute path, or unset it to use {default}"


@pytest.mark.parametrize("var", ["ACQ_SECRET_META_DIR", "ACQ_SECRET_INDEX_FILE"])
def test_store_dir_relocates_the_secret_metadata_overrides(monkeypatch, tmp_path, var):
    # Like Bash, these are not read (so not refused) while ACQ_SECRET_STORE_DIR
    # relocates them; a relative store dir itself is still refused.
    monkeypatch.setenv(var, "relative")
    monkeypatch.setenv("ACQ_SECRET_STORE_DIR", str(tmp_path / "store"))
    userdirs.check_path_overrides()
    monkeypatch.setenv("ACQ_SECRET_STORE_DIR", "rel-store")
    with pytest.raises(userdirs.UserDirError, match="ACQ_SECRET_STORE_DIR"):
        userdirs.check_path_overrides()


def test_path_override_empty_is_unset_and_absolute_is_honored(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_PROVENANCE_DIR", "")
    assert userdirs.path_override("ACQ_PROVENANCE_DIR") is None
    monkeypatch.setenv("ACQ_PROVENANCE_DIR", str(tmp_path / "prov"))
    assert userdirs.path_override("ACQ_PROVENANCE_DIR") == tmp_path / "prov"


def test_provenance_dir_ignores_relative_xdg_state_home(monkeypatch, workspace, home):
    monkeypatch.delenv("ACQ_PROVENANCE_DIR", raising=False)
    monkeypatch.setenv("XDG_STATE_HOME", "rel-state")
    assert state.provenance_dir() == home / ".local" / "state" / "acq" / "provenance"


def test_bash_lock_dir_never_resolves_against_the_cwd(monkeypatch, workspace, home):
    from acq_py import lock

    monkeypatch.delenv("ACQ_PROVENANCE_DIR", raising=False)
    monkeypatch.setenv("XDG_STATE_HOME", "rel-state")
    path = lock._bash_lock_dir("msb", "box")
    assert path.is_absolute()
    assert path.is_relative_to(home / ".local" / "state" / "acq" / "provenance")
    monkeypatch.setenv("ACQ_PROVENANCE_DIR", "rel-prov")
    with pytest.raises(userdirs.UserDirError):
        lock._bash_lock_dir("msb", "box")


def test_bash_lock_dir_ignores_relative_home(monkeypatch, workspace, tmp_path):
    from acq_py import lock

    fallback = tmp_path / "account-home"
    monkeypatch.setattr(userdirs, "_account_home", lambda: fallback)
    monkeypatch.setenv("HOME", "relhome")
    monkeypatch.delenv("ACQ_PROVENANCE_DIR", raising=False)
    monkeypatch.delenv("XDG_STATE_HOME", raising=False)
    path = lock._bash_lock_dir("msb", "box")
    assert path.is_relative_to(fallback / ".local" / "state" / "acq" / "provenance")


@pytest.mark.parametrize(("var", "default"), PATH_OVERRIDES.items())
def test_cli_refuses_relative_path_override_with_bash_text(workspace, acq_cmd, var, default):
    env = dict(os.environ, ACQ_BACKEND="msb", **{var: "rel-override"})
    if var != "ACQ_SECRET_STORE_DIR":
        env.pop("ACQ_SECRET_STORE_DIR", None)  # it relocates the metadata overrides
    proc = subprocess.run(
        [*acq_cmd, "ls"],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    assert proc.returncode == 1, proc.stderr
    assert proc.stdout == ""
    assert proc.stderr == (
        f"acq: {var} must be an absolute path, got 'rel-override'\n"
        f"set {var} to an absolute path, or unset it to use {default}\n"
    )
    assert list(workspace.iterdir()) == []


def test_doctor_state_check_fails_on_relative_path_override(monkeypatch, workspace, home):
    monkeypatch.setenv("ACQ_PROVENANCE_DIR", "rel-prov")
    check = doctor.state_check()
    assert check["status"] == "fail"
    assert check["message"] == "ACQ_PROVENANCE_DIR must be an absolute path, got 'rel-prov'"
    assert list(workspace.iterdir()) == []
