"""Tier-2 implementation tests for the ACQ_IMPL coexistence switch (ADR-0047m).

These drive the repo-root Bash ``acq`` dispatcher as a subprocess to prove the
runtime switch end to end: unset/``bash`` runs the Bash body, ``python`` execs
the Python implementation, and an unknown value fails closed. They are
non-contract evidence (ADR-0039m); the Tier-1 oracles live under
``test/vectors/coexistence`` and run through both the pytest and Bash runners.

Skipped where a usable ``bash`` is unavailable (notably native Windows, where the
``bash`` on PATH is the WSL shim and cannot reach this checkout's paths).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
ACQ = REPO_ROOT / "acq"


def _have_bash() -> bool:
    return os.name != "nt" and shutil.which("bash") is not None


pytestmark = pytest.mark.skipif(not _have_bash(), reason="bash (POSIX) unavailable")


def _run_acq(env_extra: dict[str, str], *args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    for name in ("ACQ_IMPL", "ACQ_RUNTIME"):
        env.pop(name, None)
    # The Python `version` reports the active backend's detected version; with
    # both backends absent it never runs a real msb or sbx from the host's PATH.
    env.update(ACQ_SBX_INSTALLED="0", ACQ_MSB_INSTALLED="0")
    env.update(env_extra)
    return subprocess.run(
        ["bash", str(ACQ), *args],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_impl_unset_runs_bash_body():
    proc = _run_acq({}, "version")
    assert proc.returncode == 0, proc.stderr
    assert "script:" in proc.stdout
    assert "acq v1 (Python skeleton)" not in proc.stdout


def test_impl_bash_runs_bash_body():
    proc = _run_acq({"ACQ_IMPL": "bash"}, "version")
    assert proc.returncode == 0, proc.stderr
    assert "script:" in proc.stdout


def test_impl_python_dispatches():
    proc = _run_acq({"ACQ_IMPL": "python"}, "version")
    assert proc.returncode == 0, proc.stderr
    assert "acq v1 (Python skeleton)" in proc.stdout
    assert "impl:" in proc.stdout


def test_impl_python_forwards_json_and_exit_status():
    proc = _run_acq({"ACQ_IMPL": "python"}, "version", "--json")
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["command"] == "version"
    assert doc["data"]["impl"] == "python"


def test_acq_python_launcher_runs_python():
    # ADR-0047m: the distinct `acq-python` identity runs the Python implementation
    # (never the Bash body), so the two entry points are observably distinct.
    acq_python = REPO_ROOT / "acq-python"
    proc = subprocess.run(
        ["bash", str(acq_python), "version"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    assert "acq v1 (Python skeleton)" in proc.stdout
    assert "impl:" in proc.stdout
    assert "script:" not in proc.stdout


def test_impl_unknown_fails_closed_exit_2():
    proc = _run_acq({"ACQ_IMPL": "bogus"}, "version")
    assert proc.returncode == 2
    assert "unsupported ACQ_IMPL" in proc.stderr


# --- launchers must not import modules from the current directory ------------
# `python -m` puts the current directory first on sys.path. A workspace file
# named like a module acq imports must never run on the host.


def _hostile_workspace(tmp_path: Path) -> tuple[Path, Path]:
    ws = tmp_path / "workspace"
    ws.mkdir()
    marker = tmp_path / "hijacked"
    for mod in ("json", "argparse", "pathlib"):
        (ws / f"{mod}.py").write_text(f"open({str(marker)!r}, 'w').write({mod!r})\n")
    return ws, marker


def _launch(argv: list[str], cwd: Path, env_extra: dict[str, str] | None = None):
    env = dict(os.environ)
    for name in ("ACQ_IMPL", "ACQ_RUNTIME"):
        env.pop(name, None)
    env.update(env_extra or {})
    return subprocess.run(argv, cwd=str(cwd), env=env, capture_output=True, text=True, timeout=30)


def test_acq_python_launcher_ignores_workspace_modules(tmp_path):
    ws, marker = _hostile_workspace(tmp_path)
    proc = _launch(["bash", str(REPO_ROOT / "acq-python"), "version", "--json"], ws)
    assert not marker.exists(), "a workspace module was imported on the host"
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["data"]["impl"] == "python"


def test_impl_python_dispatch_ignores_workspace_modules(tmp_path):
    ws, marker = _hostile_workspace(tmp_path)
    proc = _launch(["bash", str(ACQ), "version", "--json"], ws, {"ACQ_IMPL": "python"})
    assert not marker.exists(), "a workspace module was imported on the host"
    assert proc.returncode == 0, proc.stderr


def test_dispatcher_fallback_without_launcher_ignores_workspace_modules(tmp_path):
    # Without an acq-python launcher beside it, `acq` runs `python -m acq_py`
    # itself; that path must be safe too.
    root = tmp_path / "install"
    root.mkdir()
    shutil.copy2(ACQ, root / "acq")
    shutil.copytree(REPO_ROOT / "acq.backends", root / "acq.backends")
    shutil.copytree(REPO_ROOT / "py-acq" / "src", root / "py-acq" / "src")
    ws, marker = _hostile_workspace(tmp_path)
    proc = _launch(["bash", str(root / "acq"), "version", "--json"], ws, {"ACQ_IMPL": "python"})
    assert not marker.exists(), "a workspace module was imported on the host"
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["data"]["impl"] == "python"


def test_launchers_refuse_an_interpreter_older_than_3_12(tmp_path):
    # A stand-in interpreter that fails the version probe, as Python < 3.12 would.
    fake = tmp_path / "python-old"
    fake.write_text("#!/bin/sh\nexit 1\n")
    fake.chmod(0o755)
    proc = _launch(["bash", str(REPO_ROOT / "acq-python"), "version"], tmp_path, {"ACQ_RUNTIME": str(fake)})
    assert proc.returncode == 1
    assert "3.12" in proc.stderr


@pytest.mark.parametrize("pythonpath", [":", "/nonexistent:", ":/nonexistent", ".", "src"])
def test_inherited_pythonpath_cannot_reintroduce_the_workspace(tmp_path, pythonpath):
    # -P only drops the implicit sys.path[0]; an empty or relative PYTHONPATH
    # entry resolves to the cwd, so the launchers must not inherit PYTHONPATH.
    ws, marker = _hostile_workspace(tmp_path)
    (ws / "src").mkdir()
    (ws / "src" / "json.py").write_text((ws / "json.py").read_text())
    (ws / "sitecustomize.py").write_text(f"open({str(marker)!r}, 'w').write('site')\n")
    for argv, extra in (
        (["bash", str(REPO_ROOT / "acq-python"), "version", "--json"], {}),
        (["bash", str(ACQ), "version", "--json"], {"ACQ_IMPL": "python"}),
    ):
        proc = _launch(argv, ws, {"PYTHONPATH": pythonpath, **extra})
        assert not marker.exists(), f"workspace module imported with PYTHONPATH={pythonpath!r}"
        assert proc.returncode == 0, proc.stderr


def test_dispatcher_fallback_refuses_an_old_interpreter(tmp_path):
    root = tmp_path / "install"
    root.mkdir()
    shutil.copy2(ACQ, root / "acq")
    shutil.copytree(REPO_ROOT / "acq.backends", root / "acq.backends")
    fake = tmp_path / "python-old"
    fake.write_text("#!/bin/sh\nexit 1\n")
    fake.chmod(0o755)
    proc = _launch(["bash", str(root / "acq"), "version"], tmp_path,
                   {"ACQ_IMPL": "python", "ACQ_RUNTIME": str(fake)})
    assert proc.returncode == 1
    assert "3.12" in proc.stderr


def test_bash_helpers_run_python_isolated_from_the_workspace(tmp_path):
    # The Bash implementation runs `python3 - <<PY` / `-c` snippets from the
    # user's cwd; `-I` keeps the cwd (and PYTHON* env) off sys.path.
    ws, marker = _hostile_workspace(tmp_path)
    (ws / "re.py").write_text(f"open({str(marker)!r}, 'w').write('re')\n")
    script = f'source "{REPO_ROOT}/acq.backends/common.sh"; _acq_provider_input_canonical_path /tmp'
    proc = _launch(["bash", "-c", script], ws, {"PYTHONPATH": ":"})
    assert not marker.exists(), "a workspace module was imported by a Bash-side python snippet"
    assert proc.returncode == 0, proc.stderr


def test_every_host_python_invocation_is_isolated():
    # Guard against new host-side python calls that put the cwd (or an
    # inherited PYTHONPATH) on sys.path: `python -`, `python -c`, `python -m`
    # need -I (or -P/-E for the acq launchers), and `python script.py` needs at
    # least -E. Covers acq, its backends and the scripts acq executes.
    import re as _re
    interp = r'(?:python3(?:\.\d+)?|"\$\{?[A-Za-z_]*(?:py|PY|python|PYTHON)[A-Za-z_]*\}?")'
    pattern = _re.compile(interp + r'((?:\s+-[A-Za-z]+)*)\s+(-|-c|-m|"\$[A-Za-z_]+")\s')
    offenders = []
    for rel in ("acq", "acq-python", "acq.backends/common.sh", "acq.backends/msb.sh",
                "acq.backends/sbx.sh", "acq.backends/secret-store.sh", "acq.backends/agents.sh",
                "scripts/setup-provider-input-validator"):
        path = REPO_ROOT / rel
        if not path.exists():
            continue
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for m in pattern.finditer(line):
                flags = m.group(1) or ""
                if not _re.search(r"-[A-Za-z]*[IEP]", flags):
                    offenders.append(f"{rel}:{n}: {line.strip()}")
    assert not offenders, "host python calls without -I/-E/-P:\n" + "\n".join(offenders)
