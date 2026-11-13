"""Clone mode (``--clone`` / ``ACQ_CLONE=1``, ADR-0027) in the Python acq.

A one-to-one port of ``test/bats/116-clone-option.bats``: each Bats test has a
test here with the same name (as ``test_<n>_...``, numbered in Bats order), run
in-process against the ``__stub__`` msb or sbx with a real git. Where the
Python acq has no equivalent of what the Bats test drives (a workspace-less create, ``ACQ_MSB_WORKSPACE``, a missing
``kit-translate.sh``), the port pins the Python behaviour that stands in for
it, and says so. Python-only behaviour (``create --recreate`` on a clone
sandbox, a Bash-created clone layout, the JSON fields) follows the port.

Host git is spied on through ``msb_clone._run`` rather than a ``git`` shim on
PATH, so the same tests run on Windows.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import cli, errors, gitrepos, msb, msb_clone, state

pytestmark = pytest.mark.provider_key  # creates sandboxes: needs a stored provider key

GIT = shutil.which("git")
if GIT is None:  # pragma: no cover - every supported host has git
    pytest.skip("git is required", allow_module_level=True)
POSIX = sys.platform != "win32"
posix_only = pytest.mark.skipif(not POSIX, reason="POSIX file modes or shell scripts")
NAME = "shell-cloneproj"
REMOTE = f"sandbox-{NAME}"


# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------


def _git_env(extra: dict | None = None) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update({"GIT_ALLOW_PROTOCOL": "file", "GIT_CONFIG_NOSYSTEM": "1"})
    env.update(extra or {})
    return env


def _git(*args: str, extra: dict | None = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run([GIT, *args], env=_git_env(extra), capture_output=True, text=True, check=check,
                          stdin=subprocess.DEVNULL)


def _commit(repo: Path, *args: str) -> None:
    _git("-C", str(repo), "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false",
         "commit", "-q", *args)


def _mk_repo(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    _git("init", "-q", str(path))
    (path / "file.txt").write_text("one\n", encoding="utf-8")
    _git("-C", str(path), "add", "file.txt")
    _commit(path, "-m", "init")
    return path


def _mk_other_repo(path: Path) -> Path:
    _mk_repo(path)
    (path / "other-only.txt").write_text("other\n", encoding="utf-8")
    _git("-C", str(path), "add", "other-only.txt")
    _commit(path, "-m", "other")
    return path


def _agent_commit(scratch: Path, name: str) -> None:
    (scratch / f"{name}.txt").write_text(f"{name}\n", encoding="utf-8")
    _git("-C", str(scratch), "add", f"{name}.txt")
    _commit(scratch, "-m", name)


@pytest.fixture
def env(monkeypatch, tmp_path):
    """The msb stub, acq state under ``tmp_path/state``, and the workspace repo ``cloneproj``."""
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_MSB_RO_INSPECT_RETRY_SLEEP", "0")
    monkeypatch.setenv("GIT_CEILING_DIRECTORIES", str(tmp_path))
    for var in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setattr(msb, "launch", lambda *a, **k: 0)
    return _mk_repo(tmp_path / "cloneproj")


def _state(tmp_path: Path) -> Path:
    return tmp_path / "state"


def _clones(tmp_path: Path) -> Path:
    return _state(tmp_path) / "clones"


def _scratch(tmp_path: Path, name: str = NAME, repo: str = "cloneproj") -> Path:
    return _clones(tmp_path) / name / repo


def _acq(capsys, *argv: str, backend: str = "msb") -> tuple[int, dict | None, str]:
    rc = cli.main(["--backend", backend, *argv, "--json"])
    captured = capsys.readouterr()
    out = captured.out.strip()
    return rc, (json.loads(out.splitlines()[-1]) if out else None), captured.err


def _create(capsys, *argv: str, backend: str = "msb") -> tuple[int, dict | None, str]:
    return _acq(capsys, "create", "shell", *argv, backend=backend)


def _msb_spy(monkeypatch) -> list[list[str]]:
    seen: list[list[str]] = []
    real = msb._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(msb, "_run", spy)
    return seen


def _create_argv(seen: list[list[str]]) -> list[str]:
    (argv,) = [a for a in seen if a[0] == "create"]
    return argv


def _refute_backend_create(seen: list[list[str]]) -> None:
    assert not [a for a in seen if a and a[0] == "create"]


class _GitCalls(list):
    """``(argv after the git program, env)`` for every host git call msb_clone made."""

    def lines(self) -> list[str]:
        return [" ".join(argv) for argv, _env in self]

    def wrapped(self) -> list[str]:
        return [line for line in self.lines() if "-c protocol.allow=never" in line]


def _git_spy(monkeypatch, fail=None, version: str | None = None) -> _GitCalls:
    """Record (and optionally fail) host git calls. ``fail(line)`` returns an exit code or None."""
    calls = _GitCalls()
    real = msb_clone._run

    def spy(argv, env, **kwargs):
        line = " ".join(argv[1:])
        calls.append((argv[1:], dict(env)))
        if version is not None and argv[1:] == ["--version"]:
            return subprocess.CompletedProcess(argv, 0, f"git version {version}\n", "")
        code = fail(f" {line} ") if fail else None
        if code is not None:
            return subprocess.CompletedProcess(argv, code, "", "fatal: stubbed git failure\n")
        return real(argv, env, **kwargs)

    monkeypatch.setattr(msb_clone, "_run", spy)
    return calls


def _remote_url(repo: Path, remote: str = REMOTE) -> str | None:
    proc = _git("-C", str(repo), "remote", "get-url", remote, check=False)
    return proc.stdout.strip() if proc.returncode == 0 else None


def _remotes(repo: Path) -> str:
    return _git("-C", str(repo), "remote").stdout.strip()


def _cfg(scratch: Path, *args: str) -> subprocess.CompletedProcess:
    return _git("config", "--file", str(scratch / ".git" / "config"), *args, check=False)


def _guest(path: Path) -> str:
    return msb._guest_path(os.path.realpath(path))


def _recorder(tmp_path: Path, out: Path) -> Path:
    rec = tmp_path / "recorder.sh"
    rec.write_text(f'#!/bin/sh\necho "$0 $*" >> "{out.as_posix()}"\ncat\n', encoding="utf-8", newline="\n")
    rec.chmod(0o755)
    return rec


def _arm_repo_config(tmp_path: Path, repo: Path, out: Path, flt: str = "rec") -> None:
    """Point the repo's config at a recorder (fsmonitor, a filter on every file, two hooks), stat-dirty file.txt."""
    rec = _recorder(tmp_path, out)
    hooks = repo / ".git" / "hooks"
    hooks.mkdir(parents=True, exist_ok=True)
    for hook in ("post-index-change", "reference-transaction"):
        shutil.copy(rec, hooks / hook)
    _git("-C", str(repo), "config", "core.fsmonitor", rec.as_posix())
    for part in ("clean", "smudge", "process"):
        _git("-C", str(repo), "config", f"filter.{flt}.{part}", rec.as_posix())
    (repo / ".git" / "info").mkdir(exist_ok=True)
    (repo / ".git" / "info" / "attributes").write_text(f"* filter={flt}\n", encoding="utf-8")
    os.utime(repo / "file.txt", (946684800, 946684800))


def _symlink(target: Path, link: Path) -> None:
    try:
        os.symlink(target, link, target_is_directory=target.is_dir())
    except OSError as exc:  # pragma: no cover - Windows without symlink rights
        pytest.skip(f"cannot create a symlink here: {exc}")


def _assert_layout_refused(rc: int, doc: dict | None, tmp_path: Path, seen, sandbox: str) -> str:
    assert rc == 1 and doc is not None
    message = doc["error"]["message"] + " " + (doc["error"]["remediation"] or "")
    assert "not an ordinary repository checkout" in message
    assert "git worktree" in message and "submodule" in message
    _refute_backend_create(seen)
    assert not (_clones(tmp_path) / sandbox).exists()
    return message


def _isolated_identity(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("HOME", str(tmp_path / "nohome"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "noconfig"))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")


def _message(doc: dict) -> str:
    return doc["error"]["message"] + " " + (doc["error"]["remediation"] or "")


# ---------------------------------------------------------------------------
# The port of test/bats/116-clone-option.bats, in its order.
# ---------------------------------------------------------------------------


def test_01_clone_mounts_a_scratch_clone_at_the_original_path_and_registers_the_sandbox_remote(
        env, tmp_path, monkeypatch, capsys):
    seen = _msb_spy(monkeypatch)
    calls = _git_spy(monkeypatch)
    rc, doc, err = _create(capsys, str(env), "--clone")
    assert rc == 0, (doc, err)
    scratch = _scratch(tmp_path)
    # --no-local already copies through upload-pack; --no-hardlinks is pinned
    # on its own so neither can be dropped unseen.
    (clone_argv,) = [argv for argv, _e in calls if "clone" in argv]
    assert {"--no-local", "--no-hardlinks"} <= set(clone_argv)
    argv = _create_argv(seen)
    volumes = [argv[i + 1] for i, a in enumerate(argv) if a == "--volume"]
    assert f"{os.path.realpath(scratch)}:{_guest(env)}" in volumes
    assert f"{os.path.realpath(env)}:{_guest(env)}" not in volumes
    assert "--clone" not in argv
    # A physical copy: no object file shares an inode with the host repository.
    assert (scratch / ".git").is_dir()
    assert all(p.stat().st_nlink == 1 for p in (scratch / ".git" / "objects").rglob("*") if p.is_file())
    assert os.path.realpath(_remote_url(env) or "") == os.path.realpath(scratch)
    assert f"git fetch {REMOTE}" in err


def test_02_acq_clone_1_env_is_equivalent_to_the_flag(env, tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("ACQ_CLONE", "1")
    seen = _msb_spy(monkeypatch)
    rc, _doc, _err = _create(capsys, str(env))
    assert rc == 0
    assert f"{os.path.realpath(_scratch(tmp_path))}:{_guest(env)}" in _create_argv(seen)


def test_03_records_original_host_checkout_not_scratch_for_github_scope(env, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    record = state.record_read("msb", NAME)
    assert record is not None and record["workspace"] == os.path.realpath(env)
    assert "clones" not in record["workspace"]


def test_04_a_non_git_workspace_fails_the_create_before_the_backend_runs(env, tmp_path, monkeypatch, capsys):
    plain = tmp_path / "plainproj"
    plain.mkdir()
    seen = _msb_spy(monkeypatch)
    rc, doc, _err = _create(capsys, str(plain), "--clone")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "not a git repository" in doc["error"]["message"]
    _refute_backend_create(seen)


def test_05_a_subdirectory_of_a_repo_is_rejected_naming_the_toplevel(env, monkeypatch, capsys):
    (env / "sub").mkdir()
    seen = _msb_spy(monkeypatch)
    rc, doc, _err = _create(capsys, str(env / "sub"), "--clone")
    assert rc == 1
    assert "repository root" in doc["error"]["message"] and "cloneproj" in doc["error"]["message"]
    _refute_backend_create(seen)


def test_06_clone_with_no_workspace_positional_fails_with_guidance(env, monkeypatch, capsys):
    seen = _msb_spy(monkeypatch)
    rc, doc, _err = _create(capsys, "--clone")
    assert rc == 1
    assert "--clone requires a workspace path" in doc["error"]["message"]
    _refute_backend_create(seen)


def test_07_a_dirty_working_tree_gets_a_notice_but_the_create_proceeds(env, monkeypatch, capsys):
    # The check never reads file content (no filter can run), so an unstaged
    # edit to a tracked file goes unreported; a staged one is noted.
    (env / "file.txt").write_text("one\ntwo\n", encoding="utf-8")
    seen = _msb_spy(monkeypatch)
    rc, _doc, err = _create(capsys, str(env), "--name", "unstaged", "--clone")
    assert rc == 0 and "uncommitted changes" not in err
    _git("-C", str(env), "add", "file.txt")
    rc, _doc, err = _create(capsys, str(env), "--clone")
    assert rc == 0 and "uncommitted changes" in err
    assert len([a for a in seen if a[0] == "create"]) == 2


def test_08_the_dirty_tree_notice_covers_untracked_only_changes(env, monkeypatch, capsys):
    (env / "untracked.txt").write_text("new\n", encoding="utf-8")
    seen = _msb_spy(monkeypatch)
    rc, _doc, err = _create(capsys, str(env), "--clone")
    assert rc == 0 and "uncommitted changes" in err and "git add" in err
    _create_argv(seen)


def test_09_a_path_unsafe_explicit_name_is_rejected_before_any_host_path_is_built(env, tmp_path, monkeypatch,
                                                                                    capsys):
    seen = _msb_spy(monkeypatch)
    for bad in ("../evil", ".."):
        rc, doc, _err = _create(capsys, str(env), "--name", bad, "--clone")
        assert rc == 1 and "invalid sandbox name" in doc["error"]["message"]
    _refute_backend_create(seen)
    assert not (_state(tmp_path) / "evil").exists() and not _clones(tmp_path).exists()
    assert _remotes(env) == ""
    # The clone's own check, behind the CLI's: a traversal name builds no path.
    for bad in ("../evil", "..", ".", ""):
        with pytest.raises(msb.MsbError, match="invalid sandbox name"):
            msb_clone.setup(bad, str(env), lambda _n: False)
    assert not _clones(tmp_path).exists() and _remotes(env) == ""


def test_10_secondary_workspaces_keep_their_direct_mounts(env, tmp_path, monkeypatch, capsys):
    # Clone mode changes only the primary mount source; the library stays read-only.
    second = tmp_path / "secondlib"
    second.mkdir()
    seen = _msb_spy(monkeypatch)
    rc = cli.main(["--backend", "msb", "create", "shell", str(env), f"{second}:ro", "--clone", "--json"])
    capsys.readouterr()
    assert rc == 0
    argv = _create_argv(seen)
    mounts = [argv[i + 1] for i, a in enumerate(argv) if a == "--volume" and argv[i + 1].endswith(_guest(env))]
    assert mounts == [f"{os.path.realpath(_scratch(tmp_path))}:{_guest(env)}"]
    assert f"{os.path.realpath(second)}:{_guest(second)}:ro" in argv


def test_11_acq_rm_removes_the_scratch_clone_and_the_host_remote(env, tmp_path, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    assert (_clones(tmp_path) / NAME).is_dir()
    rc, doc, err = _acq(capsys, "rm", NAME)
    assert rc == 0 and "unfetched" not in err and "clone_unfetched" not in doc["data"]
    assert not (_clones(tmp_path) / NAME).exists()
    assert _remote_url(env) is None


def test_12_rm_warns_about_unfetched_commits_before_deleting_the_scratch(env, tmp_path, monkeypatch, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    _agent_commit(_scratch(tmp_path), "agent-work")
    order: list[str] = []
    real_remove = msb.remove
    monkeypatch.setattr(msb, "remove", lambda name: (order.append("remove"), real_remove(name))[1])
    real_warn = msb_clone.warn_unfetched
    monkeypatch.setattr(msb_clone, "warn_unfetched", lambda name: (order.append("warn"), real_warn(name))[1])
    rc, doc, err = _acq(capsys, "rm", NAME)
    assert rc == 0 and doc["data"]["clone_unfetched"] is True
    assert "unfetched commits" in err and f"git fetch {REMOTE}" in err
    assert order == ["warn", "remove"]
    assert not (_clones(tmp_path) / NAME).exists()


def test_13_rm_never_executes_git_inside_the_guest_writable_scratch(env, tmp_path, monkeypatch, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    _agent_commit(scratch, "agent-work")
    _git("-C", str(scratch), "pack-refs", "--all")
    with open(scratch / ".git" / "config", "a", encoding="utf-8") as fh:
        fh.write("[broken\n")
    calls = _git_spy(monkeypatch)
    rc, _doc, err = _acq(capsys, "rm", NAME)
    assert rc == 0 and "unfetched commits" in err
    assert not any(str(scratch) in line or "clones" in line for line in calls.lines())
    assert not (_clones(tmp_path) / NAME).exists()


def test_14_create_starts_no_program_named_by_the_workspace_repos_config(env, tmp_path, capsys):
    ran = tmp_path / "ran"
    _arm_repo_config(tmp_path, env, ran)
    rc, _doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 0 and (_scratch(tmp_path) / ".git").is_dir()
    assert not ran.exists()


def test_15_rm_starts_no_program_named_by_the_workspace_repos_config(env, tmp_path, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    _agent_commit(scratch, "agent-work")
    _git("-C", str(env), "fetch", "-q", REMOTE)
    assert _git("-C", str(env), "for-each-ref", f"refs/remotes/{REMOTE}").stdout.strip()
    _agent_commit(scratch, "agent-work-2")
    ran = tmp_path / "ran"
    _arm_repo_config(tmp_path, env, ran)
    rc, _doc, err = _acq(capsys, "rm", NAME)
    assert rc == 0 and "unfetched commits" in err
    assert not ran.exists()


def test_rm_remote_symbolic_ref_does_not_delete_a_local_branch(env, tmp_path, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    _git("-C", str(env), "branch", "keep-local")
    before = _git("-C", str(env), "rev-parse", "refs/heads/keep-local").stdout.strip()
    _git("-C", str(env), "branch", "keep-other")
    _git("-C", str(env), "update-ref", f"refs/remotes/{REMOTE}/a", "HEAD")
    _git("-C", str(env), "symbolic-ref", f"refs/remotes/{REMOTE}/y-alias", "refs/heads/keep-local")
    _git("-C", str(env), "symbolic-ref", f"refs/remotes/{REMOTE}/z-alias", "refs/heads/keep-other")
    rc, _doc, _err = _acq(capsys, "rm", NAME)
    assert rc == 0
    assert _git("-C", str(env), "rev-parse", "refs/heads/keep-local").stdout.strip() == before
    assert _git("-C", str(env), "rev-parse", "refs/heads/keep-other").stdout.strip() == before
    assert not _git("-C", str(env), "for-each-ref", f"refs/remotes/{REMOTE}").stdout.strip()
    assert _remote_url(env) is None


def test_remote_removal_survives_windows_text_stdin_translation(env, monkeypatch, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    _git("-C", str(env), "update-ref", f"refs/remotes/{REMOTE}/main", "HEAD")
    real_run = msb_clone._run
    payloads = []

    def text_pipe(argv, child_env, *, input_text=None, **kwargs):
        if "update-ref" in argv and input_text is not None:
            payloads.append(input_text)
            input_text = input_text.replace("\n", "\r\n")
        return real_run(argv, child_env, input_text=input_text, **kwargs)

    monkeypatch.setattr(msb_clone, "_run", text_pipe)
    rc, _doc, err = _acq(capsys, "rm", NAME)
    assert rc == 0, err
    assert payloads and all("\n" not in p and "\0" in p for p in payloads)
    assert not _git("-C", str(env), "for-each-ref", f"refs/remotes/{REMOTE}/").stdout.strip()
    assert _remote_url(env) is None


def test_16_a_workspace_that_borrows_objects_via_alternates_is_refused(env, tmp_path, monkeypatch, capsys):
    other = _mk_repo(tmp_path / "otherrepo")
    (env / ".git" / "objects" / "info" / "alternates").write_text(f"{other / '.git' / 'objects'}\n",
                                                                 encoding="utf-8")
    seen = _msb_spy(monkeypatch)
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and "borrows objects from other repositories" in doc["error"]["message"]
    _refute_backend_create(seen)
    assert not (_clones(tmp_path) / NAME).exists()


def test_17_a_read_only_primary_is_rejected_before_any_state_is_created(env, tmp_path, monkeypatch, capsys):
    seen = _msb_spy(monkeypatch)
    rc, doc, _err = _create(capsys, f"{env}:ro", "--clone")
    assert rc == 1 and "read-only" in doc["error"]["message"]
    _refute_backend_create(seen)
    assert not _clones(tmp_path).exists() and _remote_url(env) is None


def test_18_a_failed_create_does_not_leak_the_scratch(env, tmp_path, monkeypatch, capsys):
    # Bats: a missing secondary. The Python acq has no secondaries; the scratch
    # must equally not outlive a create that fails after it was made.
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "create")
    rc, _doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1
    assert not (_clones(tmp_path) / NAME).exists() and _remote_url(env) is None
    monkeypatch.delenv("ACQ_MSB_STUB_FAIL")
    assert _create(capsys, str(env), "--clone")[0] == 0


def test_19_stale_scratch_advice_matches_sandbox_liveness(env, tmp_path, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    with pytest.raises(msb.MsbError) as live:
        msb_clone.setup(NAME, str(env), lambda _n: True)
    assert f"acq rm {NAME}" in _remediation(live.value) and "remove the directory" not in _remediation(live.value)
    with pytest.raises(msb.MsbError) as gone:
        msb_clone.setup(NAME, str(env), lambda _n: False)
    assert "remove the directory" in _remediation(gone.value)
    assert "already exists" in gone.value.message


def _remediation(exc: msb.MsbError) -> str:
    return exc.remediation or ""


def test_20_clone_on_an_existing_sandbox_notes_it_applies_only_at_create(env, monkeypatch, capsys):
    monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps({"clnreattach": "running"}))
    seen = _msb_spy(monkeypatch)
    rc, _doc, err = _acq(capsys, "run", "shell", str(env), "--clone", "--name", "clnreattach")
    assert rc == 0, err
    assert "applies only at create" in err and "'acq rm clnreattach'" in err and "acq msb rm" not in err
    _refute_backend_create(seen)


@pytest.fixture
def sbx_env(monkeypatch, tmp_path):
    from acq_py import kit_sbx

    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setenv(kit_sbx.BARRIER_TIMEOUT_ENV, "5")
    monkeypatch.setattr(kit_sbx, "BARRIER_POLL_S", 0.01)
    seen: list[list[str]] = []
    from acq_py import sbx

    real = sbx._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(sbx, "_run", spy)
    return _mk_repo(tmp_path / "cloneproj"), seen


def test_21_sbx_clone_forwards_to_the_native_sbx_create_clone(sbx_env, capsys):
    repo, seen = sbx_env
    rc, doc, err = _acq(capsys, "create", "opencode", str(repo), "--clone", backend="sbx")
    assert rc == 0, (doc, err)
    assert "--clone" in _create_argv(seen) and doc["data"]["clone"] is True
    assert state.record_read("sbx", "opencode-cloneproj")["clone"] is True


def test_22_the_scratch_carries_the_source_checkouts_effective_git_identity(env, tmp_path, monkeypatch, capsys):
    _git("-C", str(env), "config", "user.name", "Repo User")
    _git("-C", str(env), "config", "user.email", "repo@example.gov")
    _isolated_identity(monkeypatch, tmp_path)
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    assert _cfg(scratch, "user.name").stdout.strip() == "Repo User"
    assert _cfg(scratch, "user.email").stdout.strip() == "repo@example.gov"


def test_23_no_effective_source_identity_writes_nothing_into_the_scratch(env, tmp_path, monkeypatch, capsys):
    _isolated_identity(monkeypatch, tmp_path)
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    assert (scratch / ".git").is_dir()
    assert _cfg(scratch, "user.name").returncode != 0 and _cfg(scratch, "user.email").returncode != 0


def test_24_the_scratchs_origin_is_the_source_checkouts_origin_url(env, tmp_path, monkeypatch, capsys):
    _git("-C", str(env), "remote", "add", "origin", "https://github.com/example/cloneproj.git")
    _isolated_identity(monkeypatch, tmp_path)
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    assert _cfg(scratch, "remote.origin.url").stdout.strip() == "https://github.com/example/cloneproj.git"
    assert _cfg(scratch, "remote.origin.pushurl").returncode != 0
    assert os.path.realpath(_remote_url(env) or "") == os.path.realpath(scratch)


def test_25_a_separate_push_url_on_the_source_origin_is_carried_too(env, tmp_path, monkeypatch, capsys):
    _git("-C", str(env), "remote", "add", "origin", "https://github.com/example/cloneproj.git")
    _git("-C", str(env), "remote", "set-url", "--push", "origin", "git@github.com:example/cloneproj.git")
    _isolated_identity(monkeypatch, tmp_path)
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    assert _cfg(scratch, "remote.origin.url").stdout.strip() == "https://github.com/example/cloneproj.git"
    assert _cfg(scratch, "remote.origin.pushurl").stdout.strip() == "git@github.com:example/cloneproj.git"


def test_26_the_origin_url_is_carried_raw_host_insteadof_rewrites_are_not_baked_in(env, tmp_path, monkeypatch,
                                                                                     capsys):
    _git("-C", str(env), "remote", "add", "origin", "https://github.com/example/cloneproj.git")
    _git("-C", str(env), "config", "url.git@github.com:.insteadOf", "https://github.com/")
    _isolated_identity(monkeypatch, tmp_path)
    assert _create(capsys, str(env), "--clone")[0] == 0
    assert _cfg(_scratch(tmp_path), "remote.origin.url").stdout.strip() == "https://github.com/example/cloneproj.git"


def test_27_a_source_with_no_origin_leaves_the_scratch_with_no_origin_url(env, tmp_path, monkeypatch, capsys):
    _isolated_identity(monkeypatch, tmp_path)
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    assert _cfg(scratch, "remote.origin.url").returncode != 0
    assert _cfg(scratch, "remote.origin.pushurl").returncode != 0
    assert _git("-C", str(scratch), "push", "origin", "HEAD", check=False).returncode != 0


def test_28_a_multi_valued_origin_url_is_carried_in_full_and_in_order(env, tmp_path, monkeypatch, capsys):
    repo = str(env)
    _git("-C", repo, "remote", "add", "origin", "https://github.com/example/cloneproj.git")
    _git("-C", repo, "remote", "set-url", "--add", "origin", "https://gitlab.com/example/cloneproj.git")
    _git("-C", repo, "remote", "set-url", "--add", "--push", "origin", "git@github.com:example/cloneproj.git")
    _git("-C", repo, "remote", "set-url", "--add", "--push", "origin", "git@gitlab.com:example/cloneproj.git")
    _isolated_identity(monkeypatch, tmp_path)
    assert _create(capsys, repo, "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    assert _cfg(scratch, "--get-all", "remote.origin.url").stdout.splitlines() == [
        "https://github.com/example/cloneproj.git", "https://gitlab.com/example/cloneproj.git"]
    assert _cfg(scratch, "--get-all", "remote.origin.pushurl").stdout.splitlines() == [
        "git@github.com:example/cloneproj.git", "git@gitlab.com:example/cloneproj.git"]


@posix_only
def test_29_the_scratchs_state_dir_is_private_0700_regardless_of_umask(env, tmp_path, monkeypatch, capsys):
    old = os.umask(0o022)
    try:
        _isolated_identity(monkeypatch, tmp_path)
        assert _create(capsys, str(env), "--clone")[0] == 0
    finally:
        os.umask(old)
    assert stat.S_IMODE(os.stat(_clones(tmp_path) / NAME).st_mode) == 0o700


def test_30_a_scratch_dir_that_cannot_be_made_private_fails_the_create(env, tmp_path, monkeypatch, capsys):
    def chmod(path, mode):
        raise PermissionError(1, "operation not permitted", str(path))

    monkeypatch.setattr(msb_clone, "_chmod", chmod)
    seen = _msb_spy(monkeypatch)
    _isolated_identity(monkeypatch, tmp_path)
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and "private scratch dir" in doc["error"]["message"]
    assert not (_clones(tmp_path) / NAME).exists()
    _refute_backend_create(seen)


def test_31_a_failed_origin_carry_fails_the_create_and_removes_the_scratch(env, tmp_path, monkeypatch, capsys):
    _git("-C", str(env), "remote", "add", "origin", "https://github.com/example/cloneproj.git")
    clones = str(_clones(tmp_path))
    _git_spy(monkeypatch, fail=lambda line: 255 if f" -C {clones}" in line and " config " in line else None)
    seen = _msb_spy(monkeypatch)
    _isolated_identity(monkeypatch, tmp_path)
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1
    assert "remote.origin.url" in _message(doc) and "push origin" in _message(doc)
    assert not (_clones(tmp_path) / NAME).exists()
    _refute_backend_create(seen)


def test_32_an_origin_url_with_an_embedded_newline_stays_one_value(env, tmp_path, monkeypatch, capsys):
    url = "https://github.com/example/cloneproj.git\nhttps://evil.example/cloneproj.git"
    _git("-C", str(env), "remote", "add", "origin", "https://placeholder.invalid/x.git")
    _git("-C", str(env), "config", "remote.origin.url", url)
    _isolated_identity(monkeypatch, tmp_path)
    assert _create(capsys, str(env), "--clone")[0] == 0
    values = _cfg(_scratch(tmp_path), "-z", "--get-all", "remote.origin.url").stdout
    assert values.count("\0") == 1 and values == url + "\0"


def test_33_an_unreadable_source_origin_fails_the_create(env, tmp_path, monkeypatch, capsys):
    _git("-C", str(env), "remote", "add", "origin", "https://github.com/example/cloneproj.git")
    _git_spy(monkeypatch, fail=lambda line: 128 if " --get-all remote.origin.url " in line else None)
    seen = _msb_spy(monkeypatch)
    _isolated_identity(monkeypatch, tmp_path)
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and "could not read remote.origin.url" in doc["error"]["message"]
    assert not (_clones(tmp_path) / NAME).exists()
    _refute_backend_create(seen)


def test_34_an_unreadable_or_unwritable_identity_warns_but_does_not_fail(env, tmp_path, monkeypatch, capsys):
    _git("-C", str(env), "config", "user.name", "Repo User")
    clones = str(_clones(tmp_path))

    def fail(line):
        if " --get-all user.email " in line or (f" -C {clones}" in line and " user.name " in line):
            return 128
        return None

    _git_spy(monkeypatch, fail=fail)
    seen = _msb_spy(monkeypatch)
    _isolated_identity(monkeypatch, tmp_path)
    rc, _doc, err = _create(capsys, str(env), "--clone")
    assert rc == 0
    assert "user.name" in err and "user.email" in err and "push origin" not in err
    _create_argv(seen)


def test_35_the_guest_gets_acq_workspace_and_acq_clone_1_via_create_env(env, monkeypatch, capsys):
    seen = _msb_spy(monkeypatch)
    assert _create(capsys, str(env), "--clone")[0] == 0
    argv = _create_argv(seen)
    envs = [argv[i + 1] for i, a in enumerate(argv) if a == "--env"]
    assert f"ACQ_WORKSPACE={_guest(env)}" in envs and "ACQ_CLONE=1" in envs


def test_36_a_non_clone_create_exports_acq_workspace_but_never_acq_clone(env, monkeypatch, capsys):
    seen = _msb_spy(monkeypatch)
    assert _create(capsys, str(env))[0] == 0
    argv = _create_argv(seen)
    assert f"ACQ_WORKSPACE={_guest(env)}" in argv
    assert not any("ACQ_CLONE" in a for a in argv)
    assert "clone" not in state.record_read("msb", NAME)


def test_37_acq_workspace_stays_on_the_clones_mount_root(env, monkeypatch, capsys):
    # The start-directory override must never change the clone mount or marker.
    monkeypatch.setenv("ACQ_MSB_WORKSPACE", "/tmp/elsewhere")
    seen = _msb_spy(monkeypatch)
    assert _create(capsys, str(env), "--clone")[0] == 0
    argv = _create_argv(seen)
    target = [argv[i + 1] for i, a in enumerate(argv) if a == "--volume" and "clones" in argv[i + 1]]
    assert target == [f"{os.path.realpath(_scratch_of(argv))}:{_guest(env)}"]
    assert f"ACQ_WORKSPACE={_guest(env)}" in argv and "ACQ_WORKSPACE=/tmp/elsewhere" not in argv
    assert argv[argv.index("-w") + 1] == "/tmp/elsewhere" and "ACQ_CLONE=1" in argv


def _scratch_of(argv: list[str]) -> str:
    spec = next(argv[i + 1] for i, a in enumerate(argv) if a == "--volume" and "clones" in argv[i + 1])
    return spec.rsplit(":", 1)[0]


def test_38_a_workspace_less_create_exports_neither_marker(env, monkeypatch, capsys):
    # The Python acq always mounts a workspace: a create without one is refused
    # before the backend, so no sandbox without the marker exists.
    seen = _msb_spy(monkeypatch)
    assert _create(capsys, str(env), "--name", "withws")[0] == 0
    assert any(a.startswith("ACQ_WORKSPACE=") for a in _create_argv(seen))
    seen.clear()
    rc, _doc, _err = _create(capsys)
    assert rc == 1
    _refute_backend_create(seen)


def test_39_sbx_the_guest_gets_acq_workspace_and_acq_clone_1_via_create_env(sbx_env, tmp_path, monkeypatch, capsys):
    repo, seen = sbx_env
    link = tmp_path / "linkproj"
    _symlink(repo, link)
    rc, _doc, err = _acq(capsys, "create", "opencode", str(link), "--clone", backend="sbx")
    assert rc == 0, err
    argv = _create_argv(seen)
    assert f"ACQ_WORKSPACE={link}" in argv and f"ACQ_WORKSPACE={os.path.realpath(repo)}" not in argv
    assert "ACQ_CLONE=1" in argv


def test_40_sbx_a_relative_workspace_resolves_against_pwd_to_the_logical_path(sbx_env, tmp_path, monkeypatch,
                                                                               capsys):
    repo, seen = sbx_env
    (tmp_path / "decoy" / "cloneproj").mkdir(parents=True)
    monkeypatch.setenv("CDPATH", str(tmp_path / "decoy"))
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PWD", str(tmp_path))
    rc, _doc, err = _acq(capsys, "create", "opencode", "cloneproj", backend="sbx")
    assert rc == 0, err
    argv = _create_argv(seen)
    assert f"ACQ_WORKSPACE={repo}" in argv
    assert not any("decoy" in a or "ACQ_CLONE" in a for a in argv) and "--clone" not in argv


def test_41_host_side_git_runs_with_no_pager_at_create_and_rm(env, monkeypatch, capsys):
    calls = _git_spy(monkeypatch)
    assert _create(capsys, str(env), "--clone")[0] == 0
    _git("-C", str(env), "update-ref", f"refs/remotes/{REMOTE}/main", "HEAD")
    assert _acq(capsys, "rm", NAME)[0] == 0
    wrapped = calls.wrapped()
    assert any(line.endswith(" update-ref --no-deref --stdin -z") for line in wrapped)
    assert any(line.endswith(f" config --local --remove-section remote.{REMOTE}") for line in wrapped)
    assert wrapped and all(line.startswith("--no-pager ") for line in wrapped)


def test_42_hooks_are_disabled_via_a_never_created_path_in_acqs_state_dir(env, tmp_path, monkeypatch, capsys):
    calls = _git_spy(monkeypatch)
    assert _create(capsys, str(env), "--clone")[0] == 0
    hooks = {argv[argv.index("-c", argv.index("core.fsmonitor=false")) + 1] for argv, _e in calls
             if "protocol.allow=never" in argv}
    assert len(hooks) == 1
    (value,) = hooks
    assert value != "core.hooksPath=/dev/null" and value.startswith("core.hooksPath=")
    path = value.split("=", 1)[1]
    assert Path(path).parent == _state(tmp_path) and not os.path.lexists(path)


def test_43_a_linked_worktree_or_a_gitfile_checkout_is_refused(env, tmp_path, monkeypatch, capsys):
    seen = _msb_spy(monkeypatch)
    _git("-C", str(env), "worktree", "add", "-q", str(tmp_path / "wtproj"))
    rc, doc, _err = _create(capsys, str(tmp_path / "wtproj"), "--clone")
    message = _assert_layout_refused(rc, doc, tmp_path, seen, "shell-wtproj")
    assert ".git is a file pointing at another git directory" in message
    _git("init", "-q", "--separate-git-dir", str(tmp_path / "sep.git"), str(tmp_path / "subproj"))
    _commit(tmp_path / "subproj", "--allow-empty", "-m", "init")
    assert (tmp_path / "subproj" / ".git").is_file()
    rc, doc, _err = _create(capsys, str(tmp_path / "subproj"), "--clone")
    message = _assert_layout_refused(rc, doc, tmp_path, seen, "shell-subproj")
    assert ".git is a file pointing at another git directory" in message


def test_44_a_symlinked_git_a_symlinked_object_store_or_a_commondir_is_refused(env, tmp_path, monkeypatch, capsys):
    seen = _msb_spy(monkeypatch)
    real_git = tmp_path / "real.git"
    (env / ".git").rename(real_git)
    _symlink(real_git, env / ".git")
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert ".git is a symlink" in _assert_layout_refused(rc, doc, tmp_path, seen, NAME)
    os.unlink(env / ".git")
    real_git.rename(env / ".git")

    objects = tmp_path / "objects"
    (env / ".git" / "objects").rename(objects)
    _symlink(objects, env / ".git" / "objects")
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert ".git contains a symlink" in _assert_layout_refused(rc, doc, tmp_path, seen, NAME)
    os.unlink(env / ".git" / "objects")
    objects.rename(env / ".git" / "objects")

    (env / ".git" / "commondir").write_text(".\n", encoding="utf-8")
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert "commondir" in _assert_layout_refused(rc, doc, tmp_path, seen, NAME)


def test_45_an_inherited_git_common_dir_is_cleared_not_followed(env, tmp_path, monkeypatch, capsys):
    other = _mk_repo(tmp_path / "otherrepo")
    before = (other / ".git" / "config").read_text(encoding="utf-8")
    monkeypatch.setenv("GIT_COMMON_DIR", str(other / ".git"))
    rc, _doc, err = _create(capsys, str(env), "--clone")
    assert rc == 0, err
    assert (_scratch(tmp_path) / ".git").is_dir() and _remote_url(env)
    assert (other / ".git" / "config").read_text(encoding="utf-8") == before


def test_46_a_filter_driver_whose_name_contains_equals_is_blanked_too(env, tmp_path, capsys):
    ran = tmp_path / "ran"
    _arm_repo_config(tmp_path, env, ran, "a=b")
    attr = _git("-c", "core.fsmonitor=false", "-C", str(env), "check-attr", "filter", "file.txt").stdout.strip()
    assert attr == "file.txt: filter: a=b"
    rc, _doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 0 and (_scratch(tmp_path) / ".git").is_dir()
    assert not ran.exists()


def test_47_on_git_older_than_2_31_a_filter_name_containing_equals_is_refused(env, tmp_path, monkeypatch, capsys):
    ran = tmp_path / "ran"
    _arm_repo_config(tmp_path, env, ran, "a=b")
    _git_spy(monkeypatch, version="2.30.2")
    seen = _msb_spy(monkeypatch)
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and "contains '='" in _message(doc) and "2.31" in _message(doc)
    _refute_backend_create(seen)
    assert not (_clones(tmp_path) / NAME).exists() and not ran.exists()


def test_48_identity_comes_from_global_includeif_then_repo_local_never_a_repo_local_include(
        env, tmp_path, monkeypatch, capsys):
    home = tmp_path / "idhome"
    home.mkdir()
    repo = os.path.realpath(env).replace("\\", "/")
    (tmp_path / "forge.inc").write_text("[user]\n\tname = Forge User\n\temail = forge@example.gov\n",
                                        encoding="utf-8")
    (home / ".gitconfig").write_text(
        f'[includeIf "gitdir:{repo}/"]\n\tpath = {(tmp_path / "forge.inc").as_posix()}\n', encoding="utf-8")
    (tmp_path / "local.inc").write_text("[user]\n\tname = Local Include\n", encoding="utf-8")
    _git("-C", str(env), "config", "include.path", (tmp_path / "local.inc").as_posix())
    _git("-C", str(env), "config", "user.email", "repo@example.gov")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("USERPROFILE", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "noconfig"))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    assert _cfg(scratch, "user.name").stdout.strip() == "Forge User"
    assert _cfg(scratch, "user.email").stdout.strip() == "repo@example.gov"


def test_49_a_partial_clone_is_refused_before_anything_is_created(env, tmp_path, monkeypatch, capsys):
    _git("-C", str(env), "remote", "add", "origin", "https://example.invalid/cloneproj.git")
    _git("-C", str(env), "config", "remote.origin.promisor", "true")
    seen = _msb_spy(monkeypatch)
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and "partial clone" in doc["error"]["message"]
    _refute_backend_create(seen)
    assert not (_clones(tmp_path) / NAME).exists() and _remote_url(env) is None
    _git("-C", str(env), "config", "--unset", "remote.origin.promisor")
    _git("-C", str(env), "config", "extensions.partialClone", "origin")
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and "partial clone" in doc["error"]["message"]
    assert not (_clones(tmp_path) / NAME).exists()


def test_50_a_git_lfs_workspace_gets_a_notice_to_run_git_lfs_pull_in_the_guest(env, capsys):
    (env / "untracked.txt").write_text("new\n", encoding="utf-8")
    rc, _doc, err = _create(capsys, str(env), "--name", "nolfs", "--clone")
    assert rc == 0 and "uncommitted changes" in err
    assert "git lfs pull" not in err and "may appear modified" not in err
    (env / ".gitattributes").write_text("*.bin filter=lfs diff=lfs merge=lfs -text\n", encoding="utf-8")
    _git("-C", str(env), "add", ".gitattributes")
    _commit(env, "-m", "lfs")
    rc, _doc, err = _create(capsys, str(env), "--name", "withlfs", "--clone")
    assert rc == 0
    for text in ("Git LFS", "If git-lfs is available in the sandbox", "git lfs pull", "uncommitted changes"):
        assert text in err
    # No file is compared with the index, so LFS pointers cannot look modified.
    assert "may appear modified" not in err


def test_51_a_symlink_anywhere_inside_git_except_hooks_is_refused(env, tmp_path, monkeypatch, capsys):
    other = _mk_repo(tmp_path / "otherrepo")
    _git("-C", str(other), "pack-refs", "--all")
    seen = _msb_spy(monkeypatch)
    saved = tmp_path / "saved"
    for rel in ("objects/pack", "refs/heads", "packed-refs"):
        target = env / ".git" / rel
        if target.exists():
            target.rename(saved)
        _symlink(other / ".git" / rel, target)
        rc, doc, _err = _create(capsys, str(env), "--clone")
        assert ".git contains a symlink" in _assert_layout_refused(rc, doc, tmp_path, seen, NAME)
        os.unlink(target)
        if saved.exists():
            saved.rename(target)
    _symlink(tmp_path / "nonexistent-hook", env / ".git" / "hooks" / "pre-commit")
    assert _create(capsys, str(env), "--clone")[0] == 0
    assert (_scratch(tmp_path) / ".git").is_dir()


def test_52_an_existing_hooks_path_dir_or_dangling_symlink_fails_closed(env, tmp_path, monkeypatch, capsys):
    hooks = _state(tmp_path) / ".git-hooks-disabled"
    hooks.mkdir(parents=True)
    seen = _msb_spy(monkeypatch)
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and ".git-hooks-disabled exists" in doc["error"]["message"]
    _refute_backend_create(seen)
    assert not (_clones(tmp_path) / NAME).exists()
    hooks.rmdir()
    _symlink(tmp_path / "nowhere", hooks)
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and ".git-hooks-disabled exists" in doc["error"]["message"]
    assert not (_clones(tmp_path) / NAME).exists()


def test_53_a_relative_acq_state_dir_is_refused_before_any_host_side_git_runs(env, tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("ACQ_STATE_DIR", "relstate")
    calls = _git_spy(monkeypatch)
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and "ACQ_STATE_DIR must be an absolute path" in doc["error"]["message"]
    assert not (tmp_path / "relstate").exists() and calls == []
    assert _remotes(env) == ""
    with pytest.raises(msb.MsbError, match="ACQ_STATE_DIR must be an absolute path"):
        msb_clone.setup(NAME, str(env), lambda _n: False)


def test_54_an_unreadable_workspace_config_is_refused_not_treated_as_filter_free(env, tmp_path, monkeypatch,
                                                                                  capsys):
    _git_spy(monkeypatch, fail=lambda line: 128 if "--get-regexp ^filter" in line else None)
    seen = _msb_spy(monkeypatch)
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and "could not read the git config" in doc["error"]["message"]
    _refute_backend_create(seen)
    assert not (_clones(tmp_path) / NAME).exists()


def test_55_a_user_exported_git_config_count_is_dropped_blanking_starts_at_0(env, tmp_path, monkeypatch, capsys):
    ran = tmp_path / "ran"
    _arm_repo_config(tmp_path, env, ran)
    monkeypatch.setenv("GIT_CONFIG_COUNT", "1")
    monkeypatch.setenv("GIT_CONFIG_KEY_0", "core.abbrev")
    monkeypatch.setenv("GIT_CONFIG_VALUE_0", "12")
    calls = _git_spy(monkeypatch)
    assert _create(capsys, str(env), "--clone")[0] == 0
    assert not ran.exists()
    (clone_env,) = [e for argv, e in calls if "clone" in argv and "--no-hardlinks" in argv]
    assert "core.abbrev" not in clone_env.values()
    assert clone_env["GIT_CONFIG_KEY_0"].startswith("filter.")
    assert {"filter.rec.clean", "filter.rec.smudge", "filter.rec.process"} <= set(clone_env.values())
    kept = [" ".join(argv) for argv, e in calls if "core.abbrev" in e.values()]
    assert kept and all("--show-scope" in line for line in kept)
    assert any(argv[:2] == ["--no-pager", "-C"] and "clones" in argv[2] and "config" in argv for argv, _e in calls)


def test_56_identity_honours_git_config_nosystem_like_git_and_reads_worktree_and_command_scopes(
        env, tmp_path, monkeypatch, capsys):
    sysconf = tmp_path / "sys.gitconfig"
    sysconf.write_text("[user]\n\tname = System User\n\temail = system@example.gov\n", encoding="utf-8")
    _git("-C", str(env), "config", "user.email", "repo@example.gov")
    _git("-C", str(env), "config", "extensions.worktreeConfig", "true")
    _git("-C", str(env), "config", "--worktree", "user.email", "wt@example.gov")
    _isolated_identity(monkeypatch, tmp_path)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", str(sysconf))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "2")
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    assert _cfg(scratch, "user.name").returncode != 0
    assert _cfg(scratch, "user.email").stdout.strip() == "wt@example.gov"
    assert _acq(capsys, "rm", NAME)[0] == 0
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "00")
    monkeypatch.setenv("GIT_CONFIG_COUNT", "1")
    monkeypatch.setenv("GIT_CONFIG_KEY_0", "user.email")
    monkeypatch.setenv("GIT_CONFIG_VALUE_0", "env@example.gov")
    assert _create(capsys, str(env), "--clone")[0] == 0
    assert _cfg(scratch, "user.name").stdout.strip() == "System User"
    assert _cfg(scratch, "user.email").stdout.strip() == "env@example.gov"


@posix_only
@pytest.mark.skipif(POSIX and os.geteuid() == 0, reason="root ignores directory permissions")
def test_57_an_execute_only_git_cannot_hide_a_symlink_from_the_scan(env, tmp_path, monkeypatch, capsys):
    other = _mk_repo(tmp_path / "otherrepo")
    (env / ".git" / "refs" / "heads").rename(tmp_path / "saved")
    _symlink(other / ".git" / "refs" / "heads", env / ".git" / "refs" / "heads")
    seen = _msb_spy(monkeypatch)
    os.chmod(env / ".git", 0o111)
    try:
        rc, doc, _err = _create(capsys, str(env), "--clone")
    finally:
        os.chmod(env / ".git", 0o755)
    assert "could not scan .git" in _assert_layout_refused(rc, doc, tmp_path, seen, NAME)
    os.unlink(env / ".git" / "refs" / "heads")
    (tmp_path / "saved").rename(env / ".git" / "refs" / "heads")
    os.chmod(env / ".git" / "hooks", 0)
    try:
        assert _create(capsys, str(env), "--clone")[0] == 0
    finally:
        os.chmod(env / ".git" / "hooks", 0o755)
    assert (_scratch(tmp_path) / ".git").is_dir()


def test_58_rm_reports_a_wrapper_refusal_instead_of_a_spurious_unfetched_warning(env, tmp_path, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    (_state(tmp_path) / ".git-hooks-disabled").mkdir()
    rc, _doc, err = _acq(capsys, "rm", NAME)
    assert rc == 0
    assert ".git-hooks-disabled exists" in err and "discarding unfetched commits" not in err
    assert "could not check" in err and f"remote remove {REMOTE}" in err
    assert not (_clones(tmp_path) / NAME).exists()


def test_59_create_with_an_inherited_git_dir_clones_the_workspace_and_leaves_that_repo_alone(
        env, tmp_path, monkeypatch, capsys):
    other = _mk_other_repo(tmp_path / "otherrepo")
    _git("-C", str(env), "config", "user.name", "Repo User")
    before = (other / ".git" / "config").read_text(encoding="utf-8")
    _isolated_identity(monkeypatch, tmp_path)
    monkeypatch.setenv("GIT_DIR", str(other / ".git"))
    rc, _doc, err = _create(capsys, str(env), "--clone")
    assert rc == 0, err
    monkeypatch.delenv("GIT_DIR")
    scratch = _scratch(tmp_path)
    head = _git("-C", str(env), "rev-parse", "HEAD").stdout
    assert _git("-C", str(scratch), "rev-parse", "HEAD").stdout == head
    assert not (scratch / "other-only.txt").exists()
    assert os.path.realpath(_remote_url(env) or "") == os.path.realpath(scratch)
    assert (other / ".git" / "config").read_text(encoding="utf-8") == before
    assert _cfg(scratch, "user.name").stdout.strip() == "Repo User"
    assert _remotes(other) == ""


def test_60_an_inherited_git_dir_naming_a_filter_free_repo_leaves_the_workspaces_filters_blanked(
        env, tmp_path, monkeypatch, capsys):
    other = _mk_repo(tmp_path / "cleanrepo")
    ran = tmp_path / "ran"
    _arm_repo_config(tmp_path, env, ran)
    monkeypatch.setenv("GIT_DIR", str(other / ".git"))
    rc, _doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 0 and (_scratch(tmp_path) / ".git").is_dir()
    assert not ran.exists()


def test_61_an_identity_in_an_inherited_git_config_file_is_not_carried(env, tmp_path, monkeypatch, capsys):
    (tmp_path / "env.gitconfig").write_text("[user]\n\tname = Env File User\n", encoding="utf-8")
    _git("-C", str(env), "config", "user.name", "Repo User")
    _isolated_identity(monkeypatch, tmp_path)
    monkeypatch.setenv("GIT_CONFIG", str(tmp_path / "env.gitconfig"))
    rc, _doc, err = _create(capsys, str(env), "--clone")
    assert rc == 0 and "could not read" not in err
    assert _cfg(_scratch(tmp_path), "user.name").stdout.strip() == "Repo User"


def test_62_rm_with_an_inherited_git_dir_removes_the_workspaces_remote_not_that_repos(
        env, tmp_path, monkeypatch, capsys):
    other = _mk_other_repo(tmp_path / "otherrepo")
    _git("-C", str(other), "remote", "add", REMOTE, str(tmp_path / "elsewhere"))
    before = (other / ".git" / "config").read_text(encoding="utf-8")
    assert _create(capsys, str(env), "--clone")[0] == 0
    monkeypatch.setenv("GIT_DIR", str(other / ".git"))
    assert _acq(capsys, "rm", NAME)[0] == 0
    monkeypatch.delenv("GIT_DIR")
    assert (other / ".git" / "config").read_text(encoding="utf-8") == before
    assert not (_clones(tmp_path) / NAME).exists() and _remote_url(env) is None


def test_63_a_hooks_path_injected_through_git_config_parameters_runs_no_hook(env, tmp_path, monkeypatch, capsys):
    hooks = tmp_path / "injected-hooks"
    hooks.mkdir()
    ran = tmp_path / "ran"
    rec = _recorder(tmp_path, ran)
    for hook in ("post-checkout", "reference-transaction", "post-index-change"):
        shutil.copy(rec, hooks / hook)
    assert _create(capsys, str(env), "--clone")[0] == 0
    _agent_commit(_scratch(tmp_path), "agent-work")
    _git("-C", str(env), "fetch", "-q", REMOTE)
    assert _acq(capsys, "rm", NAME)[0] == 0
    monkeypatch.setenv("GIT_CONFIG_PARAMETERS", f"'core.hooksPath'='{hooks.as_posix()}'")
    assert _create(capsys, str(env), "--clone")[0] == 0
    _agent_commit(_scratch(tmp_path), "agent-work-2")
    monkeypatch.delenv("GIT_CONFIG_PARAMETERS")
    _git("-C", str(env), "fetch", "-q", REMOTE)
    monkeypatch.setenv("GIT_CONFIG_PARAMETERS", f"'core.hooksPath'='{hooks.as_posix()}'")
    assert _acq(capsys, "rm", NAME)[0] == 0
    assert not ran.exists()


def test_64_a_filter_driver_injected_through_git_config_parameters_is_not_run(env, tmp_path, monkeypatch, capsys):
    ran = tmp_path / "ran"
    rec = _recorder(tmp_path, ran).as_posix()
    (env / ".git" / "info").mkdir(exist_ok=True)
    (env / ".git" / "info" / "attributes").write_text("* filter=rec\n", encoding="utf-8")
    os.utime(env / "file.txt", (946684800, 946684800))
    monkeypatch.setenv("GIT_CONFIG_PARAMETERS", f"'filter.rec.clean'='{rec}' 'filter.rec.smudge'='{rec}'")
    rc, _doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 0 and (_scratch(tmp_path) / ".git").is_dir()
    assert not ran.exists()


def test_65_host_side_git_refuses_to_run_when_the_isolation_cannot_be_applied(env, tmp_path, monkeypatch):
    # Bash: kit-translate.sh not loaded. Python: the environment it builds still
    # carries a redirect (here a broken git_env), so it refuses to run git.
    other = _mk_repo(tmp_path / "otherrepo")
    before = (other / ".git" / "config").read_text(encoding="utf-8")
    monkeypatch.setenv("GIT_DIR", str(other / ".git"))
    monkeypatch.setattr(gitrepos, "git_env", lambda **_k: dict(os.environ))
    with pytest.raises(msb.MsbError, match="cannot clear the"):
        msb_clone.ws_git(str(env), "remote", "add", "sandbox-x", "/nowhere")
    monkeypatch.delenv("GIT_DIR")
    assert (other / ".git" / "config").read_text(encoding="utf-8") == before
    assert _remotes(env) == ""


# ---------------------------------------------------------------------------
# Python-only behaviour: run, recreate, Bash interop, JSON, Windows seams.
# ---------------------------------------------------------------------------


def test_run_agent_path_clone_creates_on_a_clone_and_reports_it(env, tmp_path, capsys):
    rc, doc, err = _acq(capsys, "run", "shell", str(env), "--clone")
    assert rc == 0, err
    assert doc["data"]["action"] == "created" and doc["data"]["clone"] is True
    assert state.record_read("msb", NAME)["clone"] is True
    assert (_scratch(tmp_path) / ".git").is_dir()


def test_create_json_reports_clone_only_in_clone_mode(env, capsys):
    rc, doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 0 and doc["data"]["clone"] is True
    rc, doc, _err = _create(capsys, str(env), "--name", "plain")
    assert rc == 0 and "clone" not in doc["data"]


def test_run_name_ignores_acq_clone_silently(env, monkeypatch, capsys):
    assert _create(capsys, str(env))[0] == 0
    monkeypatch.setenv("ACQ_CLONE", "1")
    rc, doc, err = _acq(capsys, "run", NAME)
    assert rc == 0 and doc["data"]["action"] == "reattached"
    assert "ACQ_CLONE" not in err


def test_a_failed_kit_apply_removes_the_fresh_scratch(env, tmp_path, monkeypatch, capsys):
    from acq_py import kit_msb

    monkeypatch.setattr(kit_msb, "apply_kit", lambda *a, **k: False)
    rc, _doc, _err = _acq(capsys, "create", "opencode", str(env), "--clone")
    assert rc == 1
    assert not (_clones(tmp_path) / "opencode-cloneproj").exists()
    assert _remote_url(env, "sandbox-opencode-cloneproj") is None


def test_a_create_whose_sandbox_may_survive_keeps_the_scratch(env, tmp_path, monkeypatch, capsys):
    # msb create failed but the listing cannot prove the sandbox gone: the
    # scratch may be its mount source, so it stays for 'acq rm' (as in Bash).
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "create")
    monkeypatch.setattr(msb, "list_names", lambda **_k: None)
    rc, _doc, _err = _create(capsys, str(env), "--clone")
    assert rc == 1 and (_scratch(tmp_path) / ".git").is_dir()


def test_rm_of_an_out_of_band_removed_clone_sandbox_still_cleans_up(env, tmp_path, monkeypatch, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    state.record_remove("msb", NAME)
    catalog = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
    doc = json.loads(catalog.read_text(encoding="utf-8"))
    doc.pop(NAME)
    catalog.write_text(json.dumps(doc), encoding="utf-8")
    from acq_py import kits

    kits.kit_applied_remove("msb", NAME)
    msb.held_forget(NAME)
    rc, out, _err = _acq(capsys, "rm", NAME)
    assert rc == 0 and out["data"]["backend_absent"] is True
    assert not (_clones(tmp_path) / NAME).exists() and _remote_url(env) is None


def _drop_ro_mount(tmp_path: Path, name: str) -> None:
    """Make the stub report ``name`` without its read-only mount, so it qualifies for recreation."""
    mounts = tmp_path / "msb-home" / ".microsandbox" / "mounts.json"
    doc = json.loads(mounts.read_text(encoding="utf-8"))
    doc[name] = []
    mounts.write_text(json.dumps(doc), encoding="utf-8")


@posix_only  # recreation is for the read-only mount, which Windows never requests
def test_recreate_rebuilds_a_clone_sandbox_on_its_existing_scratch(env, tmp_path, monkeypatch, capsys):
    from acq_py import security

    monkeypatch.setattr(security, "WINDOWS", False)
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    _agent_commit(scratch, "agent-work")
    _drop_ro_mount(tmp_path, NAME)
    seen = _msb_spy(monkeypatch)
    rc, doc, err = _acq(capsys, "create", "--recreate", NAME, "--yes", "--clone")
    assert rc == 0, (doc, err)
    assert doc["data"]["recreated"] is True and doc["data"]["clone"] is True
    assert "ignored by 'create --recreate'" in err
    argv = _create_argv(seen)
    assert f"{os.path.realpath(scratch)}:{_guest(env)}" in argv and "ACQ_CLONE=1" in argv
    assert (scratch / "agent-work.txt").exists()
    assert state.record_read("msb", NAME)["clone"] is True


@posix_only
def test_recreate_of_a_bash_created_clone_sandbox_uses_its_scratch(env, tmp_path, monkeypatch, capsys):
    from acq_py import security

    monkeypatch.setattr(security, "WINDOWS", False)
    assert _create(capsys, str(env), "--clone")[0] == 0
    record = state.record_read("msb", NAME)
    record.pop("clone")  # what the migration imports from a Bash record
    state.atomic_write_text(state.record_path("msb", NAME), json.dumps(record))
    _drop_ro_mount(tmp_path, NAME)
    seen = _msb_spy(monkeypatch)
    rc, doc, err = _acq(capsys, "create", "--recreate", NAME, "--yes")
    assert rc == 0, (doc, err)
    assert f"{os.path.realpath(_scratch(tmp_path))}:{_guest(env)}" in _create_argv(seen)
    assert doc["data"]["clone"] is True


@posix_only
def test_recreate_refuses_a_clone_sandbox_whose_scratch_is_gone(env, tmp_path, monkeypatch, capsys):
    from acq_py import security

    monkeypatch.setattr(security, "WINDOWS", False)
    assert _create(capsys, str(env), "--clone")[0] == 0
    shutil.rmtree(_clones(tmp_path) / NAME)
    _drop_ro_mount(tmp_path, NAME)
    removed: list[str] = []
    monkeypatch.setattr(msb, "remove", lambda name: removed.append(name))
    rc, doc, _err = _acq(capsys, "create", "--recreate", NAME, "--yes")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "scratch clone" in doc["error"]["message"] and removed == []


def test_a_python_created_clone_is_found_by_the_bash_layout(env, tmp_path, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    sandbox = _clones(tmp_path) / NAME
    assert (sandbox / ".origin").read_text(encoding="utf-8") == msb_clone.origin_text(os.path.realpath(env)) + "\n"
    assert msb_clone._find_scratch(sandbox) == (_scratch(tmp_path), False)


def test_a_bash_created_clone_is_removed_with_its_remote(env, tmp_path, capsys):
    # The layout Bash's _acq_msb_clone_setup leaves: .origin, the scratch, the remote.
    sandbox = _clones(tmp_path) / NAME
    sandbox.mkdir(parents=True)
    (sandbox / ".origin").write_text(os.path.realpath(env) + "\n", encoding="utf-8")
    _git("clone", "-q", "--no-local", "--no-hardlinks", str(env), str(sandbox / "cloneproj"))
    _git("-C", str(env), "remote", "add", REMOTE, str(sandbox / "cloneproj"))
    _agent_commit(sandbox / "cloneproj", "bash-agent-work")
    assert msb_clone.warn_unfetched(NAME) is True
    assert "unfetched commits" in capsys.readouterr().err
    msb_clone.cleanup(NAME)
    assert not sandbox.exists() and _remote_url(env) is None


def test_bash_windows_origin_forms_read_back_as_native_paths(monkeypatch):
    monkeypatch.setattr(msb_clone, "WINDOWS", True)
    assert msb_clone.origin_from_text("/c/Users/me/proj\n") == "C:\\Users\\me\\proj"
    assert msb_clone.origin_from_text("/unc/server/share/proj\n") == "\\\\server\\share\\proj"
    assert msb_clone.origin_from_text("C:/Users/me/proj\n") == "C:\\Users\\me\\proj"
    assert msb_clone.origin_text("C:\\Users\\me\\proj") == "C:/Users/me/proj"
    monkeypatch.setattr(msb_clone, "WINDOWS", False)
    assert msb_clone.origin_from_text("/c/Users/me/proj\n") == "/c/Users/me/proj"


def test_clones_dir_override_is_honoured_and_refused_when_relative(env, tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("ACQ_MSB_CLONES_DIR", str(tmp_path / "elsewhere"))
    assert _create(capsys, str(env), "--clone")[0] == 0
    assert (tmp_path / "elsewhere" / NAME / "cloneproj" / ".git").is_dir()
    monkeypatch.setenv("ACQ_MSB_CLONES_DIR", "relclones")
    rc, doc, _err = _create(capsys, str(env), "--name", "rel", "--clone")
    assert rc == 1 and "ACQ_MSB_CLONES_DIR must be an absolute path" in doc["error"]["message"]


def test_a_workspace_holding_the_clones_dir_is_refused(env, tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("ACQ_MSB_CLONES_DIR", str(env / "clones"))
    rc, doc, _err = _create(capsys, str(env))
    assert rc == 1 and "scratch clones dir" in doc["error"]["message"]


@posix_only
def test_rm_does_not_block_on_a_fifo_planted_in_the_scratch_refs(env, tmp_path, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    heads = _scratch(tmp_path) / ".git" / "refs" / "heads"
    os.mkfifo(heads / "trap")
    packed = _scratch(tmp_path) / ".git" / "packed-refs"
    packed.unlink(missing_ok=True)
    os.mkfifo(packed)
    import threading

    done: list[object] = []
    reader = threading.Thread(target=lambda: done.append(msb_clone._ref_tips(_scratch(tmp_path))), daemon=True)
    reader.start()
    reader.join(10)
    assert done, "reading the scratch refs blocked on a FIFO"
    assert _acq(capsys, "rm", NAME)[0] == 0
    assert not (_clones(tmp_path) / NAME).exists()


def test_an_oversized_packed_refs_is_treated_as_unverifiable(env, tmp_path, monkeypatch, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    monkeypatch.setattr(msb_clone, "_PACKED_REFS_CAP", 8)
    (_scratch(tmp_path) / ".git" / "packed-refs").write_text("# pack-refs with: peeled\n" * 4, encoding="utf-8")
    assert msb_clone.warn_unfetched(NAME) is True


@pytest.mark.parametrize(("value", "expected"), [
    ("", False), ("0", False), ("00", False), ("false", False), ("No", False), ("OFF", False),
    ("1", True), ("2", True), ("true", True), ("Yes", True), ("on", True), ("1k", True), ("-1", True),
    ("+0", False), ("0g", False), ("bogus", True), ("+", True),
])
def test_git_bool_true_reads_like_git(value, expected):
    assert msb_clone.git_bool_true(value) is expected


def test_wrapped_git_drops_an_inherited_git_allow_protocol(env, monkeypatch):
    monkeypatch.setenv("GIT_ALLOW_PROTOCOL", "ext:file")
    calls = _git_spy(monkeypatch)
    msb_clone.ws_git(str(env), "status")
    assert all("GIT_ALLOW_PROTOCOL" not in e for _argv, e in calls)


def test_the_isolation_list_covers_git_local_env_vars():
    out = _git("rev-parse", "--local-env-vars").stdout.split()
    env = {name: "x" for name in out}
    assert set(gitrepos.redirects_left(env)) == set(out)
    assert gitrepos.redirects_left(gitrepos.git_env()) == []
    assert re.fullmatch(r"[0-9a-f]+", "abc") and not msb_clone.valid_name("a/b")


# ---------------------------------------------------------------------------
# Review regressions: removing a guest-writable tree, recreating a broken
# clone, and the dirty-tree check never running a filter.
# ---------------------------------------------------------------------------


@posix_only
def test_rm_never_chmods_a_host_dir_through_a_guest_symlink(env, tmp_path, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    victim = tmp_path / "victim"
    victim.mkdir()
    os.chmod(victim, 0o755)
    trap = _scratch(tmp_path) / "trap"
    trap.mkdir()
    os.symlink(victim, trap / "link")
    os.chmod(trap, 0o555)  # the unlink of trap/link fails until trap is writable
    locked = _scratch(tmp_path) / "locked"
    (locked / "deep").mkdir(parents=True)
    os.chmod(locked, 0)  # a directory the host cannot even list
    rc, _doc, _err = _acq(capsys, "rm", NAME)
    assert rc == 0
    assert stat.S_IMODE(os.stat(victim).st_mode) == 0o755
    assert not (_clones(tmp_path) / NAME).exists()


def test_removing_a_guest_tree_never_touches_a_link_target(tmp_path):
    outside = tmp_path / "outside.txt"
    outside.write_text("host\n", encoding="utf-8")
    os.chmod(outside, stat.S_IREAD)
    tree = tmp_path / "tree"
    (tree / "sub").mkdir(parents=True)
    (tree / "sub" / "ro.txt").write_text("x", encoding="utf-8")
    os.chmod(tree / "sub" / "ro.txt", stat.S_IREAD)  # git object files are read-only
    _symlink(outside, tree / "sub" / "link")
    msb_clone.remove_guest_tree(tree)
    assert not tree.exists()
    assert outside.read_text(encoding="utf-8") == "host\n"
    assert not os.access(outside, os.W_OK) or (POSIX and os.geteuid() == 0)
    os.chmod(outside, stat.S_IREAD | stat.S_IWRITE)


def test_removing_a_link_in_place_of_the_tree_unlinks_it(tmp_path):
    target = tmp_path / "target"
    target.mkdir()
    (target / "keep.txt").write_text("k", encoding="utf-8")
    _symlink(target, tmp_path / "tree")
    msb_clone.remove_guest_tree(tmp_path / "tree")
    assert not os.path.lexists(tmp_path / "tree") and (target / "keep.txt").exists()


def _keyless_record() -> None:
    record = state.record_read("msb", NAME)
    record.pop("clone")  # what the migration imports from a Bash record
    state.atomic_write_text(state.record_path("msb", NAME), json.dumps(record))


@posix_only
@pytest.mark.parametrize("damage", ["rename-git", "delete-git", "delete-scratch", "other-origin"])
def test_recreate_refuses_a_keyless_clone_sandbox_whose_scratch_the_guest_broke(env, tmp_path, monkeypatch,
                                                                               capsys, damage):
    from acq_py import security

    monkeypatch.setattr(security, "WINDOWS", False)
    assert _create(capsys, str(env), "--clone")[0] == 0
    _keyless_record()
    scratch = _scratch(tmp_path)
    if damage == "rename-git":
        os.rename(scratch / ".git", scratch / ".git-moved")
    elif damage == "delete-git":
        shutil.rmtree(scratch / ".git")
    elif damage == "delete-scratch":
        shutil.rmtree(scratch)
    else:
        other = _mk_repo(tmp_path / "otherrepo")
        (_clones(tmp_path) / NAME / ".origin").write_text(f"{other}\n", encoding="utf-8")
    _drop_ro_mount(tmp_path, NAME)
    seen = _msb_spy(monkeypatch)
    rc, doc, _err = _acq(capsys, "create", "--recreate", NAME, "--yes")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "refusing to rebuild it on the real checkout" in doc["error"]["message"]
    _refute_backend_create(seen)
    assert not [a for a in seen if a[:1] == ["remove"]]


@posix_only
def test_recreate_of_a_keyless_sandbox_with_no_clone_dir_mounts_the_workspace(env, tmp_path, monkeypatch, capsys):
    from acq_py import security

    monkeypatch.setattr(security, "WINDOWS", False)
    assert _create(capsys, str(env))[0] == 0
    _drop_ro_mount(tmp_path, NAME)
    seen = _msb_spy(monkeypatch)
    rc, doc, err = _acq(capsys, "create", "--recreate", NAME, "--yes")
    assert rc == 0, (doc, err)
    assert f"{os.path.realpath(env)}:{_guest(env)}" in _create_argv(seen) and "clone" not in doc["data"]


def test_the_dirty_tree_check_runs_no_filter_even_with_a_stale_filter_list(env, tmp_path, monkeypatch):
    # The driver is defined after the filter list was read: the check must not
    # run it, which a working-tree comparison (git status) of a stat-dirty file would.
    ran = tmp_path / "ran"
    _arm_repo_config(tmp_path, env, ran)
    monkeypatch.setattr(msb_clone, "_filter_settings", lambda ws, hooks: msb_clone._Prep(hooks))
    calls = _git_spy(monkeypatch)
    (env / "untracked.txt").write_text("new\n", encoding="utf-8")
    assert msb_clone._has_uncommitted(str(env)) is True
    assert not ran.exists()
    assert not any(" status" in f" {line}" for line in calls.lines())


def test_a_staged_change_is_reported_and_a_clean_tree_is_not(env):
    assert msb_clone._has_uncommitted(str(env)) is False
    (env / "new.txt").write_text("n\n", encoding="utf-8")
    _git("-C", str(env), "add", "new.txt")
    assert msb_clone._has_uncommitted(str(env)) is True


def test_unfetched_check_does_not_follow_a_linked_git_dir_out_of_the_scratch(env, tmp_path, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    shutil.rmtree(scratch / ".git" / "refs")
    _symlink(env / ".git" / "refs", scratch / ".git" / "refs")
    tips, unverifiable = msb_clone._ref_tips(scratch)
    assert tips == [] and unverifiable is True


# ---------------------------------------------------------------------------
# Second review: a guest taking permissions away inside its scratch must never
# block rm or make recreate fail with a traceback; the remover and the git
# calls are bounded.
# ---------------------------------------------------------------------------

root_ignores_modes = pytest.mark.skipif(POSIX and os.geteuid() == 0, reason="root ignores directory permissions")


@posix_only
@root_ignores_modes
@pytest.mark.parametrize("target", ["", ".git", ".git/refs"], ids=["scratch-root", "git", "git-refs"])
def test_a_guest_chmod_0_never_blocks_rm(env, tmp_path, capsys, target):
    assert _create(capsys, str(env), "--clone")[0] == 0
    victim = _scratch(tmp_path) / target if target else _scratch(tmp_path)
    os.chmod(victim, 0)
    rc, doc, err = _acq(capsys, "rm", NAME)
    assert rc == 0, err
    assert doc["data"]["clone_unfetched"] is True  # unverifiable, so warned
    assert "discarding unfetched commits" in err
    assert not msb.exists(NAME) and not (_clones(tmp_path) / NAME).exists()
    assert _remote_url(env) is None
    assert _acq(capsys, "rm", NAME)[0] == 1  # gone for good: a second rm finds nothing


@posix_only
@root_ignores_modes
@pytest.mark.parametrize("keyed", [True, False], ids=["clone-record", "keyless-record"])
@pytest.mark.parametrize("target", ["", ".git", ".git/refs"], ids=["scratch-root", "git", "git-refs"])
def test_recreate_refuses_cleanly_when_the_guest_made_its_scratch_unreadable(env, tmp_path, monkeypatch, capsys,
                                                                             target, keyed):
    from acq_py import security

    monkeypatch.setattr(security, "WINDOWS", False)
    assert _create(capsys, str(env), "--clone")[0] == 0
    if not keyed:
        _keyless_record()
    victim = _scratch(tmp_path) / target if target else _scratch(tmp_path)
    _drop_ro_mount(tmp_path, NAME)
    seen = _msb_spy(monkeypatch)
    os.chmod(victim, 0)
    try:
        rc, doc, _err = _acq(capsys, "create", "--recreate", NAME, "--yes")
    finally:
        os.chmod(victim, 0o700)
    if target:
        # The scratch is still there and still names the checkout: rebuilding on
        # the guest's own (damaged) scratch keeps the real checkout out of reach.
        assert rc == 0 and f"{os.path.realpath(_scratch(tmp_path))}:{_guest(env)}" in _create_argv(seen)
        return
    assert rc == 1 and "refusing to rebuild it on the real checkout" in doc["error"]["message"]
    _refute_backend_create(seen)


def test_a_failed_unfetched_check_never_blocks_rm(env, tmp_path, monkeypatch, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0

    def broken(_name):
        raise PermissionError(13, "Permission denied", str(_scratch(tmp_path)))

    monkeypatch.setattr(msb_clone, "warn_unfetched", broken)
    rc, _doc, err = _acq(capsys, "rm", NAME)
    assert rc == 0 and "could not check sandbox" in err
    assert not msb.exists(NAME) and not (_clones(tmp_path) / NAME).exists()


@posix_only
@root_ignores_modes
def test_the_remover_gives_up_on_a_directory_it_still_cannot_list(tmp_path, monkeypatch):
    # chmod "succeeds" but the directory stays unlistable: one retry, then stop.
    import threading

    tree = tmp_path / "tree"
    (tree / "locked" / "deep").mkdir(parents=True)
    os.chmod(tree / "locked", 0)
    monkeypatch.setattr(msb_clone, "_fix_dir", lambda _d, _r: os.open(tmp_path, os.O_RDONLY))
    done: list[bool] = []
    worker = threading.Thread(target=lambda: done.append(msb_clone.remove_guest_tree(tree) is None), daemon=True)
    worker.start()
    worker.join(20)
    os.chmod(tree / "locked", 0o700)
    assert done == [True], "the remover kept retrying the same directory"
    assert (tree / "locked").exists()


def test_a_retry_is_attempted_once_per_directory(tmp_path, monkeypatch):
    calls: list[str] = []
    monkeypatch.setattr(msb_clone, "_fix_dir", lambda d, _r: calls.append(d))  # returns None: no fix
    fixed: set[str] = set()
    exc = PermissionError(13, "Permission denied")
    target = str(tmp_path / "d" / "f")
    for _ in range(2):
        with pytest.raises(PermissionError):
            msb_clone._posix_retry(os.unlink, target, exc, str(tmp_path), fixed)
    assert calls == [str(tmp_path / "d")]


@posix_only
def test_a_fifo_gitignore_cannot_hang_the_dirty_check(env, tmp_path, monkeypatch, capsys):
    os.mkfifo(env / ".gitignore")
    monkeypatch.setattr(msb_clone, "GIT_TIMEOUT_S", 2.0)
    monkeypatch.setattr(msb_clone.ws_git, "__defaults__", (False, None, False, 2.0))
    rc, _doc, err = _create(capsys, str(env), "--clone")
    assert rc == 0, err
    assert "could not check the workspace for uncommitted changes" in err and "skipping that note" in err
    assert (_scratch(tmp_path) / ".git").is_dir()


@posix_only  # recreation is for the read-only mount, which Windows never requests
def test_recreate_of_a_clone_sandbox_keeps_ports_as_preferences_and_its_scratch(env, tmp_path, monkeypatch,
                                                                                capsys):
    from acq_py import security
    from acq_py.commands import lifecycle

    monkeypatch.setattr(security, "WINDOWS", False)
    assert _create(capsys, str(env), "--clone")[0] == 0
    _drop_ro_mount(tmp_path, NAME)
    monkeypatch.setattr(lifecycle, "_declared_create_ports", lambda _name: (("6767", 6868),))
    seen: list[dict] = []
    real = lifecycle._msb_create

    def spy(*args, **kwargs):
        seen.append(kwargs)
        return real(*args, **kwargs)

    monkeypatch.setattr(lifecycle, "_msb_create", spy)
    rc, doc, err = _acq(capsys, "create", "--recreate", NAME, "--yes")
    assert rc == 0, (doc, err)
    (call,) = seen
    assert call["preferred"] == {"6767": 6868} and call["overrides"] == ()
    assert call["clone_src"] == os.path.realpath(_scratch(tmp_path))
    assert doc["data"]["clone"] is True


# ---------------------------------------------------------------------------
# Third review: ref tips, bounded read, find_scratch candidate, and Windows
# remover tests.
# ---------------------------------------------------------------------------

@posix_only
@root_ignores_modes
@pytest.mark.parametrize("target", ["loose", "packed"])
def test_unreadable_ref_file_counts_as_unreadable_and_warns(env, tmp_path, capsys, target):
    assert _create(capsys, str(env), "--clone")[0] == 0
    scratch = _scratch(tmp_path)
    if target == "loose":
        ref_file = scratch / ".git" / "refs" / "heads" / "feature"
        ref_file.write_text("0123456789abcdef0123456789abcdef01234567\n")
    else:
        ref_file = scratch / ".git" / "packed-refs"
        ref_file.write_text("# pack-refs with: peeled fully-peeled sorted\n0123456789abcdef0123456789abcdef01234567 refs/heads/feature\n")
    os.chmod(ref_file, 0)
    try:
        _tips, truncated = msb_clone._ref_tips(scratch)
        assert truncated is True
        assert msb_clone.warn_unfetched(NAME) is True
    finally:
        os.chmod(ref_file, 0o600)


@posix_only
def test_read_bounded_refuses_symlink_when_platform_lacks_nofollow(tmp_path, monkeypatch):
    target = tmp_path / "target.txt"
    target.write_text("secret-content")
    link = tmp_path / "link.txt"
    os.symlink(target, link)
    monkeypatch.setattr(msb_clone, "_READ_FLAGS", os.O_RDONLY)
    assert msb_clone._read_bounded(str(link), 1024) is None


@posix_only
@root_ignores_modes
def test_find_scratch_returns_path_when_unreadable_or_linked(env, tmp_path, capsys):
    assert _create(capsys, str(env), "--clone")[0] == 0
    sandbox = _clones(tmp_path) / NAME
    scratch = _scratch(tmp_path)
    os.chmod(scratch, 0)
    try:
        found, unreadable = msb_clone._find_scratch(sandbox)
        assert found == scratch
        assert unreadable is True
        # Verify recorded_scratch never returns the unreadable path as a recreate source
        rec_scratch, matches = msb_clone.recorded_scratch(NAME, str(env))
        assert rec_scratch is None
        assert matches is False
    finally:
        os.chmod(scratch, 0o700)


def test_remove_guest_tree_windows_retries_unreadable_dir(tmp_path, monkeypatch):
    import shutil

    tree = tmp_path / "tree"
    sub = tree / "sub"
    file = sub / "file.txt"
    sub.mkdir(parents=True)
    file.write_text("hello")

    locked = {str(sub)}
    real_scandir = os.scandir
    real_chmod = os.chmod

    def mock_scandir(path):
        if str(path) in locked:
            raise PermissionError(13, "Access is denied", str(path))
        return real_scandir(path)

    def mock_chmod(path, mode):
        locked.discard(str(path))
        return real_chmod(path, mode)

    monkeypatch.setattr(shutil, "_use_fd_functions", False)
    monkeypatch.setattr(msb_clone, "WINDOWS", True)
    monkeypatch.setattr(os, "scandir", mock_scandir)
    monkeypatch.setattr(os, "chmod", mock_chmod)

    msb_clone.remove_guest_tree(tree)
    assert not tree.exists()
