"""Tier-2 tests for ``acq start`` / ``acq restart`` on msb (ADR-0017, ADR-0040m).

Non-contract evidence (ADR-0039m): these drive ``cli.main`` in-process against
the deterministic ``__stub__`` msb, whose ``start`` refuses a bound variable that
is missing from its environment or whose value appears in any argv element (as
the real msb needs the value in its environment after a stop). Every msb child
process is recorded, so the tests prove the order of the steps, that a secret
value travels only in the child's environment mapping (checked as a substring
of every argv element), and that the kit heal and the read-only probe run.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import cli, errors, kit_msb, kits, lock, msb, secretstore, security, state

pytestmark = pytest.mark.provider_key  # creates msb sandboxes: needs a stored provider key

VALUE = "S3NTINEL-start-value-4b17"
OWN = "S3NTINEL-own-value-c2a0"


def _env(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in ("USAI_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "GITLAB_TOKEN"):
        monkeypatch.delenv(name, raising=False)
    (tmp_path / "ws").mkdir(exist_ok=True)


@pytest.fixture
def children(monkeypatch):
    """Record (argv, env) of every msb child process, after the adapter built it."""
    seen: list[tuple[list[str], dict | None]] = []
    real = subprocess.run

    def spy(argv, *args, **kwargs):
        if any("_stub_msb" in str(a) for a in argv):
            env = kwargs.get("env")
            seen.append((list(argv), dict(env) if env is not None else None))
        return real(argv, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", spy)
    return seen


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out, err = capsys.readouterr()
    doc = json.loads(out) if out.strip().startswith("{") else None
    return rc, doc, out, err


def _acq(capsys, *argv):
    return _invoke(capsys, "--backend", "msb", *argv)


def _set(capsys, monkeypatch, *args, value=VALUE):
    monkeypatch.setattr(sys, "stdin", io.StringIO(value))
    rc, doc, _out, err = _acq(capsys, "secret", "set", *args, "--json")
    assert rc == 0, (doc, err)


def _create(capsys, tmp_path, *extra):
    rc, doc, _out, err = _acq(capsys, "create", "shell", str(tmp_path / "ws"), "--name", "box", *extra, "--json")
    assert rc == 0, (doc, err)


def _stub_records(tmp_path) -> dict:
    path = tmp_path / "msb-home" / ".microsandbox" / "secrets.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def _verbs(children) -> list[str]:
    """The msb subcommand of each child, in order."""
    out = []
    for argv, _env in children:
        i = next(k for k, a in enumerate(argv) if a == "acq_py._stub_msb")
        out.append(argv[i + 1])
    return out


def _calls(children, verb):
    return [(argv, env) for argv, env in children if verb in argv]


def _assert_value_absent(value, children, *streams):
    for argv, _env in children:
        for element in argv:
            assert value not in element, f"value leaked into argv element {element!r}"
    for text in streams:
        assert value not in text


def _stopped_box(monkeypatch, tmp_path, capsys, *, secret=True):
    _env(monkeypatch, tmp_path)
    if secret:
        _set(capsys, monkeypatch, "-g", "usai")
    else:
        # Created with no provider kit, so neither the key gate nor a usai binding applies.
        secretstore.delete(secretstore.key_for("usai"))
        monkeypatch.setenv("ACQ_PROVIDER_KITS", "")
    _create(capsys, tmp_path)
    monkeypatch.delenv("ACQ_PROVIDER_KITS", raising=False)
    if not secret:
        # A sandbox keeps the selection it was created with; drop that record, as
        # for a sandbox from before it was recorded, so start uses the current,
        # default selection and a usai key stored meanwhile gets bound.
        path = kits._provenance_path("msb", "box")
        doc = json.loads(path.read_text(encoding="utf-8"))
        del doc["provider_selection"]
        path.write_text(json.dumps(doc), encoding="utf-8")
    assert _acq(capsys, "stop", "box")[0] == 0


# ---------------------------------------------------------------------------
# Secrets: only in msb's environment; a secret stored while stopped is bound.
# ---------------------------------------------------------------------------

def test_start_passes_bound_secrets_only_in_the_start_childs_env(monkeypatch, tmp_path, capsys, children):
    _stopped_box(monkeypatch, tmp_path, capsys)
    children.clear()
    rc, doc, out, err = _acq(capsys, "start", "box", "--json")
    assert rc == 0, (doc, err)
    assert doc["data"]["secret_bindings"] == ["USAI_API_KEY@api.gsa.usai.gov"]
    assert doc["data"]["was_running"] is False
    (argv, env), = _calls(children, "start")
    assert argv[-2:] == ["start", "box"]
    assert env is not None and env["USAI_API_KEY"] == VALUE
    # No other child (readiness probes, kit steps) receives the value. A child
    # given no env mapping inherits acq's own environment, which must not have
    # picked the value up either.
    for other_argv, other_env in children:
        if "start" not in other_argv:
            inherited = other_env if other_env is not None else dict(os.environ)
            assert VALUE not in inherited.values()
    assert VALUE not in os.environ.values()
    _assert_value_absent(VALUE, children, out, err)
    assert VALUE not in json.dumps(_stub_records(tmp_path))


def test_start_binds_a_secret_stored_while_stopped(monkeypatch, tmp_path, capsys, children):
    _stopped_box(monkeypatch, tmp_path, capsys, secret=False)
    _set(capsys, monkeypatch, "-g", "usai")
    assert _calls(children, "modify") == []  # set re-feeds running sandboxes only
    children.clear()
    rc, doc, out, err = _acq(capsys, "start", "box", "--json")
    assert rc == 0, (doc, err)
    (start_argv, start_env), = _calls(children, "start")
    assert start_env is None  # nothing was bound when the sandbox stopped
    (argv, env), = _calls(children, "modify")
    assert argv[-3:] == ["box", "--secret", "USAI_API_KEY@api.gsa.usai.gov"]
    assert env["USAI_API_KEY"] == VALUE
    assert _verbs(children).index("start") < _verbs(children).index("modify")
    assert msb.held_read("box").bindings["USAI_API_KEY"]["service"] == "usai"
    assert _stub_records(tmp_path)["box"]["USAI_API_KEY"]["host"] == "api.gsa.usai.gov"
    assert doc["data"]["secret_bindings"] == ["USAI_API_KEY@api.gsa.usai.gov"]
    _assert_value_absent(VALUE, children, out, err)
    # The next start finds the binding recorded and feeds it to msb start.
    assert _acq(capsys, "stop", "box")[0] == 0
    children.clear()
    assert _acq(capsys, "start", "box")[0] == 0
    assert _calls(children, "modify") == []
    assert _calls(children, "start")[0][1]["USAI_API_KEY"] == VALUE


@pytest.mark.parametrize("recorded", ["no-provider-kits", "default"])
def test_start_binds_a_secret_stored_while_stopped_under_the_recorded_selection(
        monkeypatch, tmp_path, capsys, children, recorded):
    # The sandbox keeps the selection its create recorded: a secret stored while
    # it was stopped is bound at start only when that selection admits it.
    GITHUB = "S3NTINEL-github-value-5d21"
    _env(monkeypatch, tmp_path)
    if recorded == "default":
        _set(capsys, monkeypatch, "-g", "usai")  # the default provider kit needs its key at create
    else:
        secretstore.delete(secretstore.key_for("usai"))
        monkeypatch.setenv("ACQ_PROVIDER_KITS", "")
    _create(capsys, tmp_path)
    monkeypatch.delenv("ACQ_PROVIDER_KITS", raising=False)  # start runs with today's default selection
    assert kits.provider_selection_read("msb", "box") == (
        ("explicit", "") if recorded == "no-provider-kits" else ("default", ""))
    assert _acq(capsys, "stop", "box")[0] == 0
    if recorded == "no-provider-kits":
        _set(capsys, monkeypatch, "-g", "usai")  # stored while stopped: the selection keeps it out
    _set(capsys, monkeypatch, "-g", "github", value=GITHUB)  # stored while stopped: not a provider
    assert _calls(children, "modify") == []  # set re-feeds running sandboxes only
    children.clear()
    rc, doc, out, err = _acq(capsys, "start", "box", "--json")
    assert rc == 0, (doc, err)
    github_flag = "GITHUB_TOKEN@github.com,api.github.com,codeload.github.com"
    (argv, env), = _calls(children, "modify")
    assert argv[-3:] == ["box", "--secret", github_flag] and env["GITHUB_TOKEN"] == GITHUB
    held = msb.held_read("box").bindings
    if recorded == "default":
        assert doc["data"]["secret_bindings"] == sorted([github_flag, "USAI_API_KEY@api.gsa.usai.gov"])
        assert _calls(children, "start")[0][1]["USAI_API_KEY"] == VALUE
        assert set(held) == {"GITHUB_TOKEN", "USAI_API_KEY"}
    else:
        assert doc["data"]["secret_bindings"] == [github_flag]
        assert _calls(children, "start")[0][1] is None  # nothing was bound when it stopped
        assert set(held) == {"GITHUB_TOKEN"} and "usai-provider" not in doc["data"]["kits"]
    _assert_value_absent(VALUE, children, out, err)
    _assert_value_absent(GITHUB, children, out, err)


def test_start_feeds_a_value_changed_while_stopped_and_records_its_scope(monkeypatch, tmp_path, capsys, children):
    _stopped_box(monkeypatch, tmp_path, capsys)
    _set(capsys, monkeypatch, "box", "usai", value=OWN)
    children.clear()
    assert _acq(capsys, "start", "box")[0] == 0
    assert _calls(children, "start")[0][1]["USAI_API_KEY"] == OWN
    assert _calls(children, "modify") == []  # same variable and hosts: only the scope changed
    assert msb.held_read("box").bindings["USAI_API_KEY"]["scope"] == "sandbox"
    _assert_value_absent(OWN, children)


def test_start_refuses_a_bound_secret_with_no_value_before_starting(monkeypatch, tmp_path, capsys, children):
    _stopped_box(monkeypatch, tmp_path, capsys)
    secretstore.delete(secretstore.key_for("usai", None))
    children.clear()
    rc, doc, _out, _err = _acq(capsys, "start", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.SECRET_MISSING
    assert "USAI_API_KEY" in doc["error"]["message"]
    assert _calls(children, "start") == []
    assert "USAI_API_KEY" in msb.held_read("box").bindings  # never silently dropped


def test_start_reports_a_binding_that_could_not_be_added(monkeypatch, tmp_path, capsys):
    _stopped_box(monkeypatch, tmp_path, capsys, secret=False)
    _set(capsys, monkeypatch, "-g", "usai")
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_ADD", "box")
    rc, doc, _out, _err = _acq(capsys, "start", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.FAILURE
    assert "is running" in doc["error"]["message"] and "usai" in doc["error"]["message"]


def test_start_failure_is_reported_and_no_heal_runs(monkeypatch, tmp_path, capsys, children):
    _stopped_box(monkeypatch, tmp_path, capsys)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "start")
    children.clear()
    rc, doc, out, err = _acq(capsys, "start", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.FAILURE
    assert "raw backend failure" not in out + err
    assert _verbs(children)[-1] == "start"


# ---------------------------------------------------------------------------
# Kit heal and the read-only probe.
# ---------------------------------------------------------------------------

def _spy_heal(monkeypatch, events: list) -> list:
    calls: list = []
    real = kit_msb.ensure_kits_applied

    def spy(name, kit_set, *, ro_required, force=False, ssh_auth_sock=None):
        events.append("heal")
        calls.append(([k.name for k in kit_set], ro_required, force))
        return real(name, kit_set, ro_required=ro_required, force=force, ssh_auth_sock=ssh_auth_sock)

    monkeypatch.setattr(kit_msb, "ensure_kits_applied", spy)
    return calls


def test_start_heals_the_recorded_kit_set(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path, "--kit", "opencode")
    assert _acq(capsys, "stop", "box")[0] == 0
    calls = _spy_heal(monkeypatch, [])
    children.clear()
    rc, doc, _out, err = _acq(capsys, "start", "box", "--json")
    assert rc == 0, (doc, err)
    (names, _ro, force), = calls
    assert "opencode" in names and "usai-provider" in names  # the .kits record plus the built-ins
    assert force is False  # a heal, not a refresh
    assert doc["data"]["kits"] == names
    assert _verbs(children).index("start") < len(children) - 1  # kit steps ran after the start


def test_start_reports_an_incomplete_heal(monkeypatch, tmp_path, capsys):
    _stopped_box(monkeypatch, tmp_path, capsys, secret=False)
    monkeypatch.setattr(kit_msb, "ensure_kits_applied",
                        lambda name, kit_set, **_kw: kit_msb.ApplyResult(["usai-provider"], ["git-ssh-sign"]))
    rc, doc, _out, _err = _acq(capsys, "start", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.FAILURE
    assert "is running" in doc["error"]["message"] and "git-ssh-sign" in doc["error"]["message"]


def _require_ro(name: str) -> None:
    rec = state.record_read("msb", name)
    state.record_write("msb", name, agent=rec["agent"], workspace=rec["workspace"], image=rec["image"],
                       ro_host_config=True)


def _spy_reconcile(monkeypatch, events: list) -> None:
    real = msb.reconcile_bindings

    def spy(name):
        events.append("reconcile")
        return real(name)

    monkeypatch.setattr(msb, "reconcile_bindings", spy)


def test_start_runs_the_ro_probe_before_binding_secrets_and_the_heal(monkeypatch, tmp_path, capsys):
    _stopped_box(monkeypatch, tmp_path, capsys, secret=False)
    _require_ro("box")
    events: list = []
    calls = _spy_heal(monkeypatch, events)
    _spy_reconcile(monkeypatch, events)
    monkeypatch.setattr(security, "probe_mount", lambda name: (events.append("probe"), ("ok", ""))[1])
    rc, doc, _out, err = _acq(capsys, "start", "box", "--json")
    assert rc == 0, (doc, err)
    assert events[:3] == ["probe", "reconcile", "heal"]
    assert calls[0][1] is True  # the heal keeps the read-only requirement


def test_start_missing_ro_mount_binds_no_new_secret_and_skips_the_heal(monkeypatch, tmp_path, capsys, children):
    _stopped_box(monkeypatch, tmp_path, capsys, secret=False)
    _require_ro("box")
    _set(capsys, monkeypatch, "-g", "usai")  # stored while stopped: would be bound after the start
    events: list = []
    calls = _spy_heal(monkeypatch, events)
    _spy_reconcile(monkeypatch, events)
    monkeypatch.setattr(security, "probe_mount", lambda name: ("missing", "the host-config mount looks WRITABLE"))
    children.clear()
    rc, doc, _out, _err = _acq(capsys, "start", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.SECURITY_EXCEPTION
    assert "is running" in doc["error"]["message"]
    assert calls == [] and events == []
    assert _calls(children, "modify") == []
    assert "USAI_API_KEY" not in msb.held_read("box").bindings


def test_start_without_the_ro_requirement_does_not_probe(monkeypatch, tmp_path, capsys):
    _stopped_box(monkeypatch, tmp_path, capsys, secret=False)
    rec = state.record_read("msb", "box")
    state.record_write("msb", "box", agent=rec["agent"], workspace=rec["workspace"], image=rec["image"],
                       ro_host_config=None)
    monkeypatch.setattr(security, "probe_mount", lambda name: pytest.fail("probed without the requirement"))
    assert _acq(capsys, "start", "box")[0] == 0


# ---------------------------------------------------------------------------
# Lock, ordering, refusals.
# ---------------------------------------------------------------------------

def test_start_and_restart_wait_for_the_sandbox_lock(monkeypatch, tmp_path, capsys, children):
    _stopped_box(monkeypatch, tmp_path, capsys)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    children.clear()
    with lock.sandbox_lock("msb", "box"):
        for verb in ("start", "restart"):
            rc, doc, _out, _err = _acq(capsys, verb, "box", "--json")
            assert rc == 1 and doc["command"] == verb and doc["error"]["code"] == errors.TIMEOUT
    assert "start" not in _verbs(children) and "stop" not in _verbs(children)


def test_start_waits_for_a_global_secret_change(monkeypatch, tmp_path, capsys, children):
    # msb start binds the values it reads from the store, as a create does, so a
    # rotation or global set/rm in progress must not slip between read and bind.
    _stopped_box(monkeypatch, tmp_path, capsys)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    children.clear()
    with lock.secret_store_lock():
        rc, doc, _out, _err = _acq(capsys, "start", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.TIMEOUT, doc
    assert "secret-store lock" in doc["error"]["message"]
    assert "nothing was started" in doc["error"]["remediation"]
    assert "start" not in _verbs(children)
    if os.name == "nt":
        return  # the store lock has no shared mode there
    with lock.secret_store_lock(shared=True):  # another create or start does not hold it up
        rc, doc, _out, _err = _acq(capsys, "start", "box", "--json")
    assert rc == 0, doc


def _store_lock_mode() -> str:
    """How the secret-store lock is held right now: ``free``, ``shared`` or ``exclusive``."""
    path = lock.secret_store_lock_path()
    try:
        with lock.exclusive_lock(path, 0.0, timeout_cls=lock.SecretStoreLockTimeout):
            return "free"
    except lock.SecretStoreLockTimeout:
        pass
    if os.name == "nt":
        return "held"  # no shared mode there: held, in some mode
    try:
        with lock.exclusive_lock(path, 0.0, timeout_cls=lock.SecretStoreLockTimeout, shared=True):
            return "shared"
    except lock.SecretStoreLockTimeout:
        return "exclusive"


@pytest.mark.parametrize("verb", ["start", "restart"])
def test_binding_after_the_start_reads_the_store_under_its_lock(monkeypatch, tmp_path, capsys, verb):
    # reconcile_bindings reads stored values and binds them into the running
    # guest; a global secret change must not slip between the two.
    _stopped_box(monkeypatch, tmp_path, capsys, secret=False)
    _set(capsys, monkeypatch, "-g", "usai")  # stored while stopped: bound by the reconcile
    modes: list[str] = []
    real = msb.reconcile_bindings

    def spy(name):
        modes.append(_store_lock_mode())
        return real(name)

    monkeypatch.setattr(msb, "reconcile_bindings", spy)
    rc, doc, _out, err = _acq(capsys, verb, "box", "--json")
    assert rc == 0, (doc, err)
    assert modes == ["held" if os.name == "nt" else "shared"]
    assert "USAI_API_KEY" in msb.held_read("box").bindings


def test_start_on_a_running_sandbox_waits_for_a_global_secret_change_before_binding(monkeypatch, tmp_path, capsys,
                                                                                     children):
    # msb start is skipped for a running sandbox, so the reconcile's own lock is
    # the only thing keeping a global change from slipping between read and bind.
    _env(monkeypatch, tmp_path)
    _set(capsys, monkeypatch, "-g", "usai")
    _create(capsys, tmp_path)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    called: list[str] = []
    monkeypatch.setattr(msb, "reconcile_bindings", lambda name: called.append(name) or [])
    children.clear()
    with lock.secret_store_lock():
        rc, doc, _out, _err = _acq(capsys, "start", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.TIMEOUT, doc
    assert "secret-store lock" in doc["error"]["message"]
    assert "nothing new was bound" in doc["error"]["remediation"]
    assert called == []
    assert "start" not in _verbs(children)  # it was running: no msb start either


def test_restart_stops_then_starts_then_heals(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    _set(capsys, monkeypatch, "-g", "usai")
    _create(capsys, tmp_path)
    children.clear()
    rc, doc, out, err = _acq(capsys, "restart", "box", "--json")
    assert rc == 0, (doc, err)
    verbs = _verbs(children)
    assert verbs.index("stop") < verbs.index("start") < len(verbs) - 1
    assert verbs[verbs.index("start") + 1:].count("exec") >= 2  # readiness, then the kit steps
    assert _calls(children, "start")[0][1]["USAI_API_KEY"] == VALUE
    assert doc["command"] == "restart" and doc["data"]["was_running"] is False
    _assert_value_absent(VALUE, children, out, err)


def test_restart_still_starts_when_the_stop_fails(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    assert _acq(capsys, "stop", "box")[0] == 0
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "stop")
    children.clear()
    rc, _doc, out, err = _acq(capsys, "restart", "box")
    assert rc == 0, err
    assert "stop of 'box' failed; attempting start anyway" in err
    assert "start" in _verbs(children)
    assert "restarted sandbox 'box'" in out


def test_restart_that_cannot_stop_a_running_sandbox_fails(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    calls = _spy_heal(monkeypatch, [])
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "stop")
    children.clear()
    rc, doc, out, err = _acq(capsys, "restart", "box", "--json")
    assert rc == 1 and doc["command"] == "restart" and doc["error"]["code"] == errors.FAILURE
    assert "could not restart sandbox 'box'" in doc["error"]["message"]
    assert "still running" in doc["error"]["message"] and "re-applied" in doc["error"]["message"]
    assert "restarted" not in out
    assert "start" not in _verbs(children)  # it never stopped, so there was nothing to start
    assert len(calls) == 1  # the kits were still healed
    assert "stop of 'box' failed" in err


def test_start_on_a_running_sandbox_skips_msb_start_but_heals(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    calls = _spy_heal(monkeypatch, [])
    children.clear()
    rc, _doc, out, err = _acq(capsys, "start", "box")
    assert rc == 0, err
    assert "start" not in _verbs(children) and len(calls) == 1
    assert "already running" in out


def test_start_missing_and_sbx_refusals(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    rc, doc, _out, _err = _acq(capsys, "start", "nope", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.SANDBOX_NOT_FOUND
    assert _calls(children, "start") == []
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    for verb in ("start", "restart"):
        rc, doc, _out, _err = _invoke(capsys, "--backend", "sbx", verb, "box", "--json")
        assert rc == 1 and doc["error"]["code"] == errors.UNSUPPORTED
        assert "acq run box" in doc["error"]["remediation"]


def test_start_refuses_an_unreadable_record_before_starting(monkeypatch, tmp_path, capsys, children):
    _stopped_box(monkeypatch, tmp_path, capsys, secret=False)
    Path(state.record_path("msb", "box")).write_text('{"schema": 99}', encoding="utf-8")
    children.clear()
    rc, doc, _out, _err = _acq(capsys, "start", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.STATE_SCHEMA_UNSUPPORTED
    assert "start" not in _verbs(children)


def test_start_not_exec_ready_is_a_timeout(monkeypatch, tmp_path, capsys):
    _stopped_box(monkeypatch, tmp_path, capsys, secret=False)
    monkeypatch.setenv("ACQ_MSB_READY_TIMEOUT", "0")
    monkeypatch.setattr(msb, "exec_ready", lambda name: False)
    rc, doc, _out, _err = _acq(capsys, "start", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.TIMEOUT
    assert "was started" in doc["error"]["message"]


def test_start_and_restart_are_acq_verbs_not_passthrough():
    assert {"start", "restart"} <= cli.KNOWN_COMMANDS


# ---------------------------------------------------------------------------
# run re-attach heals the kits, as start does (Bash acq_backend_ensure_kits_applied).
# ---------------------------------------------------------------------------

def _launches(monkeypatch) -> list:
    launched: list = []
    monkeypatch.setattr(msb, "launch", lambda name, *a, **k: launched.append(name) or 0)
    return launched


@pytest.mark.parametrize("argv", [["run", "box"], ["run", "shell", "{ws}", "--name", "box"]])
def test_run_reattach_heals_the_recorded_kit_set_then_attaches(monkeypatch, tmp_path, capsys, argv):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path, "--kit", "opencode")
    calls = _spy_heal(monkeypatch, [])
    launched = _launches(monkeypatch)
    argv = [a.replace("{ws}", str(tmp_path / "ws")) for a in argv]
    rc, doc, _out, err = _acq(capsys, *argv, "--json")
    assert rc == 0, (doc, err)
    assert doc["data"]["action"] == "reattached" and launched == ["box"]
    (names, ro, force), = calls
    assert "opencode" in names and "usai-provider" in names  # the .kits record plus the built-ins
    # A heal keeps the read-only requirement wherever the platform can mount it (never on Windows).
    assert force is False and ro is (security.ro_mount_platform_problem() is None)


def test_run_reattach_with_kit_given_again_heals_that_kit_set(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)  # created without --kit
    calls = _spy_heal(monkeypatch, [])
    _launches(monkeypatch)
    rc, doc, _out, err = _acq(capsys, "run", "shell", str(tmp_path / "ws"), "--name", "box", "--kit", "opencode",
                              "--json")
    assert rc == 0, (doc, err)
    (names, _ro, _force), = calls
    assert "opencode" in names


def test_run_reattach_with_an_incomplete_heal_warns_and_attaches(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    monkeypatch.setattr(kit_msb, "ensure_kits_applied",
                        lambda name, kit_set, **_kw: kit_msb.ApplyResult(["usai-provider"], ["git-ssh-sign"]))
    launched = _launches(monkeypatch)
    # An incomplete heal must not rewrite the provenance record.
    stamp = json.loads(kits._provenance_path("msb", "box").read_text(encoding="utf-8"))["recorded_at"]
    rc, doc, _out, err = _acq(capsys, "run", "box", "--json")
    assert rc == 0 and launched == ["box"], (doc, err)
    assert "git-ssh-sign" in err and "attaching anyway" in err
    assert json.loads(kits._provenance_path("msb", "box").read_text(encoding="utf-8"))["recorded_at"] == stamp


def test_run_reattach_to_a_stopped_sandbox_skips_the_heal_with_a_warning(monkeypatch, tmp_path, capsys):
    _stopped_box(monkeypatch, tmp_path, capsys, secret=False)
    calls = _spy_heal(monkeypatch, [])
    launched = _launches(monkeypatch)
    monkeypatch.setattr(sys.modules["acq_py.commands.lifecycle"], "_attach_key_check", lambda *a: None)
    rc, doc, _out, err = _acq(capsys, "run", "box", "--json")
    assert rc == 0 and launched == ["box"], (doc, err)
    assert calls == []
    assert "is not running, so its kits were not re-applied" in err and "acq start box" in err


def test_run_by_name_waits_for_the_sandbox_lock(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    launched = _launches(monkeypatch)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.2")
    with lock.sandbox_lock("msb", "box"):
        rc, doc, _out, _err = _acq(capsys, "run", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.TIMEOUT
    assert launched == []


def test_a_heal_ignores_config_extra_kits_added_after_create(monkeypatch, tmp_path, capsys):
    # The create recorded the extras it applied; a configured default added
    # later is not folded into a heal (Bash folds config extra_kits only into a
    # fresh create). Folded in, it would be refused here as a kit to fetch.
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    cfg = Path(os.environ["XDG_CONFIG_HOME"]) / "acq" / "config.yaml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_text("schema: 1\nextra_kits: openchamber\n", encoding="utf-8")
    calls = _spy_heal(monkeypatch, [])
    rc, doc, _out, err = _acq(capsys, "start", "box", "--json")
    assert rc == 0, (doc, err)
    (names, _ro, _force), = calls
    assert "openchamber" not in names
    _launches(monkeypatch)
    rc, doc, _out, err = _acq(capsys, "run", "box", "--json")
    assert rc == 0 and "not re-applied" not in err, (doc, err)


def test_selection_for_folds_config_extras_into_a_new_sandbox_only(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    cfg = Path(os.environ["XDG_CONFIG_HOME"]) / "acq" / "config.yaml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_text("schema: 1\nextra_kits: paseo\n", encoding="utf-8")
    monkeypatch.delenv("ACQ_EXTRA_KITS", raising=False)

    def extras(sel):
        return [k.ref for k in sel.kits if k.role == "extra"]

    new = kit_msb.selection_for("shell", [], image_is_default=False)
    assert len(extras(new)) == 1 and "paseo" in extras(new)[0]
    assert extras(kit_msb.selection_for("shell", [], image_is_default=False, extras=[])) == []
    # Recorded extras replace ACQ_EXTRA_KITS, including an explicitly empty selection.
    monkeypatch.setenv("ACQ_EXTRA_KITS", "/live/kit")
    assert extras(kit_msb.selection_for("shell", [], image_is_default=False, extras=[])) == []
    assert extras(kit_msb.selection_for("shell", [], image_is_default=False, extras=["/rec/kit"])) == ["/rec/kit"]
