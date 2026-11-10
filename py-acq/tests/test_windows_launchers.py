"""acq.cmd and acq.ps1 forward argv and select an implementation as documented.

ADR-0047m promises that the Windows launchers forward argv verbatim and fail
closed (exit 2) on any ACQ_IMPL other than ``bash`` or ``python``, compared as
the Bash ``acq`` compares it. These tests copy the launchers into a scratch
tree beside a fake ``acq_py`` package (and a fake Bash ``acq``) that report the
argv they received, then run them the ways users do: ``acq.cmd`` (which starts
Windows PowerShell 5.1 with ``-File``) and ``acq.ps1`` under PowerShell.

Windows PowerShell 5.1's call operator drops an empty argument and leaves an
embedded double quote unescaped when it starts a native program. Through
``acq.cmd`` the Python branch avoids it with an exact command line; the Bash
branch still uses it, so it refuses such an argument instead of running a
changed command.

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
print(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd()}))
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
    result = _run(via(launcher_tree, ["exec", "box", "--", "echo", unsafe]), _env(None), tmp_path)
    assert result.returncode == 2, (result.stdout, result.stderr)
    assert "ACQ_IMPL=python" in result.stderr
    assert "[exec]" not in result.stdout


def test_bash_branch_forwards_plain_arguments(launcher_tree: Path, tmp_path: Path) -> None:
    if _git_bash() is None:
        pytest.skip("Git for Windows is not installed")
    # A regression guard for the refusal above: ordinary arguments still pass.
    args = ["exec", "box", "--", "echo", "--json", "a b"]
    result = _run(_via_cmd(launcher_tree, args), _env(None), tmp_path)
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [f"[{a}]" for a in args]
