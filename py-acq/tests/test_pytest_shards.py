"""Real collection and fail-closed CI aggregation contracts (ADR-0054m)."""

from __future__ import annotations

import copy
import itertools
import os
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))


def run_suite(root, spec=None, collect=False):
    args = [sys.executable, "-m", "pytest", "-p", "pytest_shard", str(root),
            "-q", "--tb=short", "--show-capture=no"]
    if spec is not None:
        args += ["--acq-shard", spec]
    if collect:
        args += ["--collect-only"]
    plugin_path = str(ROOT / "scripts")
    pytest_path = str(Path(pytest.__file__).resolve().parent.parent)
    inherited_pythonpath = os.environ.get("PYTHONPATH")
    return subprocess.run(args, cwd=root, text=True, capture_output=True, timeout=30,
                          env={**os.environ, "PYTHONPATH": plugin_path + os.pathsep + pytest_path + (
                              os.pathsep + inherited_pythonpath if inherited_pythonpath else ""),
                               "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1"})


@pytest.fixture
def suite(tmp_path):
    # Module fixture requires every parametrization to execute in the same worker.
    (tmp_path / "conftest.py").write_text(
        "import pytest\n@pytest.fixture(scope='module')\ndef seen():\n"
        "    values = []\n    yield values\n    assert values == [0, 1, 2]\n")
    for name in ("test_a.py", "test_b.py", "c_test.py", "test_d.py"):
        (tmp_path / name).write_text(
            "import pytest\n@pytest.mark.parametrize('i', range(3))\n"
            "def test_item(i, seen):\n    seen.append(i)\n")
    (tmp_path / "helper.py").write_text("raise RuntimeError('not a collected test')\n")
    return tmp_path


def nodes(result):
    assert result.returncode == 0, result.stdout + result.stderr
    return {line for line in result.stdout.splitlines() if "::test_item[" in line}


def test_collection_partitions_all_items_and_new_files(suite):
    for add_file in (False, True):
        if add_file:
            (suite / "test_new.py").write_text((suite / "test_a.py").read_text())
        full = nodes(run_suite(suite, collect=True))
        shards = [nodes(run_suite(suite, f"{i}/4", collect=True)) for i in range(1, 5)]
        assert set.union(*shards) == full
        assert sum(map(len, shards)) == len(full)
        assert all(shards)
        assert all("helper.py" not in node for node in full)
        for shard in shards:
            for file in {node.split("::", 1)[0] for node in shard}:
                assert {node for node in full if node.startswith(file + "::")} <= shard


@pytest.mark.parametrize("spec", [None, "1/4", "2/4", "3/4", "4/4"])
def test_parametrizations_and_module_fixture_stay_together(suite, spec):
    result = run_suite(suite, spec)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("spec", ["", "0/4", "1/0", "5/4", "1", "1/4/2", "-1/4", "01/4", "1/5"])
def test_invalid_or_empty_shard_fails_before_execution(suite, spec):
    result = run_suite(suite, spec)
    assert result.returncode == 4
    assert "ERROR:" in result.stderr
    assert " passed" not in result.stdout


def test_collection_error_and_test_failure_remain_failures(suite):
    (suite / "test_a.py").write_text("def test_failure():\n    assert False\n")
    assert run_suite(suite, "4/4").returncode == 1
    (suite / "test_a.py").write_text("raise RuntimeError('collection failure')\n")
    assert run_suite(suite, "1/4").returncode == 2


def test_partition_is_deterministic_and_balances_collected_counts():
    from pytest_shard import partition

    counts = Counter({"a": 12, "b": 6, "c": 4, "d": 2, "new": 1})
    assert partition(counts, 4) == partition(Counter(dict(reversed(list(counts.items())))), 4)
    assert partition(counts, 4) == [["a"], ["b"], ["c"], ["d", "new"]]
    with pytest.raises(ValueError):
        partition(Counter(), 4)


def workflow():
    return yaml.safe_load((ROOT / ".github/workflows/python-vectors.yml").read_text())


def assert_topology(doc):
    jobs = doc["jobs"]
    matrix = jobs["pytest-shards"]["strategy"]
    assert matrix == {"fail-fast": False, "matrix": {"shard": ["1/4", "2/4", "3/4", "4/4"]}}
    assert jobs["corpus"]["needs"] == ["pytest-shards"]
    assert "if" not in jobs["corpus"]  # Default success() is deliberate.
    gate = jobs["vectors"]
    assert gate["needs"] == ["pytest-shards", "corpus"]
    assert gate["if"] == "${{ always() }}"
    assert gate["steps"][0]["env"] == {
        "PYTEST_RESULT": "${{ needs.pytest-shards.result }}",
        "CORPUS_RESULT": "${{ needs.corpus.result }}",
    }


def gate_result(doc, pytest_result, corpus_result):
    script = doc["jobs"]["vectors"]["steps"][0]["run"]
    # Resolve the real POSIX Bash beside sh, not Windows' WSL launcher; the
    # restricted child PATH must not hide the installed Git Bash toolchain.
    shell = shutil.which("sh")
    assert shell is not None, "gate tests require the POSIX shell toolchain"
    bash = shutil.which("bash", path=str(Path(shell).parent))
    assert bash is not None, "the POSIX shell toolchain must supply Bash"
    return subprocess.run([bash, "-c", script], capture_output=True, timeout=10,
                          env={"PATH": os.defpath, "PYTEST_RESULT": pytest_result,
                               "CORPUS_RESULT": corpus_result}).returncode


def assert_gate(doc):
    for pytest_result, corpus_result in itertools.product(
        ("success", "failure", "cancelled", "skipped", ""), repeat=2
    ):
        assert (gate_result(doc, pytest_result, corpus_result) == 0) == (
            pytest_result == corpus_result == "success"
        )


def test_final_gate_rejects_matrix_and_late_corpus_failure():
    doc = workflow()
    assert_topology(doc)
    assert_gate(doc)


def test_mutation_controls_reject_missing_shard_or_ignored_failure():
    doc = workflow()
    missing = copy.deepcopy(doc)
    missing["jobs"]["pytest-shards"]["strategy"]["matrix"]["shard"].pop()
    with pytest.raises(AssertionError):
        assert_topology(missing)
    for result in ("PYTEST_RESULT", "CORPUS_RESULT"):
        ignored = copy.deepcopy(doc)
        step = ignored["jobs"]["vectors"]["steps"][0]
        step["run"] = step["run"].replace(f'test "${result}" = success', "true")
        with pytest.raises(AssertionError):
            assert_gate(ignored)


def test_workers_preserve_pinned_checkout_guard_and_diagnostics():
    steps = workflow()["jobs"]["pytest-shards"]["steps"]
    run = next(step for step in steps if step.get("name") == "Run pytest vector runner")
    assert "-p scripts.pytest_shard" in run["run"]
    assert "--acq-shard '${{ matrix.shard }}'" in run["run"]
    assert "--tb=short -ra --show-capture=no" in run["run"]
    assert "set -euo pipefail" in run["run"]
    assert "pinned Patterns checkout is provided" in run["run"]
    assert "ACQ_TEST_PATTERNS_REPO" in run["env"]
    verify = next(step for step in steps if step.get("name") == "Verify the pinned Patterns checkout")
    assert 'rev-parse HEAD)" = "$PATTERNS_REF"' in verify["run"]
    assert "status --porcelain" in verify["run"]
    assert "! -type l -exec chmod a-w" in verify["run"]
    text = (ROOT / ".github/workflows/python-vectors.yml").read_text()
    assert text.count('scripts/run-vectors --acq "python -m acq_py"') == 1
    assert text.count('scripts/run-vectors --acq "$run/bin/acq-py" --section cli') == 1
