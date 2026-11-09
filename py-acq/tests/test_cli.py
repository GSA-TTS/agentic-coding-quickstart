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


def test_version_reports_python_impl():
    # ADR-0047m: version output marks the implementation so a bug report is
    # unambiguous about which implementation produced it.
    proc = run_cli("version", "--json")
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["data"]["impl"] == "python"

    human = run_cli("version")
    assert human.returncode == 0, human.stderr
    assert "impl:" in human.stdout


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

import pathlib


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

    # `is` alone is not enough for short string constants: CPython interns
    # identifier-like literals, so a hand-copied duplicate would satisfy it. Assert
    # the alias is the *only* definition by reading the source of each module.
    import re

    for name, owner in (("SUBSTRATE_STATE_ENV", "lifecycle"), ("DEFAULT_GUEST_WORKSPACE", "common")):
        source = (pathlib.Path(cli.__file__)).read_text(encoding="utf-8")
        assigns = re.findall(rf"^{name} = (.+)$", source, re.M)
        assert assigns == [f"{owner}.{name}"], f"cli must alias {name}, not redefine it: {assigns}"


def test_every_known_command_has_a_dispatch_arm_into_a_command_module():
    # main() (through _dispatch, which holds the arms while main owns the error
    # boundary) must route every advertised verb into a real handler. Driving each verb
    # with no arguments cannot prove this (most exit 2 at argparse before dispatch),
    # so this reads the dispatch itself, per arm: for every KNOWN_COMMAND there must
    # be an `if parsed.command == "X"` (or an `in (...)` group) whose body calls a
    # `<command module>.<handler>` that exists. Subcommand comparisons
    # (parsed.secret_command and friends) are deliberately ignored: `ls`, `rm`,
    # `check` and `list` appear in both spaces, so counting them would let a missing
    # top-level arm be satisfied by a same-named subcommand.
    import ast
    import inspect

    from acq_py import cli
    from acq_py.commands import common, creds, kit, lifecycle, secret, session

    modules = {"common": common, "creds": creds, "kit": kit, "lifecycle": lifecycle,
               "secret": secret, "session": session}

    def verbs_of(test):
        """Top-level command literals an `if` test compares against."""
        found = set()
        for node in ast.walk(test):
            left = getattr(node, "left", None)
            if isinstance(node, ast.Compare) and isinstance(left, ast.Attribute) and left.attr == "command":
                for cmp in node.comparators:
                    if isinstance(cmp, ast.Constant) and isinstance(cmp.value, str):
                        found.add(cmp.value)
                    elif isinstance(cmp, (ast.Tuple, ast.List, ast.Set)):
                        found |= {e.value for e in cmp.elts
                                  if isinstance(e, ast.Constant) and isinstance(e.value, str)}
        return found

    def handlers_in(body):
        calls = set()
        for stmt in body:
            for node in ast.walk(stmt):
                if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                        and isinstance(node.func.value, ast.Name)
                        and node.func.value.id in modules):
                    calls.add((node.func.value.id, node.func.attr))
        return calls

    # Record the most specific arm per verb: an outer `in (...)` group resolves the
    # backend and then delegates to one `== "verb"` arm each, so the handler call
    # must be found on that inner arm, not merely somewhere in the enclosing group.
    routed, specific = {}, {}
    dispatch_src = inspect.getsource(cli.main) + "\n" + inspect.getsource(cli._dispatch)
    for node in ast.walk(ast.parse(dispatch_src)):
        if not isinstance(node, ast.If):
            continue
        verbs = verbs_of(node.test)
        for verb in verbs:
            routed.setdefault(verb, set())
            if len(verbs) == 1:  # a single-verb arm is the specific one
                specific.setdefault(verb, set()).update(handlers_in(node.body))
            else:
                routed[verb].update(handlers_in(node.body))
    for verb, calls in specific.items():
        routed[verb] = calls

    # A verb named only in an `in (...)` group, with no arm of its own, is NOT
    # routed: the group resolves the backend and then falls through, so the verb
    # would reach the end of main() instead of a handler.
    grouped = {v for v, calls in routed.items() if v not in specific}
    delegating = {v for v in grouped if v not in ("version", "doctor", "backend", "help")}
    assert not delegating, f"named in a group but given no dispatch arm: {sorted(delegating)}"

    unrouted = cli.KNOWN_COMMANDS - set(routed) - {"help"}  # `help` is argparse's own
    assert not unrouted, f"not reachable from main(): {sorted(unrouted)}"

    for verb, calls in sorted(routed.items()):
        # `version` and `doctor` are handled in cli itself (lazily imported, so they
        # stay off the Tier-3 surface); every other verb delegates to a module.
        if verb in ("version", "doctor", "backend", "help"):
            continue
        assert calls, f"the dispatch arm for {verb!r} calls no command-module handler"
        for mod, attr in sorted(calls):
            assert hasattr(modules[mod], attr), f"{verb!r} dispatches to {mod}.{attr}, which does not exist"


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
