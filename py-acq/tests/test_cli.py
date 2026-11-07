"""Tier-2 implementation tests for the envelope and exit-code contract.

These are non-contract evidence (ADR-0039m): they may reach into the package
directly. Contract evidence lives only in the vector corpus (``test/vectors``).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys

import pytest

import acq_py
from acq_py import envelope, errors


def run_cli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "acq_py", *args],
        capture_output=True,
        text=True,
    )


def test_package_version_is_semver():
    assert re.fullmatch(r"\d+\.\d+\.\d+", acq_py.__version__), acq_py.__version__


def test_envelope_success_shape():
    doc = envelope.success("version", {"acq_version": "0.1.0"})
    assert doc == {
        "schema_version": envelope.SCHEMA_VERSION,
        "command": "version",
        "data": {"acq_version": "0.1.0"},
    }


def test_envelope_error_shape():
    doc = envelope.error("version", errors.USAGE, "bad", remediation="try again")
    assert doc["schema_version"] == envelope.SCHEMA_VERSION
    assert doc["command"] == "version"
    assert doc["error"] == {"code": "usage", "message": "bad", "remediation": "try again"}


def test_version_json_subprocess():
    proc = run_cli("version", "--json")
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["schema_version"] == envelope.SCHEMA_VERSION
    assert doc["command"] == "version"
    assert doc["data"]["acq_version"] == acq_py.__version__


def test_usage_error_exit_code_2_human():
    proc = run_cli("--bad-flag")
    assert proc.returncode == 2
    assert proc.stdout == ""
    assert "bad-flag" in proc.stderr


def test_usage_error_json_envelope():
    proc = run_cli("--json", "--bad-flag")
    assert proc.returncode == 2
    doc = json.loads(proc.stdout)
    assert doc["schema_version"] == envelope.SCHEMA_VERSION
    assert doc["error"]["code"] == "usage"


def test_version_flag_alias():
    proc = run_cli("--version")
    assert proc.returncode == 0
    assert "acq version" in proc.stdout


@pytest.mark.parametrize("cmd", [["version"], ["help"], ["--help"]])
def test_success_paths_exit_zero(cmd):
    assert run_cli(*cmd).returncode == 0


# ---- command-module split (the dispatch layer is a thin seam) -----------------

def test_cli_reexports_everything_the_command_modules_own_that_callers_address():
    # The handlers moved to acq_py.commands.*; cli re-exports the names the Tier-2
    # tests patch and call, so the split is invisible to existing callers. Any
    # re-export that stops resolving to the owning module is a silent divergence:
    # cli.X and commands.Y.X must be the same object, not a stale copy.
    from acq_py import cli
    from acq_py.commands import common, lifecycle

    for name in (
        "_adapter", "_supports", "_default_image_for_agent", "_usage_failure",
        "_operational_failure", "_resolve_active_backend", "_read_secret_value",
        "_validate_workspace", "_mount_workspace", "_sandbox_ref",
        "_workspace_from_record", "_slugify", "_derive_name",
        "_parse_secret_scope_service", "_parse_secret_ls_scope",
        "_ADAPTER_ERRORS", "KNOWN_AGENTS", "DEFAULT_GUEST_WORKSPACE",
        "OPENCODE_DEVENV_IMAGE",
    ):
        assert getattr(cli, name) is getattr(common, name), name
    assert cli._resolve_image is lifecycle._resolve_image
    assert cli.SUBSTRATE_STATE_ENV is lifecycle.SUBSTRATE_STATE_ENV


def test_every_known_command_has_a_dispatch_arm_into_a_command_module():
    # main() must route every advertised verb into acq_py.commands.*. Driving each
    # verb with no arguments cannot prove this (most exit 2 at argparse before
    # dispatch), so this reads the dispatch itself: every KNOWN_COMMAND must appear
    # in a `parsed.command == "X"` comparison, and every such arm must call a
    # qualified `<module>.<handler>`. A verb dropped from the dispatch during a
    # refactor would otherwise fall through to the backend passthrough silently.
    import ast
    import inspect

    from acq_py import cli
    from acq_py.commands import common, creds, kit, lifecycle, secret, session

    tree = ast.parse(inspect.getsource(cli.main))
    routed, calls = set(), set()
    for node in ast.walk(tree):
        if (isinstance(node, ast.Compare) and isinstance(node.left, ast.Attribute)
                and node.left.attr in ("command", "secret_command", "backend_command",
                                       "provider_credential_command", "kit_command")):
            routed |= {c.value for c in node.comparators if isinstance(c, ast.Constant)}
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                and isinstance(node.func.value, ast.Name):
            calls.add(f"{node.func.value.id}.{node.func.attr}")

    unrouted = cli.KNOWN_COMMANDS - routed
    assert not unrouted, f"not reachable from main(): {sorted(unrouted)}"

    modules = {"common": common, "creds": creds, "kit": kit, "lifecycle": lifecycle,
               "secret": secret, "session": session}
    handlers = {c for c in calls if c.split(".")[0] in modules}
    assert handlers, "main() no longer dispatches into any command module"
    for call in sorted(handlers):
        mod, attr = call.split(".", 1)
        assert hasattr(modules[mod], attr), f"main() calls {call}, which does not exist"


def test_an_unknown_verb_reaches_the_passthrough_not_argparse(monkeypatch):
    # The passthrough is the deliberate escape hatch (spec user story #9): an unknown
    # verb must reach it verbatim rather than becoming an argparse usage error. With
    # no backend installed it fails closed with backend_not_found, which is itself
    # proof the verb got past argparse into the passthrough.
    import contextlib
    import io
    import json

    from acq_py import cli

    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        code = cli.main(["definitely-not-a-verb", "--json"])
    assert code == 1  # operational failure, not 2 (usage)
    doc = json.loads(out.getvalue().splitlines()[-1])
    assert doc["command"] == "definitely-not-a-verb"  # the verb was carried through
    assert doc["error"]["code"] == "backend_not_found"
