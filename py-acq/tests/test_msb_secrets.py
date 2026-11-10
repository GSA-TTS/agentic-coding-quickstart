"""Tier-2 tests for the msb credential path (acq store + ``--secret ENV@HOST``).

Non-contract evidence (ADR-0039m): these drive ``cli.main`` and the adapter
in-process against the deterministic ``__stub__`` msb. They record every child
process msb is started as, so they prove which bindings are emitted and that a
secret value travels only in the child's environment mapping. The argv check
looks for the value as a substring of every argv element, so a ``--flag=VALUE``
embedding is caught as well as a bare element. Substitution on the wire needs a
live msb and is out of scope here.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import cli, msb, provider_creds, secretstore
from acq_py._stub_msb import main as stub_main

VALUE = "S3NTINEL-msb-value-7c41"
SCOPED = "S3NTINEL-scoped-value-91e2"


def _env(monkeypatch, tmp_path, *, catalog=None):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in (
        "ACQ_BACKEND", "ACQ_MSB_STUB_CATALOG", "ACQ_MSB_STUB_FAIL", "ACQ_IMAGE", "ACQ_MSB_IMAGE",
        "ACQ_PROVIDER_CREDENTIAL_BINDINGS", "ACQ_PROVIDER_CREDENTIAL_SEED", "ACQ_SECRET_NO_LIVE_REFEED",
        "USAI_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "GITLAB_TOKEN", "API_KEY",
    ):
        monkeypatch.delenv(name, raising=False)
    if catalog is not None:
        path = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(catalog), encoding="utf-8")
    (tmp_path / "ws").mkdir(exist_ok=True)


def _stub_records(tmp_path) -> dict:
    path = tmp_path / "msb-home" / ".microsandbox" / "secrets.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


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


def _invoke(capsys, *argv, stdin=None, monkeypatch=None):
    if stdin is not None:
        monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))
    rc = cli.main(list(argv))
    out, err = capsys.readouterr()
    doc = json.loads(out) if out.strip().startswith("{") else None
    return rc, doc, out, err


def _set(capsys, monkeypatch, *args, value=VALUE):
    rc, doc, out, err = _invoke(capsys, "--backend", "msb", "secret", "set", *args, "--json",
                                stdin=value, monkeypatch=monkeypatch)
    assert rc == 0, (doc, err)
    return out, err


def _assert_value_absent(value, children, *streams):
    for argv, _env in children:
        for element in argv:
            assert value not in element, f"value leaked into argv element {element!r}"
    for text in streams:
        assert value not in text


def _verb_calls(children, verb):
    return [(argv, env) for argv, env in children if verb in argv]


# ---------------------------------------------------------------------------
# The binding resolver (single table for create, re-feed, unbind, has, ls).
# ---------------------------------------------------------------------------

def test_service_binding_table(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    assert msb.service_binding("usai") == ("USAI_API_KEY", "api.gsa.usai.gov")
    assert msb.service_binding("github") == ("GITHUB_TOKEN", "github.com,api.github.com,codeload.github.com")
    assert msb.service_binding("github").flag == "GITHUB_TOKEN@github.com,api.github.com,codeload.github.com"
    # An unknown service is never guessed.
    assert msb.service_binding("gitlab") is None
    # A recorded endpoint wins over the fixed table, the sandbox's own first.
    secretstore.meta_store("github", None, "ghe.example.gov", "GITHUB_TOKEN")
    secretstore.meta_store("github", "box", "ghe-box.example.gov", "GH_BOX")
    assert msb.service_binding("github") == ("GITHUB_TOKEN", "ghe.example.gov")
    assert msb.service_binding("github", "box") == ("GH_BOX", "ghe-box.example.gov")
    assert msb.service_binding("github", "other") == ("GITHUB_TOKEN", "ghe.example.gov")


def test_service_binding_refuses_unsafe_mappings(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    # A process-critical env name would hand the value to the msb child as PATH.
    secretstore.meta_store("svc", None, "api.example.gov", "PATH")
    assert msb.service_binding("svc") is None
    # Lower-case env names and wildcard hosts are not bindable either; an unsafe
    # recorded endpoint never falls back to the fixed table.
    secretstore.meta_store("github", None, "*.example.gov", "GITHUB_TOKEN")
    assert msb.service_binding("github") is None
    secretstore.meta_store("svc2", None, "api.example.gov", "lower_env")
    assert msb.service_binding("svc2") is None


def test_provider_pin_resolution(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    provider_creds.set_binding("acme", "ACME_KEY", ["models.acme.gov", "alt.acme.gov"])
    assert msb.service_binding("acme") == ("ACME_KEY", "models.acme.gov,alt.acme.gov")
    assert provider_creds.provider_ids() == ["usai", "acme"]
    # The env layer overrides the durable record.
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "acme=ACME_ENV_KEY@env.acme.gov")
    assert msb.service_binding("acme") == ("ACME_ENV_KEY", "env.acme.gov")
    # A user pin for usai replaces the trust anchor.
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "usai=USAI_API_KEY@usai.example.gov")
    assert msb.service_binding("usai") == ("USAI_API_KEY", "usai.example.gov")
    # A malformed pin binds nothing: it never falls back to the anchor.
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "usai=not-an-env")
    assert msb.service_binding("usai") is None
    assert provider_creds.provider_ids() == ["usai"]
    monkeypatch.delenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS")
    # An unreadable (newer-schema) record also binds nothing.
    provider_creds._binding_path("usai").parent.mkdir(parents=True, exist_ok=True)
    provider_creds._binding_path("usai").write_text('{"schema": 99, "provider": "usai"}', encoding="utf-8")
    assert msb.service_binding("usai") is None
    # A pin with no hosts has no destination.
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_SEED", '[{"provider": "nohost", "key_env": "NOHOST_KEY"}]')
    assert provider_creds.provider_env_hosts("nohost") is None
    assert provider_creds.provider_env_hosts("Bad!") is None


# ---------------------------------------------------------------------------
# Create: --secret ENV@HOST on argv, the value only in the child's env mapping.
# ---------------------------------------------------------------------------

def test_create_binds_and_value_never_in_argv(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    _set(capsys, monkeypatch, "-g", "usai")
    _set(capsys, monkeypatch, "-g", "gitlab", "--host", "workshop.cloud.gov", "--env", "GITLAB_TOKEN",
         value="S3NTINEL-gitlab-0003")
    children.clear()
    rc, doc, out, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"),
                                "--name", "box", "--json")
    assert rc == 0, err
    assert doc["data"]["secret_bindings"] == ["GITLAB_TOKEN@workshop.cloud.gov", "USAI_API_KEY@api.gsa.usai.gov"]
    (argv, env), = _verb_calls(children, "create")
    i = argv.index("--secret")
    assert argv[i:i + 4] == ["--secret", "GITLAB_TOKEN@workshop.cloud.gov", "--secret", "USAI_API_KEY@api.gsa.usai.gov"]
    assert env["USAI_API_KEY"] == VALUE and env["GITLAB_TOKEN"] == "S3NTINEL-gitlab-0003"
    _assert_value_absent(VALUE, children, out, err)
    _assert_value_absent("S3NTINEL-gitlab-0003", children, out, err)
    # Only the create child gets the values; the readiness probe does not.
    for argv2, env2 in children:
        if "create" not in argv2:
            assert env2 is None
    # The stub saw both variables and recorded presence only.
    rec = _stub_records(tmp_path)["box"]
    assert rec["USAI_API_KEY"] == {"host": "api.gsa.usai.gov", "env_present": True}
    assert VALUE not in json.dumps(_stub_records(tmp_path))
    assert "USAI_API_KEY" not in os.environ


def test_create_prefers_the_sandbox_value_over_global(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")  # no provider kit selected: no usai gate or binding
    _set(capsys, monkeypatch, "-g", "github")
    _set(capsys, monkeypatch, "box", "github", value=SCOPED)
    children.clear()
    assert _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"), "--name", "box")[0] == 0
    (_argv, env), = _verb_calls(children, "create")
    assert env["GITHUB_TOKEN"] == SCOPED
    children.clear()
    assert _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"), "--name", "other")[0] == 0
    (_argv, env), = _verb_calls(children, "create")
    assert env["GITHUB_TOKEN"] == VALUE


def test_create_without_secrets_adds_no_flags(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")  # no provider kit selected: no usai gate or binding
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"),
                                  "--name", "box", "--json")
    assert rc == 0 and doc["data"]["secret_bindings"] == []
    (argv, env), = _verb_calls(children, "create")
    assert "--secret" not in argv and env is None


# ---------------------------------------------------------------------------
# Running sandboxes: re-feed on set, unbind on rm.
# ---------------------------------------------------------------------------

def _running(tmp_path, monkeypatch, *names):
    _env(monkeypatch, tmp_path, catalog={n: "running" for n in names} | {"idle": "stopped"})
    # A stopped sandbox acq created with nothing bound: known, so never swept.
    msb.HeldRecord("idle", complete=True).save()


def test_global_set_refeeds_running_sandboxes(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a", "b")
    out, err = _set(capsys, monkeypatch, "-g", "usai")
    modifies = _verb_calls(children, "modify")
    assert sorted(argv[argv.index("modify") + 1] for argv, _ in modifies) == ["a", "b"]
    for argv, env in modifies:
        assert argv[-2:] == ["--secret", "USAI_API_KEY@api.gsa.usai.gov"]
        assert env["USAI_API_KEY"] == VALUE
    _assert_value_absent(VALUE, children, out, err)
    assert set(_stub_records(tmp_path)) == {"a", "b"}  # the stopped sandbox is untouched


def test_global_set_leaves_a_sandbox_with_its_own_value(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a", "b")
    _set(capsys, monkeypatch, "a", "usai", value=SCOPED)
    assert [argv[argv.index("modify") + 1] for argv, _ in _verb_calls(children, "modify")] == ["a"]
    children.clear()
    _set(capsys, monkeypatch, "-g", "usai")
    assert [argv[argv.index("modify") + 1] for argv, _ in _verb_calls(children, "modify")] == ["b"]


def test_refeed_failure_is_reported_not_hidden(monkeypatch, tmp_path, capsys):
    _running(tmp_path, monkeypatch, "a")
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "modify")
    rc, doc, out, err = _invoke(capsys, "--backend", "msb", "secret", "set", "-g", "usai", "--json",
                                stdin=VALUE, monkeypatch=monkeypatch)
    assert rc == 1
    assert doc["error"]["message"].startswith("stored 'usai' in the acq secret store, but could not apply")
    assert "a" in doc["error"]["message"]
    assert secretstore.resolve("usai") == VALUE
    assert VALUE not in out + err


def test_no_live_refeed_is_store_only(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a")
    monkeypatch.setenv("ACQ_SECRET_NO_LIVE_REFEED", "1")
    _set(capsys, monkeypatch, "-g", "usai")
    assert _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai")[0] == 0
    assert _verb_calls(children, "modify") == []


def test_global_rm_unbinds_running_sandboxes(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a", "b")
    _set(capsys, monkeypatch, "-g", "usai")
    _set(capsys, monkeypatch, "b", "usai", value=SCOPED)
    children.clear()
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 0 and doc["data"]["value_state"] == "unset"
    (argv, env), = _verb_calls(children, "modify")  # b keeps its own value
    assert argv[argv.index("modify") + 1:] == ["a", "--secret-rm", "USAI_API_KEY"] and env is None
    assert "USAI_API_KEY" not in _stub_records(tmp_path)["a"]
    assert secretstore.resolve("usai", "b") == SCOPED
    assert not secretstore.exists("usai")


def _modify_tails(children):
    return [argv[argv.index("modify") + 1:] for argv, _env in _verb_calls(children, "modify")]


def test_scoped_rm_falls_back_to_the_global_value(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a")
    _set(capsys, monkeypatch, "-g", "usai")
    _set(capsys, monkeypatch, "a", "usai", value=SCOPED)
    children.clear()
    assert _invoke(capsys, "--backend", "msb", "secret", "rm", "a", "usai")[0] == 0
    # Never a replace in place: remove, then re-add the global value separately.
    assert _modify_tails(children) == [["a", "--secret-rm", "USAI_API_KEY"],
                                       ["a", "--secret", "USAI_API_KEY@api.gsa.usai.gov"]]
    (_argv, env), = [c for c in _verb_calls(children, "modify") if "--secret" in c[0]]
    assert env["USAI_API_KEY"] == VALUE
    _assert_value_absent(VALUE, children)
    _assert_value_absent(SCOPED, children)
    assert _stub_records(tmp_path)["a"]["USAI_API_KEY"]["env_present"] is True
    assert msb.held_read("a").bindings["USAI_API_KEY"]["scope"] == "global"


def test_scoped_rm_with_a_different_env_drops_then_rebinds(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a")
    _set(capsys, monkeypatch, "-g", "svc", "--host", "api.example.gov", "--env", "API_KEY")
    children.clear()
    _set(capsys, monkeypatch, "a", "svc", "--host", "box.example.gov", "--env", "BOX_KEY", value=SCOPED)
    assert _modify_tails(children) == [["a", "--secret-rm", "API_KEY"], ["a", "--secret", "BOX_KEY@box.example.gov"]]
    children.clear()
    assert _invoke(capsys, "--backend", "msb", "secret", "rm", "a", "svc")[0] == 0
    assert _modify_tails(children) == [["a", "--secret-rm", "BOX_KEY"], ["a", "--secret", "API_KEY@api.example.gov"]]
    assert set(_stub_records(tmp_path)["a"]) == {"API_KEY"}


def test_scoped_rm_readd_failure_leaves_no_removed_value(monkeypatch, tmp_path, capsys):
    _running(tmp_path, monkeypatch, "a")
    _set(capsys, monkeypatch, "-g", "usai")
    _set(capsys, monkeypatch, "a", "usai", value=SCOPED)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_ADD", "a")
    rc, _doc, _out, err = _invoke(capsys, "--backend", "msb", "secret", "rm", "a", "usai")
    assert rc == 0
    assert "could not bind the global value there" in err
    assert "USAI_API_KEY" not in _stub_records(tmp_path)["a"]
    assert msb.held_read("a").bindings == {}
    assert not secretstore.exists("usai", "a")


def test_unbind_failure_keeps_the_secret_and_retry_succeeds(monkeypatch, tmp_path, capsys):
    _running(tmp_path, monkeypatch, "a", "b")
    _set(capsys, monkeypatch, "-g", "usai")
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_RM", "b")
    rc, doc, out, err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 1 and doc["error"]["code"] == "unbind_failed"
    assert "sandbox(es): b;" in doc["error"]["message"]
    assert secretstore.resolve("usai") == VALUE  # kept for the retry
    assert "USAI_API_KEY" not in _stub_records(tmp_path)["a"]
    assert VALUE not in out + err
    monkeypatch.delenv("ACQ_MSB_STUB_FAIL_RM")
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 0 and doc["data"]["value_state"] == "unset"
    assert _stub_records(tmp_path) == {"a": {}, "b": {}}


def _stub_bind(tmp_path, name, env, host):
    path = tmp_path / "msb-home" / ".microsandbox" / "secrets.json"
    records = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    records.setdefault(name, {})[env] = {"host": host, "env_present": True}
    path.write_text(json.dumps(records), encoding="utf-8")


def _catalog(tmp_path, **sandboxes):
    path = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
    path.write_text(json.dumps(sandboxes), encoding="utf-8")


def test_unbind_targets_only_the_sandboxes_that_hold_it(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a")
    _set(capsys, monkeypatch, "-g", "usai")
    # b was created by acq after the set with nothing bound (a known, empty
    # record); idle (stopped) is recorded as holding it.
    _catalog(tmp_path, a="running", b="running", idle="stopped")
    msb.HeldRecord("b", complete=True).save()
    msb.HeldRecord("idle", {"USAI_API_KEY": {"service": "usai", "host": "api.gsa.usai.gov", "scope": "global"}},
                   complete=True).save()
    _stub_bind(tmp_path, "idle", "USAI_API_KEY", "api.gsa.usai.gov")
    children.clear()
    rc, _doc, _out, err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 0 and err == ""
    assert sorted(t[0] for t in _modify_tails(children)) == ["a", "idle"]


def test_create_writes_a_record_even_with_no_bindings(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")  # no provider kit selected: no usai gate or binding
    assert _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"), "--name", "box")[0] == 0
    rec = msb.held_read("box")
    assert rec.complete and rec.bindings == {} and rec.knows("usai")
    assert not msb.held_read("never-created").knows("usai")


def test_unrecorded_sandbox_holding_it_is_swept(monkeypatch, tmp_path, capsys, children):
    # A sandbox Bash (or msb directly) created, holding the binding, no record.
    _env(monkeypatch, tmp_path, catalog={"legacy": "running"})
    secretstore.store(secretstore.key_for("usai"), VALUE)
    _stub_bind(tmp_path, "legacy", "USAI_API_KEY", "api.gsa.usai.gov")
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 0 and doc["data"]["value_state"] == "unset"
    assert _modify_tails(children) == [["legacy", "--secret-rm", "USAI_API_KEY"]]
    assert _stub_records(tmp_path)["legacy"] == {}
    assert msb.held_read("legacy").knows("usai") and not msb.held_read("legacy").complete


def test_unrecorded_sandbox_that_cannot_be_confirmed_blocks_rm(monkeypatch, tmp_path, capsys):
    # msb refuses to remove a variable the sandbox does not hold, which acq cannot
    # tell apart from a real failure, so it keeps the secret and says why.
    _env(monkeypatch, tmp_path, catalog={"legacy": "running", "other": "stopped"})
    secretstore.store(secretstore.key_for("usai"), VALUE)
    _stub_bind(tmp_path, "legacy", "USAI_API_KEY", "api.gsa.usai.gov")
    rc, doc, out, err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 1 and doc["error"]["code"] == "unbind_failed"
    assert "acq has no binding record for: other" in doc["error"]["message"]
    assert "legacy" not in doc["error"]["message"]
    assert secretstore.resolve("usai") == VALUE and VALUE not in out + err
    # Once the unconfirmed sandbox is gone, the removal goes through.
    _catalog(tmp_path, legacy="running")
    assert _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai")[0] == 0
    assert secretstore.resolve("usai") is None


def _bash_overwritten(monkeypatch, tmp_path, **catalog):
    """A Bash-created sandbox ``legacy`` whose own value was overwritten by a Bash
    global set: msb holds the global token there, while the acq store still has
    the sandbox's own value too."""
    _env(monkeypatch, tmp_path, catalog=catalog or {"legacy": "running"})
    secretstore.store(secretstore.key_for("usai"), VALUE)
    secretstore.store(secretstore.key_for("usai", "legacy"), SCOPED)
    _stub_bind(tmp_path, "legacy", "USAI_API_KEY", "api.gsa.usai.gov")


def test_global_rm_reasserts_an_unrecorded_sandboxs_own_value(monkeypatch, tmp_path, capsys, children):
    _bash_overwritten(monkeypatch, tmp_path)
    rc, _doc, out, err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 0, err
    assert _modify_tails(children) == [["legacy", "--secret-rm", "USAI_API_KEY"],
                                       ["legacy", "--secret", "USAI_API_KEY@api.gsa.usai.gov"]]
    (_argv, env), = [c for c in _verb_calls(children, "modify") if "--secret" in c[0]]
    assert env["USAI_API_KEY"] == SCOPED  # the sandbox's own value, not the removed global one
    assert msb.held_read("legacy").bindings["USAI_API_KEY"]["scope"] == "sandbox"
    assert secretstore.resolve("usai", "legacy") == SCOPED and not secretstore.exists("usai")
    _assert_value_absent(VALUE, children, out, err)
    _assert_value_absent(SCOPED, children, out, err)


def test_global_rm_reassert_failure_is_unconfirmed(monkeypatch, tmp_path, capsys):
    _bash_overwritten(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_ADD", "legacy")
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 1 and doc["error"]["code"] == "unbind_failed"
    assert "binding record for: legacy" in doc["error"]["message"]
    assert secretstore.resolve("usai") == VALUE


def test_global_rm_own_value_never_bound_is_unconfirmed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"legacy": "running"})
    secretstore.store(secretstore.key_for("usai"), VALUE)
    secretstore.store(secretstore.key_for("usai", "legacy"), SCOPED)
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 1 and doc["error"]["code"] == "unbind_failed"


def _rm_json(capsys, *extra):
    return _invoke(capsys, "--backend", "msb", "secret", "rm", *extra, "--json")


def test_accept_unconfirmed_accepts_only_the_named_sandboxes(monkeypatch, tmp_path, capsys, children):
    # legacy holds the token (swept and confirmed); other never had it.
    _env(monkeypatch, tmp_path, catalog={"legacy": "running", "other": "stopped", "third": "running"})
    secretstore.store(secretstore.key_for("usai"), VALUE)
    _stub_bind(tmp_path, "legacy", "USAI_API_KEY", "api.gsa.usai.gov")
    rc, doc, _out, _err = _rm_json(capsys, "-g", "usai", "--accept-unconfirmed", "other")
    assert rc == 1 and "binding record for: third" in doc["error"]["message"]
    assert secretstore.resolve("usai") == VALUE
    rc, doc, _out, err = _rm_json(capsys, "--accept-unconfirmed", "other,third", "-g", "usai")
    assert rc == 0 and doc["data"]["unconfirmed"] == ["other", "third"]
    assert "could not be confirmed unbound from sandbox(es) other, third" in err
    assert secretstore.resolve("usai") is None
    assert _stub_records(tmp_path)["legacy"] == {}


def test_accept_unconfirmed_never_covers_a_recorded_failure(monkeypatch, tmp_path, capsys):
    _running(tmp_path, monkeypatch, "a")
    _set(capsys, monkeypatch, "-g", "usai")
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_RM", "a")
    rc, doc, _out, _err = _rm_json(capsys, "-g", "usai", "--accept-unconfirmed=a")
    assert rc == 1 and doc["error"]["code"] == "unbind_failed"
    assert secretstore.resolve("usai") == VALUE


def test_accept_unconfirmed_validation(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    secretstore.store(secretstore.key_for("usai"), VALUE)
    for extra in (["--accept-unconfirmed", "bad.name"], ["--accept-unconfirmed", "-x"], ["--accept-unconfirmed"],
                  ["--accept-unconfirmed", "a,,b"]):
        rc, doc, _out, _err = _rm_json(capsys, "-g", "usai", *extra)
        assert rc == 1 and doc["error"]["code"] == "validation_failed", extra
    assert secretstore.resolve("usai") == VALUE
    # With nothing unconfirmed the field is present and empty.
    rc, doc, _out, _err = _rm_json(capsys, "-g", "usai", "--accept-unconfirmed", "nobody")
    assert rc == 0 and doc["data"]["unconfirmed"] == []


def test_accept_unconfirmed_is_refused_where_unsupported(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setenv("ACQ_SBX_STUB_SECRETS", json.dumps({"global": {"usai": "set"}}))
    rc, doc, _out, _err = _invoke(capsys, "--backend", "sbx", "secret", "rm", "-g", "usai",
                                  "--accept-unconfirmed", "x", "--json")
    assert rc == 1 and doc["error"]["code"] == "unsupported_capability"


def test_scoped_rm_on_an_unrecorded_sandbox(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path, catalog={"legacy": "running"})
    secretstore.store(secretstore.key_for("usai"), VALUE)
    secretstore.store(secretstore.key_for("usai", "legacy"), SCOPED)
    _stub_bind(tmp_path, "legacy", "USAI_API_KEY", "api.gsa.usai.gov")
    assert _invoke(capsys, "--backend", "msb", "secret", "rm", "legacy", "usai")[0] == 0
    assert _modify_tails(children) == [["legacy", "--secret-rm", "USAI_API_KEY"],
                                       ["legacy", "--secret", "USAI_API_KEY@api.gsa.usai.gov"]]
    assert msb.held_read("legacy").bindings["USAI_API_KEY"]["scope"] == "global"


def test_rm_clears_the_record_of_a_sandbox_already_gone(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")  # no provider kit selected: no usai gate or binding
    assert _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"), "--name", "box")[0] == 0
    _catalog(tmp_path)  # removed outside acq
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 0 and doc["data"].get("backend_absent") is True
    assert not msb.held_path("box").exists()
    # A binding record alone still counts as a host record to clear.
    msb.HeldRecord("ghost", complete=True).save()
    assert _invoke(capsys, "--backend", "msb", "rm", "ghost")[0] == 0
    assert not msb.held_path("ghost").exists()


def test_global_set_moves_a_running_binding_to_a_new_host(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a")
    _set(capsys, monkeypatch, "-g", "svc", "--host", "old.example.gov", "--env", "API_KEY")
    children.clear()
    _set(capsys, monkeypatch, "-g", "svc", "--host", "new.example.gov", "--env", "API_KEY")
    assert _modify_tails(children) == [["a", "--secret-rm", "API_KEY"], ["a", "--secret", "API_KEY@new.example.gov"]]
    assert _stub_records(tmp_path)["a"] == {"API_KEY": {"host": "new.example.gov", "env_present": True}}
    assert msb.held_read("a").bindings["API_KEY"]["host"] == "new.example.gov"


def test_unreadable_binding_record_fails_closed(monkeypatch, tmp_path, capsys):
    _running(tmp_path, monkeypatch, "a")
    _set(capsys, monkeypatch, "-g", "usai")
    msb.held_path("a").write_text("not json", encoding="utf-8")
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 1 and doc["error"]["code"] == "state_schema_unsupported"
    assert secretstore.resolve("usai") == VALUE
    good = {"schema": 1, "sandbox": "a", "complete": True, "services": [], "bindings": {}}
    entry = {"service": "usai", "host": "api.gsa.usai.gov", "scope": "global"}
    bad_docs = [
        [], {**good, "schema": 2}, {**good, "sandbox": "b"}, {**good, "bindings": []},
        {**good, "complete": "yes"}, {**good, "services": "usai"}, {**good, "services": [1]},
        {**good, "bindings": {"K": 1}}, {**good, "bindings": {"USAI_API_KEY": {"service": "usai"}}},
        # Keys must be bindable env names before acq ever passes one to msb.
        {**good, "bindings": {"PATH": entry}}, {**good, "bindings": {"lower_key": entry}},
        {**good, "bindings": {"--secret-rm": entry}},
    ]
    msb.held_path("a").write_text(json.dumps({**good, "bindings": {"USAI_API_KEY": entry}}), encoding="utf-8")
    assert msb.held_read("a").bindings == {"USAI_API_KEY": entry}
    for bad in [json.dumps(d) for d in bad_docs]:
        msb.held_path("a").write_text(bad, encoding="utf-8")
        with pytest.raises(msb.MsbError):
            msb.held_read("a")


def test_rm_warns_when_no_binding_resolves(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    secretstore.store(secretstore.key_for("orphan"), VALUE)
    rc, _doc, _out, err = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "orphan")
    assert rc == 0 and "'orphan' has no msb binding to resolve" in err


def test_unlisted_sandboxes_fail_closed(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(msb, "running_names", lambda **_kw: None)
    with pytest.raises(msb.MsbError) as info:
        msb.secret_feed(secretstore.GLOBAL, "usai", "")
    assert info.value.code == "failure"


# ---------------------------------------------------------------------------
# secret has: "can be injected", the sandbox scope before the global one.
# ---------------------------------------------------------------------------

def _has(*args) -> int:
    return cli.main(["--backend", "msb", "secret", "has", *args])


def test_has_scope_precedence(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _set(capsys, monkeypatch, "box", "usai", value=SCOPED)
    assert _has("box", "usai") == 0
    assert _has("-g", "usai") == 1  # a sandbox value never reads as global
    assert _has("other", "usai") == 1
    _set(capsys, monkeypatch, "-g", "usai")
    assert _has("other", "usai") == 0  # a sandbox can be injected with the global value
    assert _has("global", "usai") == 0  # a sandbox named `global` falls back too
    assert secretstore.resolve("usai", "box") == SCOPED
    assert capsys.readouterr() == ("", "")


def test_has_needs_a_binding(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    # Stored outside acq (or under an older mapping): a value with no binding
    # cannot be injected, so `has` says no.
    secretstore.store(secretstore.key_for("orphan"), VALUE)
    assert _has("-g", "orphan") == 1


# ---------------------------------------------------------------------------
# secret set preflight, secret ls, provider-credential set.
# ---------------------------------------------------------------------------

def test_set_refuses_what_msb_cannot_inject(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    for args in (["-g", "orphan"], ["-g", "svc", "--host", "api.example.gov", "--env", "PATH"],
                 ["-g", "svc", "--host", "api.example.gov", "--env", "lower_env"]):
        rc, doc, out, err = _invoke(capsys, "--backend", "msb", "secret", "set", *args, "--json",
                                    stdin=VALUE, monkeypatch=monkeypatch)
        assert rc == 1 and doc["error"]["code"] == "validation_failed", args
        assert VALUE not in out + err
    assert secretstore.list_keys() == []


def test_ls_reports_bindings_and_filters_by_scope_kind(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _set(capsys, monkeypatch, "-g", "usai")
    _set(capsys, monkeypatch, "global", "github", value=SCOPED)
    secretstore.store(secretstore.key_for("orphan"), VALUE)
    secretstore.store("acq.a.b.c", VALUE)  # a legacy multi-dot key
    rc, doc, out, _err = _invoke(capsys, "--backend", "msb", "secret", "ls", "--json")
    assert rc == 0 and VALUE not in out and SCOPED not in out
    assert doc["data"]["secrets"] == [
        {"scope": "?", "scope_kind": "unknown", "service": "a.b.c", "value_state": "set", "binding": None},
        # The sandbox named `global`: scope reads "global", scope_kind says sandbox.
        {"scope": "global", "scope_kind": "sandbox", "service": "github", "value_state": "set",
         "binding": "GITHUB_TOKEN@github.com,api.github.com,codeload.github.com"},
        {"scope": "global", "scope_kind": "global", "service": "orphan", "value_state": "set", "binding": None},
        {"scope": "global", "scope_kind": "global", "service": "usai", "value_state": "set",
         "binding": "USAI_API_KEY@api.gsa.usai.gov"},
    ]
    assert [e["service"] for e in msb.secret_ls(secretstore.GLOBAL)] == ["orphan", "usai"]
    assert [e["service"] for e in msb.secret_ls(secretstore.sandbox_scope("global"))] == ["github"]


def test_provider_credential_set_stores_and_refeeds(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a")
    rc, doc, out, err = _invoke(capsys, "--backend", "msb", "provider-credential", "set", "acme", "ACME_KEY",
                                "--host", "models.acme.gov", "--json", stdin=VALUE, monkeypatch=monkeypatch)
    assert rc == 0, err
    assert doc["data"] == {"provider": "acme", "key_env": "ACME_KEY", "hosts": ["models.acme.gov"],
                           "source_layer": "provider-credentials"}
    assert secretstore.resolve("acme") == VALUE
    (argv, env), = _verb_calls(children, "modify")
    assert argv[-2:] == ["--secret", "ACME_KEY@models.acme.gov"] and env["ACME_KEY"] == VALUE
    _assert_value_absent(VALUE, children, out, err)
    # The recorded pin makes the provider bindable at the next create.
    assert msb.service_binding("acme") == ("ACME_KEY", "models.acme.gov")
    assert _has("-g", "acme") == 0


def test_provider_partial_refeed_then_rm_fully_revokes(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")  # no provider kit selected: no usai gate or binding
    for name in ("a", "b"):  # created by acq, so their records are complete
        assert _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"), "--name", name)[0] == 0
        _forget_selection(name)  # the recorded "no provider kits" would keep the provider out of both
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_ADD", "b")
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "provider-credential", "set", "acme", "ACME_KEY",
                                  "--host", "models.acme.gov", "--json", stdin=VALUE, monkeypatch=monkeypatch)
    assert rc == 1 and "b" in doc["error"]["message"]
    # The pin was recorded first, so rm resolves the same binding re-feed used.
    assert msb.service_binding("acme") == ("ACME_KEY", "models.acme.gov")
    assert set(_stub_records(tmp_path)["a"]) == {"ACME_KEY"} and _stub_records(tmp_path).get("b", {}) == {}
    monkeypatch.delenv("ACQ_MSB_STUB_FAIL_ADD")
    assert _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "acme")[0] == 0
    assert all("ACME_KEY" not in held for held in _stub_records(tmp_path).values())
    assert msb.held_read("a").bindings == {} and secretstore.resolve("acme") is None


def test_provider_rm_unbinds_and_deletes_the_credential(monkeypatch, tmp_path, capsys, children):
    # Removing the destination pin must not leave the credential injected: rm
    # unbinds it from the sandboxes holding it and deletes the stored value.
    _running(tmp_path, monkeypatch, "a", "b")
    rc, _doc, _out, err = _invoke(capsys, "--backend", "msb", "provider-credential", "set", "acme", "ACME_KEY",
                                  "--host", "models.acme.gov", "--json", stdin=VALUE, monkeypatch=monkeypatch)
    assert rc == 0, err
    assert all("ACME_KEY" in _stub_records(tmp_path)[n] for n in ("a", "b"))
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_RM", "b")
    rc, doc, out, err = _invoke(capsys, "--backend", "msb", "provider-credential", "rm", "acme", "--json")
    assert rc == 1 and doc["error"]["code"] == "unbind_failed"
    assert "binding was kept" in doc["error"]["message"]
    assert provider_creds.get_binding("acme") is not None and secretstore.resolve("acme") == VALUE
    monkeypatch.delenv("ACQ_MSB_STUB_FAIL_RM")
    children.clear()
    rc, doc, out, err = _invoke(capsys, "--backend", "msb", "provider-credential", "rm", "acme", "--json")
    assert rc == 0, err
    assert doc["data"] == {"provider": "acme", "removed": True, "credential_removed": True}
    assert all("ACME_KEY" not in held for held in _stub_records(tmp_path).values())
    assert secretstore.resolve("acme") is None and provider_creds.get_binding("acme") is None
    assert msb.held_read("b").bindings == {}
    _assert_value_absent(VALUE, children, out, err)


def test_provider_rm_accept_unconfirmed(monkeypatch, tmp_path, capsys):
    # A sandbox acq has no record for cannot be confirmed unbound; rm names the
    # provider-credential command to accept it, and the flag passes through.
    _env(monkeypatch, tmp_path, catalog={"other": "stopped"})
    provider_creds.set_binding("acme", "ACME_KEY", ["models.acme.gov"])
    secretstore.store(secretstore.key_for("acme"), VALUE)
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "provider-credential", "rm", "acme", "--json")
    assert rc == 1 and doc["error"]["code"] == "unbind_failed"
    assert "acq provider-credential rm acme --accept-unconfirmed NAME" in doc["error"]["remediation"]
    assert provider_creds.get_binding("acme") is not None and secretstore.resolve("acme") == VALUE
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "provider-credential", "rm", "acme",
                                  "--accept-unconfirmed", "bad.name", "--json")
    assert rc == 1 and doc["error"]["code"] == "validation_failed"
    rc, doc, _out, err = _invoke(capsys, "--backend", "msb", "provider-credential", "rm", "acme",
                                 "--accept-unconfirmed", "other", "--json")
    assert rc == 0, err
    assert doc["data"] == {"provider": "acme", "removed": True, "credential_removed": True, "unconfirmed": ["other"]}
    assert secretstore.resolve("acme") is None and provider_creds.get_binding("acme") is None


def test_provider_reset_same_value_refused_restores_the_binding(monkeypatch, tmp_path, capsys, children):
    # The stored value is unchanged when msb refuses a re-set of the SAME value
    # under a new destination, so the previous binding must come back.
    _running(tmp_path, monkeypatch, "a")
    _set(capsys, monkeypatch, "-g", "acme", "--host", "old.acme.gov", "--env", "ACME_OLD")
    provider_creds.set_binding("acme", "ACME_OLD", ["old.acme.gov"])
    before = provider_creds._binding_path("acme").read_bytes()
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "provider-credential", "set", "acme", "ACME_KEY",
                                  "--host", "models.acme.gov", "--json", stdin=VALUE, monkeypatch=monkeypatch)
    assert rc == 1 and doc["error"]["code"] == "validation_failed"
    assert provider_creds._binding_path("acme").read_bytes() == before
    assert secretstore.resolve("acme") == VALUE


def test_provider_pin_refuses_a_diverging_endpoint_record(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a")
    _set(capsys, monkeypatch, "-g", "acme", "--host", "old.acme.gov", "--env", "ACME_OLD", value="S3NTINEL-old")
    children.clear()
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "provider-credential", "set", "acme", "ACME_KEY",
                                  "--host", "models.acme.gov", "--json", stdin=VALUE, monkeypatch=monkeypatch)
    assert rc == 1 and doc["error"]["code"] == "validation_failed"
    assert "ACME_OLD@old.acme.gov" in doc["error"]["message"]
    assert provider_creds.get_binding("acme") is None
    assert secretstore.resolve("acme") == "S3NTINEL-old" and _verb_calls(children, "modify") == []
    # A record naming the same destination is consistent and allowed.
    rc, _doc, _out, err = _invoke(capsys, "--backend", "msb", "provider-credential", "set", "acme", "ACME_OLD",
                                  "--host", "old.acme.gov", "--json", stdin=VALUE, monkeypatch=monkeypatch)
    assert rc == 0, err
    assert msb.held_read("a").bindings["ACME_OLD"]["host"] == "old.acme.gov"


def test_provider_set_skips_a_sandbox_with_its_own_value(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a", "b")
    secretstore.store(secretstore.key_for("acme", "a"), SCOPED)
    rc, _doc, _out, err = _invoke(capsys, "--backend", "msb", "provider-credential", "set", "acme", "ACME_KEY",
                                  "--host", "models.acme.gov", "--json", stdin=VALUE, monkeypatch=monkeypatch)
    assert rc == 0, err
    assert [t[0] for t in _modify_tails(children)] == ["b"]


def test_scoped_set_targets_only_that_sandbox(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a", "b")
    _set(capsys, monkeypatch, "b", "github", value=SCOPED)
    assert _modify_tails(children) == [["b", "--secret", "GITHUB_TOKEN@github.com,api.github.com,codeload.github.com"]]
    assert msb.held_read("b").bindings["GITHUB_TOKEN"]["scope"] == "sandbox" and msb.held_read("a").bindings == {}


def _forget_selection(sandbox):
    """Drop the recorded provider selection, as for a sandbox from before it was recorded."""
    from acq_py import kits

    path = kits._provenance_path("msb", sandbox)
    doc = json.loads(path.read_text(encoding="utf-8"))
    del doc["provider_selection"]
    path.write_text(json.dumps(doc), encoding="utf-8")


def _record_selection(sandbox, provider_kits):
    """Record the provider selection ``sandbox`` was created with (``""`` is
    ``--no-provider-kits``), as create does."""
    from acq_py import kits

    with kits.provider_kits_env(provider_kits):
        kits.provenance_write("msb", sandbox)


def test_global_set_skips_a_sandbox_whose_recorded_selection_leaves_the_provider_out(
        monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a", "b", "c")
    _record_selection("a", "")  # created with --no-provider-kits
    _record_selection("b", None)  # the default selection: usai's kit is in it
    # "c" has no recorded selection (from before it was recorded): re-fed as before.
    out, err = _set(capsys, monkeypatch, "-g", "usai")
    assert sorted(t[0] for t in _modify_tails(children)) == ["b", "c"]
    assert msb.held_read("a").bindings == {}
    _assert_value_absent(VALUE, children, out, err)
    # A service that is not a provider is not subject to provider selection.
    children.clear()
    _set(capsys, monkeypatch, "-g", "github")
    assert sorted(t[0] for t in _modify_tails(children)) == ["a", "b", "c"]


def test_global_set_refeeds_a_held_binding_even_when_the_selection_leaves_the_provider_out(
        monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a")
    _record_selection("a", "")
    rec = msb.HeldRecord("a", complete=True)
    rec.bindings["USAI_API_KEY"] = {"service": "usai", "host": "api.gsa.usai.gov", "scope": "global"}
    rec.save()
    out, err = _set(capsys, monkeypatch, "-g", "usai")
    (argv, env), = _verb_calls(children, "modify")
    assert argv[-3:] == ["a", "--secret", "USAI_API_KEY@api.gsa.usai.gov"] and env["USAI_API_KEY"] == VALUE
    _assert_value_absent(VALUE, children, out, err)


def test_scoped_provider_set_notes_a_sandbox_whose_selection_leaves_it_out(monkeypatch, tmp_path, capsys, children):
    _running(tmp_path, monkeypatch, "a")
    _record_selection("a", "")
    out, err = _set(capsys, monkeypatch, "a", "usai")
    assert _verb_calls(children, "modify") == []
    assert ("acq: note: 'usai' is stored for sandbox 'a', but it will not reach that sandbox: its "
            "provider selection excludes the provider (recreate it to change the selection)") in err
    assert secretstore.resolve("usai", "a") == VALUE
    _assert_value_absent(VALUE, children, out, err)
    # A global change says nothing: most sandboxes are simply not meant to get it.
    _out, global_err = _set(capsys, monkeypatch, "-g", "usai")
    assert "acq: note:" not in global_err


def test_refeed_with_an_unreadable_recorded_selection_fails_closed_for_that_sandbox(
        monkeypatch, tmp_path, capsys, children):
    from acq_py import kits

    _running(tmp_path, monkeypatch, "a", "b")
    _record_selection("a", "")
    kits._provenance_path("msb", "a").write_text("{not json", encoding="utf-8")
    rc, doc, out, err = _invoke(capsys, "--backend", "msb", "secret", "set", "-g", "usai", "--json",
                                stdin=VALUE, monkeypatch=monkeypatch)
    assert rc == 1 and doc["error"]["code"] == "failure"
    assert "a (sandbox 'a' has an unreadable recorded provider selection)" in doc["error"]["message"]
    assert [t[0] for t in _modify_tails(children)] == ["b"]  # never fed to "a"; the others still are
    assert secretstore.resolve("usai") == VALUE
    _assert_value_absent(VALUE, children, out, err)


@pytest.mark.parametrize("argv, takes_lock", [
    (["secret", "set", "b", "github"], True),
    (["secret", "rm", "b", "github"], True),
    (["secret", "set", "a", "github"], False),
    (["secret", "set", "-g", "github"], False),
])
def test_sandbox_scoped_set_and_rm_take_the_sandbox_lock(monkeypatch, tmp_path, capsys, children, argv, takes_lock):
    # A create of 'b' holds its lifecycle lock while it reads the store to bind
    # it; a scoped change to 'b' must wait for it rather than race it.
    from acq_py import errors, lock

    _running(tmp_path, monkeypatch, "a", "b")
    secretstore.store(secretstore.key_for("github", "b"), SCOPED)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.2")
    children.clear()
    with lock.sandbox_lock("msb", "b"):
        rc, doc, out, err = _invoke(capsys, "--backend", "msb", *argv, "--json", stdin=VALUE, monkeypatch=monkeypatch)
    if takes_lock:
        assert rc == 1 and doc["error"]["code"] == errors.TIMEOUT
        assert "sandbox 'b'" in doc["error"]["message"]
        assert secretstore.resolve("github", "b") == SCOPED and _verb_calls(children, "modify") == []
    else:
        assert rc == 0, (doc, err)
    _assert_value_absent(VALUE, children, out, err)


def test_create_first_claim_wins_for_a_shared_env(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")  # no provider kit selected: no usai gate or binding
    # Records written outside this preflight (e.g. by Bash) can share a variable.
    for service, value in (("svc1", "S3NTINEL-one"), ("svc2", "S3NTINEL-two")):
        secretstore.set_secret(service, None, value, "api.example.gov", "SHARED_KEY")
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"),
                                  "--name", "box", "--json")
    assert rc == 0 and doc["data"]["secret_bindings"] == ["SHARED_KEY@api.example.gov"]
    (argv, env), = _verb_calls(children, "create")
    assert argv.count("--secret") == 1 and env["SHARED_KEY"] == "S3NTINEL-one"
    assert msb.held_read("box").bindings["SHARED_KEY"]["service"] == "svc1"


def test_refeed_keeps_the_first_claim(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")  # no provider kit selected: no usai gate or binding
    secretstore.set_secret("svc1", None, "S3NTINEL-one", "api.example.gov", "SHARED_KEY")
    assert _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"), "--name", "box")[0] == 0
    secretstore.set_secret("svc2", None, "S3NTINEL-two", "api.example.gov", "SHARED_KEY")
    children.clear()
    msb.secret_feed(secretstore.GLOBAL, "svc2", "")
    assert _verb_calls(children, "modify") == []
    assert "SHARED_KEY is already bound there for 'svc1'" in capsys.readouterr().err


def test_refeed_without_a_readable_value_fails(monkeypatch, tmp_path, capsys):
    _running(tmp_path, monkeypatch, "a")
    monkeypatch.setattr(secretstore, "resolve", lambda service, sandbox=None: None)
    with pytest.raises(msb.MsbError) as info:
        msb.secret_feed(secretstore.GLOBAL, "usai", "")
    assert "a (no injectable value)" in info.value.message


def test_set_refuses_another_services_env(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    provider_creds.set_binding("acme", "ACME_KEY", ["models.acme.gov"])
    _set(capsys, monkeypatch, "-g", "svc1", "--host", "api.example.gov", "--env", "API_KEY")
    for env, why in (("GITHUB_TOKEN", "reserved for 'github'"), ("USAI_API_KEY", "reserved for 'usai'"),
                     ("ACME_KEY", "provider 'acme'"), ("API_KEY", "already bound for 'svc1'")):
        rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "secret", "set", "-g", "svc2", "--host",
                                      "api.example.gov", "--env", env, "--json", stdin=VALUE, monkeypatch=monkeypatch)
        assert rc == 1 and why in doc["error"]["message"], env
    assert not secretstore.exists("svc2")
    # A service may keep its own reserved variable on another host.
    _set(capsys, monkeypatch, "-g", "github", "--host", "ghe.example.gov", "--env", "GITHUB_TOKEN")


def test_binding_host_checks(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    assert not msb._binding_ok("API_KEY", "api..example.gov")
    assert not msb._binding_ok("API_KEY", "api.example.gov,")
    assert msb._binding_ok("API_KEY", "api.example.gov:8443,alt.example.gov")
    # acq refuses to write such a sidecar, but Bash's looser check can: plant one
    # directly, and msb must still ignore it.
    with pytest.raises(secretstore.SecretStoreError):
        secretstore.meta_store("svc", None, "api..example.gov", "API_KEY")
    meta = secretstore._file_for(secretstore._layout().meta_dir, secretstore.key_for("svc"))
    meta.parent.mkdir(parents=True, exist_ok=True)
    meta.write_text("api..example.gov\tAPI_KEY\n", encoding="utf-8")
    assert msb.service_binding("svc") is None
    _set(capsys, monkeypatch, "-g", "svc2", "--host", "API.Example.GOV", "--env", "API_KEY2")
    assert msb.service_binding("svc2") == ("API_KEY2", "api.example.gov")


def test_create_that_cannot_record_its_bindings_is_undone(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _set(capsys, monkeypatch, "-g", "usai")

    def boom(rec):
        raise msb.MsbError("failure", f"could not record the secrets bound to sandbox '{rec.name}'")

    monkeypatch.setattr(msb, "_held_write", boom)
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"),
                                  "--name", "box", "--json")
    assert rc == 1 and "could not record" in doc["error"]["message"]
    assert not msb.exists("box")


def test_capability_record_declares_the_secret_verbs():
    caps = msb.capability_record()["capabilities"]
    assert caps["secret-write"] == caps["secret-rm"] == caps["secret-list"] == "required"
    # Rotation stores the new key and re-feeds running sandboxes (msb modify --secret).
    assert caps["key-rotate"] == "required"


# ---------------------------------------------------------------------------
# The stub models what the real msb needs and records presence, never a value.
# ---------------------------------------------------------------------------

def _stub(monkeypatch, tmp_path, *args) -> int:
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.delenv("ACQ_MSB_STUB_CATALOG", raising=False)
    return stub_main(["msb", *args])


def test_stub_refuses_a_value_on_argv(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("TOK", VALUE)
    assert _stub(monkeypatch, tmp_path, "create", "--name", "x", f"--label={VALUE}", "--secret", "TOK@h.example") == 1
    assert _stub(monkeypatch, tmp_path, "create", "--name", "x", "--secret", f"TOK={VALUE}@h.example") == 1
    assert _stub(monkeypatch, tmp_path, "create", "--name", "x", "--secret", "MISSING@h.example") == 1
    err = capsys.readouterr().err
    assert VALUE not in err and "MISSING is not set" in err
    assert _stub(monkeypatch, tmp_path, "create", "--name", "x", "--secret", "TOK@h.example", "img") == 0
    assert _stub_records(tmp_path) == {"x": {"TOK": {"host": "h.example", "env_present": True}}}
    assert _stub(monkeypatch, tmp_path, "modify", "x", "--secret", "TOK@h.example") == 0  # rotate
    assert _stub(monkeypatch, tmp_path, "modify", "x", "--secret", "TOK@other.example") == 1  # no replace
    assert _stub(monkeypatch, tmp_path, "modify", "x", "--secret-rm", "NOPE") == 1
    assert _stub(monkeypatch, tmp_path, "modify", "x", "--secret-rm", "TOK") == 0
    assert _stub(monkeypatch, tmp_path, "modify", "nobox", "--secret-rm", "TOK") == 1
    assert _stub(monkeypatch, tmp_path, "remove", "x") == 0
    assert _stub_records(tmp_path) == {}
    assert VALUE not in Path(tmp_path / "msb-home").joinpath(".microsandbox", "secrets.json").read_text()
