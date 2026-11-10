"""acq.cmd and acq.ps1 forward argv and select an implementation as documented.

ADR-0047m promises that the Windows launchers forward argv verbatim and fail
closed (exit 2) on any ACQ_IMPL other than ``bash`` or ``python``, compared as
the Bash ``acq`` compares it. ADR-0048m makes an unset ACQ_IMPL mean ``python``
on Windows, with a fixed interpreter order (an absolute ``ACQ_RUNTIME``, the
managed ``py-acq\\runtime\\python.exe``, then a drive-rooted or UNC ``PATH``
entry that passes an isolated 3.12+ probe), ``-P``, and a fail-closed error
that never falls back to Bash. These tests copy the launchers into a scratch
tree beside a fake ``acq_py`` package (and a fake Bash ``acq``) that report the
argv and interpreter they received, then run them the ways users do:
``acq.cmd`` (which starts Windows PowerShell 5.1 with ``-File``) and
``acq.ps1`` under PowerShell.

A real interpreter stands in for the managed runtime and for relative ``PATH``
entries through directory junctions to the running Python's base install
(``sys.base_prefix``), so each candidate would pass the probe if the launcher
considered it. The junctions are removed (the links only, never their targets)
when each test ends.

Windows PowerShell 5.1's call operator drops an empty argument and leaves an
embedded double quote unescaped when it starts a native program. Through
``acq.cmd`` the Python branch avoids it with an exact command line; the Bash
branch still uses it, so it refuses such an argument instead of running a
changed command.

PowerShell 7 fills ``$args`` from ``pwsh -File`` verbatim, and from 7.3 its
call operator passes native arguments correctly by default
(``$PSNativeCommandArgumentPassing`` is ``Windows``), so there acq.ps1 forwards
an empty argument, an embedded quote, a trailing backslash and ``--``
unchanged on both branches. The PowerShell 7 cases find ``pwsh`` on PATH (or
the absolute path in ``ACQ_TEST_PWSH``) and skip without it, unless
``ACQ_TEST_REQUIRE_PWSH=1`` (set in CI) makes a missing ``pwsh`` a failure; an
``ACQ_TEST_PWSH`` that does not name a usable pwsh fails them too.

Windows only: they need cmd.exe and Windows PowerShell, so they run in the
Windows CI job's pytest step.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.skipif(
    sys.platform != "win32", reason="runs acq.cmd and acq.ps1, which need cmd.exe and Windows PowerShell"
)

FAKE_MAIN = """\
import json, os, sys
print(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd(), "pythonpath": os.environ.get("PYTHONPATH"),
                  "executable": sys.executable, "orig_argv": sys.orig_argv, "safe_path": bool(sys.flags.safe_path)}))
sys.exit(int(os.environ.get("ACQ_FAKE_EXIT", "0")))
"""

# The Bash branch runs `bash <dir>/acq ARGS`; print one bracketed line per arg.
FAKE_BASH_ACQ = '#!/usr/bin/env bash\nfor a in "$@"; do printf \'[%s]\\n\' "$a"; done\n'

# What a user would type after `acq`, including the pieces Windows PowerShell
# 5.1's call operator used to lose or change on the way to Python: an empty
# argument, an embedded double quote and a trailing backslash inside a quoted
# argument (a backslash run before the closing quote).
ARGV = ["exec", "box", "--", "echo", "--json", "", "a b", 'say "hi"', "C:\\dir with space\\", "--"]


def _windows_powershell() -> str:
    return os.path.join(os.environ["SystemRoot"], "System32", "WindowsPowerShell", "v1.0", "powershell.exe")


def _find_pwsh(override: str) -> str | None:
    if override:
        return override if os.path.isabs(override) and os.path.isfile(override) else None
    return shutil.which("pwsh")


@pytest.fixture(scope="module")
def pwsh(pwsh_test_settings: tuple[str, bool]) -> tuple[str, tuple[int, int]]:
    """``(path, (major, minor))`` of PowerShell 7 or newer; skips without it.

    An explicit ``ACQ_TEST_PWSH`` is a request to run these tests, so one that
    is not usable fails them, as ``ACQ_TEST_REQUIRE_PWSH=1`` does."""
    override, required = pwsh_test_settings
    required = required or bool(override)
    path = _find_pwsh(override)
    version: tuple[int, int] | None = None
    if path is not None:
        probe = subprocess.run(
            [path, "-NoProfile", "-NonInteractive", "-Command",
             "'{0} {1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor"],
            capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120,
        )
        fields = probe.stdout.split()
        if probe.returncode == 0 and len(fields) == 2 and all(f.isdigit() for f in fields):
            version = (int(fields[0]), int(fields[1]))
    if version is None or version < (7, 0):
        if required:
            pytest.fail(f"PowerShell 7 is required here but was not usable (found {path!r}, version {version})")
        pytest.skip("PowerShell 7 (pwsh) is not installed")
    assert path is not None and version is not None
    return path, version


def _needs_standard_native_arguments(pwsh: tuple[str, tuple[int, int]]) -> str:
    """The pwsh path, skipping before 7.3 (the legacy call operator)."""
    path, version = pwsh
    if version < (7, 3):
        pytest.skip(f"PowerShell {version[0]}.{version[1]} passes native arguments the legacy way")
    return path


def _git_bash() -> Path | None:
    for base in (os.environ.get("ProgramFiles"), os.environ.get("ProgramFiles(x86)")):
        if base:
            candidate = Path(base) / "Git" / "bin" / "bash.exe"
            if candidate.is_file():
                return candidate
    return None


@pytest.fixture
def launcher_tree(tmp_path: Path) -> Path:
    # realpath: the launchers compare the script path acq.cmd passed with the
    # one PowerShell reports, so keep 8.3 short names out of the scratch path.
    root = Path(os.path.realpath(tmp_path)) / "acq-launchers"
    package = root / "py-acq" / "src" / "acq_py"
    package.mkdir(parents=True)
    for name in ("acq.cmd", "acq.ps1"):
        shutil.copyfile(REPO_ROOT / name, root / name)
    (package / "__init__.py").write_bytes(b"")
    (package / "__main__.py").write_bytes(FAKE_MAIN.encode())
    (root / "acq").write_bytes(FAKE_BASH_ACQ.encode())
    return root


def _env(impl: str | None, **extra: str) -> dict[str, str]:
    env = dict(os.environ)
    env.pop("ACQ_IMPL", None)
    env.pop("PYTHONPATH", None)
    if impl is not None:
        env["ACQ_IMPL"] = impl
    # The venv's python.exe is absolute and 3.12+, which is all acq.ps1 checks.
    env["ACQ_RUNTIME"] = sys.executable
    env.update(extra)
    return env


def _run(command: list[str], env: dict[str, str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command, env=env, cwd=cwd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=180
    )


def _via_cmd(tree: Path, args: list[str]) -> list[str]:
    return [str(tree / "acq.cmd"), *args]


def _via_ps1(tree: Path, args: list[str]) -> list[str]:
    # Not acq.cmd's argument shape, so acq.ps1 takes its arguments from $args.
    return [_windows_powershell(), "-NoProfile", "-NonInteractive", "-File", str(tree / "acq.ps1"), *args]


def _same_dir(a: str, b: Path) -> bool:
    return os.path.normcase(os.path.realpath(a)) == os.path.normcase(os.path.realpath(b))


def test_acq_cmd_forwards_argv_verbatim_to_python(launcher_tree: Path, tmp_path: Path) -> None:
    work = tmp_path / "work dir"
    work.mkdir()
    result = _run(_via_cmd(launcher_tree, ARGV), _env("python"), work)
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["argv"] == ARGV
    assert _same_dir(report["cwd"], work)


def test_acq_cmd_forwards_no_arguments_and_the_exit_status(launcher_tree: Path, tmp_path: Path) -> None:
    result = _run(_via_cmd(launcher_tree, []), _env("python", ACQ_FAKE_EXIT="7"), tmp_path)
    assert result.returncode == 7, result.stderr
    assert json.loads(result.stdout)["argv"] == []


def test_acq_ps1_started_otherwise_forwards_its_args(launcher_tree: Path, tmp_path: Path) -> None:
    result = _run(_via_ps1(launcher_tree, ["version", "--json", "a b"]), _env("python"), tmp_path)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["argv"] == ["version", "--json", "a b"]


@pytest.mark.parametrize("impl", ["PYTHON", "Python", "BASH", "Bash"])
@pytest.mark.parametrize("via", [_via_cmd, _via_ps1], ids=["acq.cmd", "acq.ps1"])
def test_acq_impl_is_compared_case_sensitively(launcher_tree: Path, tmp_path: Path, impl: str, via) -> None:
    result = _run(via(launcher_tree, ["version"]), _env(impl), tmp_path)
    assert result.returncode == 2, (result.stdout, result.stderr)
    assert f"unsupported ACQ_IMPL '{impl}'" in result.stderr
    assert '"argv"' not in result.stdout and "[version]" not in result.stdout


# Through acq.cmd the arguments come from the process argv, so both cases are
# certain to reach the check; acq.ps1 started otherwise sees PowerShell's $args.
@pytest.mark.parametrize(
    ("via", "unsafe"),
    [(_via_cmd, ""), (_via_cmd, 'say "hi"'), (_via_ps1, 'say "hi"')],
    ids=["acq.cmd-empty", "acq.cmd-quote", "acq.ps1-quote"],
)
def test_bash_branch_refuses_an_argument_powershell_would_change(
    launcher_tree: Path, tmp_path: Path, unsafe: str, via
) -> None:
    if _git_bash() is None:
        pytest.skip("Git for Windows is not installed")
    result = _run(via(launcher_tree, ["exec", "box", "--", "echo", unsafe]), _env("bash"), tmp_path)
    assert result.returncode == 2, (result.stdout, result.stderr)
    assert "ACQ_IMPL=python" in result.stderr
    assert "[exec]" not in result.stdout


def test_bash_branch_forwards_plain_arguments(launcher_tree: Path, tmp_path: Path) -> None:
    if _git_bash() is None:
        pytest.skip("Git for Windows is not installed")
    # A regression guard for the refusal above: ordinary arguments still pass.
    args = ["exec", "box", "--", "echo", "--json", "a b"]
    result = _run(_via_cmd(launcher_tree, args), _env("bash"), tmp_path)
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [f"[{a}]" for a in args]


# ---- ACQ_IMPL unset: the Python implementation by default (ADR-0048m) ----------

FAIL_CLOSED = "no Python 3.12 or newer was found to run acq"


def _system_path() -> list[str]:
    """PATH entries that hold no python.exe but keep Windows' own tools reachable."""
    root = os.environ["SystemRoot"]
    return [os.path.join(root, "System32"), root]


def _default_env(path: list[str] | None = None, **extra: str) -> dict[str, str]:
    """ACQ_IMPL and ACQ_RUNTIME unset; ``path`` (plus Windows' own directories)
    replaces PATH when given."""
    env = _env(None, **extra)
    if "ACQ_RUNTIME" not in extra:
        env.pop("ACQ_RUNTIME", None)
    if path is not None:
        env["PATH"] = ";".join([*path, *_system_path()])
    return env


def _same_exe(a: str, b: Path) -> bool:
    # Compared without resolving links: a junction path must stay as launched.
    return os.path.normcase(os.path.abspath(a)) == os.path.normcase(os.path.abspath(b))


@pytest.fixture
def base_python() -> Path:
    """The directory of the running Python's base install, whose python.exe is a
    real 3.12+ interpreter that honours PYTHONPATH (no ._pth file)."""
    base = Path(sys.base_prefix)
    if not (base / "python.exe").is_file():
        pytest.skip(f"no python.exe in the base install {base}")
    if any(base.glob("python*._pth")):
        pytest.skip(f"the base install {base} is an embedded layout that ignores PYTHONPATH")
    return base


@pytest.fixture
def junction():
    """``make(link, target)`` creates a directory junction; each one is removed
    with os.rmdir afterwards, which deletes the link and leaves the target alone."""
    made: list[Path] = []
    cmd = os.path.join(os.environ["SystemRoot"], "System32", "cmd.exe")

    def make(link: Path, target: Path) -> Path:
        subprocess.run([cmd, "/d", "/c", "mklink", "/J", str(link), str(target)],
                       check=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=60)
        made.append(link)
        return link

    yield make
    for link in reversed(made):
        os.rmdir(link)


@pytest.fixture
def failing_python(tmp_path: Path) -> Path:
    """A directory whose python.exe starts but fails the launcher's probe, as the
    App Execution Alias stub does (it prints a Store hint and exits 9009). It is a
    copy of whoami.exe, which rejects the probe's ``-I`` with a non-zero exit."""
    stub = tmp_path / "stub dir"
    stub.mkdir()
    shutil.copyfile(os.path.join(os.environ["SystemRoot"], "System32", "whoami.exe"), stub / "python.exe")
    probe = subprocess.run([str(stub / "python.exe"), "-I", "-c", "import sys"],
                           capture_output=True, stdin=subprocess.DEVNULL, timeout=60)
    assert probe.returncode != 0, "the stand-in stub unexpectedly passed the probe"
    return stub


def _assert_python_ran(report: dict, exe: Path, argv: list[str]) -> None:
    assert _same_exe(report["executable"], exe), report
    assert report["argv"] == argv
    # Safe-path mode, as `python.exe -P -m acq_py ARGS`.
    assert report["safe_path"] is True
    assert report["orig_argv"][1:4] == ["-P", "-m", "acq_py"], report["orig_argv"]


def _assert_failed_closed(result: subprocess.CompletedProcess[str]) -> None:
    assert result.returncode == 1, (result.stdout, result.stderr)
    assert FAIL_CLOSED in result.stderr
    for remedy in ("Install acq from a release", "Python 3.12+", "ACQ_RUNTIME", "ACQ_IMPL=bash"):
        assert remedy in result.stderr, remedy
    # Neither the Python fake nor the Bash fake ran: no fallback to Bash.
    assert '"argv"' not in result.stdout and "[version]" not in result.stdout


@pytest.mark.parametrize("impl", [None, ""], ids=["unset", "empty"])
@pytest.mark.parametrize("via", [_via_cmd, _via_ps1], ids=["acq.cmd", "acq.ps1"])
def test_default_runs_the_managed_runtime_with_safe_path(
    launcher_tree: Path, tmp_path: Path, base_python: Path, junction, impl: str | None, via
) -> None:
    runtime = junction(launcher_tree / "py-acq" / "runtime", base_python)
    extra = {} if impl is None else {"ACQ_IMPL": impl}
    # The caller's PATH stays as it is: the managed runtime wins over it.
    result = _run(via(launcher_tree, ["version", "a b"]), _default_env(**extra), tmp_path)
    assert result.returncode == 0, result.stderr
    _assert_python_ran(json.loads(result.stdout), runtime / "python.exe", ["version", "a b"])


@pytest.mark.parametrize("via", [_via_cmd, _via_ps1], ids=["acq.cmd", "acq.ps1"])
def test_default_honours_an_absolute_acq_runtime(
    launcher_tree: Path, tmp_path: Path, base_python: Path, via
) -> None:
    exe = base_python / "python.exe"
    # No managed runtime and nothing on PATH: only ACQ_RUNTIME can supply one.
    env = _default_env([], ACQ_RUNTIME=str(exe))
    result = _run(via(launcher_tree, ["version"]), env, tmp_path)
    assert result.returncode == 0, result.stderr
    _assert_python_ran(json.loads(result.stdout), exe, ["version"])


@pytest.mark.parametrize("via", [_via_cmd, _via_ps1], ids=["acq.cmd", "acq.ps1"])
def test_default_refuses_a_relative_acq_runtime(
    launcher_tree: Path, tmp_path: Path, base_python: Path, junction, via
) -> None:
    work = tmp_path / "work"
    work.mkdir()
    # The relative value names a real interpreter from the working directory.
    junction(work / "py", base_python)
    env = _default_env([], ACQ_RUNTIME="py\\python.exe")
    result = _run(via(launcher_tree, ["version"]), env, work)
    assert result.returncode == 1, (result.stdout, result.stderr)
    assert "ACQ_RUNTIME must be an absolute path to python.exe, got 'py\\python.exe'" in result.stderr
    assert '"argv"' not in result.stdout


@pytest.mark.parametrize("via", [_via_cmd, _via_ps1], ids=["acq.cmd", "acq.ps1"])
def test_default_skips_a_python_that_fails_the_probe(
    launcher_tree: Path, tmp_path: Path, base_python: Path, failing_python: Path, via
) -> None:
    result = _run(via(launcher_tree, ["version"]), _default_env([str(failing_python), str(base_python)]), tmp_path)
    assert result.returncode == 0, result.stderr
    _assert_python_ran(json.loads(result.stdout), base_python / "python.exe", ["version"])


def test_default_skips_the_app_execution_alias_stub(launcher_tree: Path, tmp_path: Path) -> None:
    apps = Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WindowsApps"
    stub = apps / "python.exe"
    if not os.path.isabs(apps) or not os.path.lexists(stub):
        pytest.skip("no App Execution Alias for python.exe on this host")
    probe = subprocess.run([str(stub), "-I", "-c", "import sys"], capture_output=True,
                           stdin=subprocess.DEVNULL, timeout=60)
    if probe.returncode == 0:
        pytest.skip("python.exe in WindowsApps is a real Store-installed Python, not the stub")
    _assert_failed_closed(_run(_via_cmd(launcher_tree, ["version"]), _default_env([str(apps)]), tmp_path))


@pytest.mark.parametrize("entry", [".", "rel", ".\\rel", "rel\\"])
def test_default_never_selects_a_relative_path_entry(
    launcher_tree: Path, tmp_path: Path, base_python: Path, junction, failing_python: Path, entry: str
) -> None:
    # Each relative entry resolves, from the working directory, to a directory
    # holding a real interpreter that would pass the probe.
    if entry == ".":
        work = junction(tmp_path / "work", base_python)
    else:
        work = tmp_path / "work"
        work.mkdir()
        junction(work / "rel", base_python)
    env = _default_env([entry, str(failing_python)])
    _assert_failed_closed(_run(_via_cmd(launcher_tree, ["version"]), env, work))


@pytest.mark.parametrize("via", [_via_cmd, _via_ps1], ids=["acq.cmd", "acq.ps1"])
def test_default_fails_closed_without_falling_back_to_bash(
    launcher_tree: Path, tmp_path: Path, failing_python: Path, via
) -> None:
    # The fake Bash acq is in the tree, and Git Bash may be installed; neither
    # is used when no interpreter qualifies.
    result = _run(via(launcher_tree, ["version"]), _default_env([str(failing_python)]), tmp_path)
    _assert_failed_closed(result)


@pytest.mark.parametrize("impl", ["bogus", "pyhton", "sh"])
@pytest.mark.parametrize("via", [_via_cmd, _via_ps1], ids=["acq.cmd", "acq.ps1"])
def test_unknown_acq_impl_exits_2(launcher_tree: Path, tmp_path: Path, impl: str, via) -> None:
    result = _run(via(launcher_tree, ["version"]), _env(impl), tmp_path)
    assert result.returncode == 2, (result.stdout, result.stderr)
    assert f"unsupported ACQ_IMPL '{impl}'" in result.stderr
    assert '"argv"' not in result.stdout and "[version]" not in result.stdout


# ---- acq.ps1 run inside the caller's PowerShell session ------------------------

# Run as `& .\acq.ps1` from a prompt, acq.ps1 shares the session's environment.
# The variables it sets for the programs it starts must not outlive the call.
SESSION_VARS = ("NoDefaultCurrentDirectoryInExePath", "PYTHONPATH", "ACQ_PROVIDER_INPUT_DATA_DIR")


def _in_session(tree: Path, args: list[str], before: dict[str, str | None], catch: bool = False,
                shell: str | None = None, prelude: str | None = None) -> list[str]:
    """powershell.exe -Command that sets ``before``, runs acq.ps1 in-process, and
    prints ``AFTER <json>`` with the exit status and the variables afterwards.

    With ``catch``, the call runs inside try/catch, as a prompt carries on after
    an error, and a thrown error is printed as ``CAUGHT <message>``. ``shell``
    replaces Windows PowerShell (with ``pwsh``, say), and ``prelude`` is a
    PowerShell statement run first."""

    def quote(value: str) -> str:
        return "'" + value.replace("'", "''") + "'"

    lines = [prelude] if prelude else []
    for name, value in before.items():
        if value is None:
            lines.append(f"Remove-Item Env:{name} -ErrorAction SilentlyContinue")
        else:
            lines.append(f"$env:{name} = {quote(value)}")
    call = "& " + " ".join(quote(a) for a in [str(tree / "acq.ps1"), *args])
    if catch:
        call = "try { " + call + " } catch { Write-Output ('CAUGHT ' + $_.Exception.Message) }"
    lines.append(call)
    lines.append("$after = @{ code = $LASTEXITCODE }")
    for name in SESSION_VARS:
        lines.append(f"$after['{name}'] = $env:{name}")
    lines.append("Write-Output ('AFTER ' + (ConvertTo-Json -Compress $after))")
    return [shell or _windows_powershell(), "-NoProfile", "-NonInteractive", "-Command", "; ".join(lines)]


def _after(stdout: str) -> dict:
    line = next(x for x in stdout.splitlines() if x.startswith("AFTER "))
    return json.loads(line[len("AFTER "):])


BEFORE = {"NoDefaultCurrentDirectoryInExePath": None, "PYTHONPATH": "C:\\user\\keep", "ACQ_PROVIDER_INPUT_DATA_DIR": None}


def test_acq_ps1_in_session_restores_the_variables_it_set_for_python(launcher_tree: Path, tmp_path: Path) -> None:
    result = _run(_in_session(launcher_tree, ["version", "a b"], BEFORE), _env("python", ACQ_FAKE_EXIT="5"), tmp_path)
    child = json.loads(result.stdout.splitlines()[0])
    assert child["argv"] == ["version", "a b"]
    # The child got the fixed PYTHONPATH; the session gets its own value back.
    assert _same_dir(child["pythonpath"], launcher_tree / "py-acq" / "src")
    after = _after(result.stdout)
    assert after["code"] == 5, result.stderr
    assert after["PYTHONPATH"] == "C:\\user\\keep"
    assert after["NoDefaultCurrentDirectoryInExePath"] is None
    assert after["ACQ_PROVIDER_INPUT_DATA_DIR"] is None


def test_acq_ps1_in_session_restores_the_variables_when_it_refuses(launcher_tree: Path, tmp_path: Path) -> None:
    before = {**BEFORE, "NoDefaultCurrentDirectoryInExePath": "0"}
    result = _run(_in_session(launcher_tree, ["version"], before), _env("bogus"), tmp_path)
    after = _after(result.stdout)
    assert after["code"] == 2, result.stderr
    assert after["NoDefaultCurrentDirectoryInExePath"] == "0"
    assert after["PYTHONPATH"] == "C:\\user\\keep"


# acq.ps1 throws (rather than exits) when it cannot go on, for example when the
# Bash entry point beside it is missing. Started with -File that is exit 1 with
# the message on stderr; run in a session, the error reaches the caller and the
# variables acq.ps1 set before it threw are still put back.
def test_acq_ps1_thrown_error_exits_1_with_its_message(launcher_tree: Path, tmp_path: Path) -> None:
    (launcher_tree / "acq").unlink()
    result = _run(_via_ps1(launcher_tree, ["version"]), _env("bash"), tmp_path)
    assert result.returncode == 1, (result.stdout, result.stderr)
    assert "Expected acq Bash entry point at" in result.stderr
    assert "[version]" not in result.stdout


def test_acq_ps1_in_session_restores_the_variables_when_it_throws(launcher_tree: Path, tmp_path: Path) -> None:
    (launcher_tree / "acq").unlink()
    before = {**BEFORE, "NoDefaultCurrentDirectoryInExePath": "0"}
    result = _run(_in_session(launcher_tree, ["version"], before, catch=True), _env("bash"), tmp_path)
    caught = [x for x in result.stdout.splitlines() if x.startswith("CAUGHT ")]
    assert caught and "Expected acq Bash entry point at" in caught[0], (result.stdout, result.stderr)
    after = _after(result.stdout)
    # acq.ps1 set it to "1" before throwing; the session gets its "0" back.
    assert after["NoDefaultCurrentDirectoryInExePath"] == "0"
    assert after["PYTHONPATH"] == "C:\\user\\keep"
    assert after["ACQ_PROVIDER_INPUT_DATA_DIR"] is None


def test_acq_ps1_in_session_restores_the_variables_it_set_for_bash(launcher_tree: Path, tmp_path: Path) -> None:
    if _git_bash() is None:
        pytest.skip("Git for Windows is not installed")
    local = tmp_path / "local"
    (local / "acq" / "provider-input-validator").mkdir(parents=True)
    result = _run(_in_session(launcher_tree, ["version"], BEFORE), _env("bash", LOCALAPPDATA=str(local)), tmp_path)
    assert "[version]" in result.stdout.splitlines()
    after = _after(result.stdout)
    assert after["code"] == 0, result.stderr
    assert after["ACQ_PROVIDER_INPUT_DATA_DIR"] is None
    assert after["NoDefaultCurrentDirectoryInExePath"] is None
    assert after["PYTHONPATH"] == "C:\\user\\keep"


# ---- PowerShell 7 ---------------------------------------------------------------

def _bash_view(args: list[str]) -> list[str]:
    """What the fake Bash acq prints for ``args`` after acq.ps1's path conversion."""
    converted = {"C:\\dir with space\\": "/c/dir with space/"}
    return [f"[{converted.get(a, a)}]" for a in args]


# `pwsh -NoProfile -NonInteractive -File` reaches acq.ps1 through $args;
# `pwsh -NoLogo -NoProfile -File` is acq.cmd's shape, so acq.ps1 reads the
# process argv instead and starts Python with an exact command line.
PWSH_FILE_SHAPES = {
    "args": ["-NoProfile", "-NonInteractive", "-File"],
    "launcher-shape": ["-NoLogo", "-NoProfile", "-File"],
}


@pytest.mark.parametrize("shape", list(PWSH_FILE_SHAPES))
def test_acq_ps1_under_pwsh_file_forwards_argv_verbatim_to_python(
    launcher_tree: Path, tmp_path: Path, pwsh, shape: str
) -> None:
    path = _needs_standard_native_arguments(pwsh) if shape == "args" else pwsh[0]
    command = [path, *PWSH_FILE_SHAPES[shape], str(launcher_tree / "acq.ps1"), *ARGV]
    result = _run(command, _env("python", ACQ_FAKE_EXIT="3"), tmp_path)
    assert result.returncode == 3, result.stderr
    assert json.loads(result.stdout)["argv"] == ARGV


def test_acq_ps1_in_a_pwsh_session_forwards_native_arguments_verbatim(
    launcher_tree: Path, tmp_path: Path, pwsh
) -> None:
    # Typed at a pwsh prompt every argument is a quoted literal, '--' included.
    shell = _needs_standard_native_arguments(pwsh)
    result = _run(_in_session(launcher_tree, ARGV, BEFORE, shell=shell), _env("python"), tmp_path)
    assert json.loads(result.stdout.splitlines()[0])["argv"] == ARGV, result.stderr
    after = _after(result.stdout)
    assert after["code"] == 0
    assert after["PYTHONPATH"] == "C:\\user\\keep"


@pytest.mark.parametrize("shape", list(PWSH_FILE_SHAPES))
def test_bash_branch_under_pwsh_forwards_empty_and_quoted_arguments(
    launcher_tree: Path, tmp_path: Path, pwsh, shape: str
) -> None:
    if _git_bash() is None:
        pytest.skip("Git for Windows is not installed")
    path = _needs_standard_native_arguments(pwsh)
    command = [path, *PWSH_FILE_SHAPES[shape], str(launcher_tree / "acq.ps1"), *ARGV]
    result = _run(command, _env("bash"), tmp_path)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert result.stdout.splitlines() == _bash_view(ARGV)


def test_bash_branch_under_pwsh_with_legacy_argument_passing_still_refuses(
    launcher_tree: Path, tmp_path: Path, pwsh
) -> None:
    if _git_bash() is None:
        pytest.skip("Git for Windows is not installed")
    command = _in_session(launcher_tree, ["exec", "box", "--", "echo", ""], BEFORE, shell=pwsh[0],
                          prelude="$PSNativeCommandArgumentPassing = 'Legacy'")
    result = _run(command, _env("bash"), tmp_path)
    assert _after(result.stdout)["code"] == 2, (result.stdout, result.stderr)
    assert "ACQ_IMPL=python" in result.stderr
    assert "[exec]" not in result.stdout
