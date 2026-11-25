"""The credential apply write protocol, end to end against the stub msb (ADR-0053).

Each test drives a real CLI verb or adapter call and reads the evidence off disk
the way a consumer would. The stub msb stands in for the backend; its side
effects on failure are modelled where a test needs them.
"""

from __future__ import annotations

import io
import json
import sys

import pytest

from acq_py import cli, msb, secretstore, state

pytestmark = pytest.mark.provider_key

VALUE = "S3NTINEL-protocol-value-8d31"
ROTATED = "S3NTINEL-protocol-rotated-52ce"


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
    # The provider_key fixture stored its key before the state directory moved, so
    # no revision evidence exists here; store it again under this state directory.
    secretstore.set_secret("usai", None, "test-usai-key-not-a-secret")


def _acq(capsys, *argv, stdin=None, monkeypatch=None):
    if stdin is not None:
        monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))
    rc = cli.main(["--backend", "msb", *argv])
    out, err = capsys.readouterr()
    return rc, (json.loads(out) if out.strip().startswith("{") else None), out, err


def _create(capsys, tmp_path, name="box"):
    rc, doc, _out, err = _acq(capsys, "create", "shell", str(tmp_path / "ws"), "--name", name, "--json")
    assert rc == 0, (doc, err)


def _set(capsys, monkeypatch, *args, value=VALUE):
    rc, doc, _out, err = _acq(capsys, "secret", "set", *args, "--json", stdin=value, monkeypatch=monkeypatch)
    return rc, doc, err


def _apply(name="box", service="usai"):
    return json.loads(msb.held_path(name).read_text(encoding="utf-8"))["apply"].get(service)


def _status(name="box", service="usai"):
    return msb.held_apply_snapshot(name).services[service].status


def test_create_promotes_only_after_the_guest_is_ready_and_trusted(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    with monkeypatch.context() as patch:
        patch.setattr(msb, "confirm_delivery", lambda name: [])
        _create(capsys, tmp_path)
    entry = _apply()
    assert entry["status"] == "pending" and entry["applied_revision"] is None
    assert _status() == "pending"
    assert msb.confirm_delivery("box") == ["usai"]
    assert _apply()["status"] == "applied" and _apply()["applied_revision"] == _apply()["revision"]
    assert _status() == "applied" and msb.held_apply_snapshot("box").reuse_eligible is False


def test_pending_is_on_disk_before_msb_create_runs(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    seen = {}
    real = msb._run

    def spy(argv, **kwargs):
        if argv and argv[0] == "create":
            seen["entry"] = _apply()
            seen["instance"] = json.loads(msb.held_path("box").read_text())["instance"]
        return real(argv, **kwargs)

    monkeypatch.setattr(msb, "_run", spy)
    _create(capsys, tmp_path)
    assert seen["entry"]["status"] == "pending" and seen["instance"].startswith("i:")


def test_a_failed_create_leaves_no_record_to_inherit(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "create")
    rc, _doc, _out, _err = _acq(capsys, "create", "shell", str(tmp_path / "ws"), "--name", "box", "--json")
    assert rc == 1 and not msb.held_path("box").exists()


def test_recreating_a_name_starts_from_a_new_instance(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    first = json.loads(msb.held_path("box").read_text())["instance"]
    assert _acq(capsys, "rm", "box", "--json")[0] == 0
    _create(capsys, tmp_path)
    second = json.loads(msb.held_path("box").read_text())
    assert second["instance"] != first and second["apply"]["usai"]["status"] == "applied"


def test_a_running_modify_stays_pending_even_when_msb_accepts_it(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    assert _status() == "applied"
    rc, _doc, _err = _set(capsys, monkeypatch, "-g", "usai", value=ROTATED)
    assert rc == 0
    assert _apply()["status"] == "pending" and _apply()["applied_revision"] is None
    assert _status() == "pending"


def test_a_rejected_modify_settles_as_failed_never_unchanged(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_ADD", "box")
    rc, _doc, _err = _set(capsys, monkeypatch, "-g", "usai", value=ROTATED)
    assert rc == 1
    assert _apply()["status"] == "failed" and _apply()["applied_revision"] is None
    assert _status() == "failed"


def test_a_modify_that_times_out_leaves_pending(monkeypatch, tmp_path, capsys):
    import subprocess

    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    real = msb._run

    def slow(argv, **kwargs):
        if argv and argv[0] == "modify" and "--secret" in argv:
            raise subprocess.TimeoutExpired(argv, 1)
        return real(argv, **kwargs)

    monkeypatch.setattr(msb, "_run", slow)
    secretstore.set_secret("usai", None, ROTATED)
    with pytest.raises(subprocess.TimeoutExpired):
        msb._refeed("usai", secretstore.GLOBAL)
    assert _apply()["status"] == "pending" and _status() == "pending"


def test_a_start_promotes_what_it_delivered_after_readiness(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    _set(capsys, monkeypatch, "-g", "usai", value=ROTATED)
    assert _status() == "pending"
    assert _acq(capsys, "stop", "box", "--json")[0] == 0
    assert _acq(capsys, "start", "box", "--json")[0] == 0
    assert _status() == "applied"
    entry = _apply()
    assert entry["applied_revision"] == entry["revision"]


def test_starting_an_already_running_sandbox_promotes_nothing(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    _set(capsys, monkeypatch, "-g", "usai", value=ROTATED)
    assert _status() == "pending"
    assert _acq(capsys, "start", "box", "--json")[0] == 0
    assert _status() == "pending"


def test_a_stale_attempt_cannot_promote(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    secretstore.set_secret("usai", None, ROTATED)
    msb._begin_start_attempts("box")  # a start's own attempt, which a later one replaces mid-confirmation
    real = msb.held_update

    def racing(name, mutate, **kwargs):
        real(name, lambda rec: rec.apply["usai"].update(attempt="t:" + "8" * 32))
        return real(name, mutate, **kwargs)

    monkeypatch.setattr(msb, "held_update", racing)
    assert msb.confirm_delivery("box") == ["usai"]  # it saw the begun attempt as ready...
    assert _apply()["status"] == "pending" and _apply()["applied_revision"] is None  # ...but the CAS refused


def test_a_completion_for_a_removed_record_cannot_resurrect_it(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    _set(capsys, monkeypatch, "-g", "usai", value=ROTATED)
    instance = msb.held_read("box").instance
    msb.held_path("box").unlink()
    assert msb.held_update("box", lambda rec: rec.note("usai"), expect_instance=instance) is None
    assert not msb.held_path("box").exists()


def test_removal_drops_the_applied_evidence_before_the_binding_goes(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    seen = {}
    real = msb._run

    def spy(argv, **kwargs):
        if argv and argv[0] == "modify" and "--secret-rm" in argv:
            seen["during"] = _apply()
        return real(argv, **kwargs)

    monkeypatch.setattr(msb, "_run", spy)
    assert _acq(capsys, "secret", "rm", "-g", "usai", "--json")[0] == 0
    assert seen["during"] is None and _apply() is None
    assert "usai" not in {e["service"] for e in msb.held_read("box").bindings.values()}


def test_a_secret_import_changes_the_revision_without_claiming_delivery(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    assert _status() == "applied"
    monkeypatch.setenv("USAI_API_KEY", ROTATED)
    rc, _doc, _out, _err = _acq(capsys, "secret", "import", "usai", "-g", "--force", "--json")
    assert rc == 0
    assert _status() == "pending"
    assert _apply()["status"] == "applied"  # persisted evidence is unchanged; the comparison invalidates it


def test_no_state_file_holds_a_credential_value(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    _set(capsys, monkeypatch, "-g", "usai", value=ROTATED)
    _acq(capsys, "stop", "box", "--json")
    _acq(capsys, "start", "box", "--json")
    for path in (p for p in state.state_dir().rglob("*") if p.is_file()):
        data = path.read_bytes()
        assert VALUE.encode() not in data and ROTATED.encode() not in data, path


def test_a_change_after_the_attempt_is_never_labelled_as_delivered(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    _set(capsys, monkeypatch, "-g", "usai", value=ROTATED)  # an attempt, pending
    captured = _apply()["revision"]
    secretstore.set_secret("usai", None, VALUE)  # the store moves on before any confirmation
    assert msb.confirm_delivery("box") == []
    assert _apply()["status"] == "pending" and _apply()["revision"] == captured
    assert _apply()["applied_revision"] is None


def test_a_failed_pending_write_prevents_the_backend_call(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    calls = []
    real = msb._run

    def spy(argv, **kwargs):
        calls.append(argv[0])
        return real(argv, **kwargs)

    def broken(rec):
        raise msb.MsbError("failure", "could not record the secrets bound to sandbox")

    monkeypatch.setattr(msb, "_run", spy)
    monkeypatch.setattr(msb, "_write_pending_probe", broken, raising=False)
    monkeypatch.setattr(msb, "_held_write", broken)
    rc, _doc, _err = _set(capsys, monkeypatch, "-g", "usai", value=ROTATED)
    assert rc == 1 and "modify" not in calls


def _child(script, tmp_path, *argv):
    import os
    import subprocess
    import textwrap

    env = os.environ.copy()
    env["PYTHONPATH"] = os.pathsep.join(sys.path)
    return subprocess.Popen([sys.executable, "-c", textwrap.dedent(script), *argv], env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def test_a_process_killed_between_pending_and_the_backend_call_leaves_pending(monkeypatch, tmp_path, capsys):
    import threading

    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    secretstore.set_secret("usai", None, ROTATED)
    script = '''
        import sys
        from acq_py import msb
        def hang(*args, **kwargs):
            print("before-backend-call", flush=True)
            sys.stdin.read(1)
        msb._modify = hang
        msb._refeed("usai", msb.secretstore.GLOBAL)
    '''
    child = _child(script, tmp_path)
    line: list[str] = []
    reader = threading.Thread(target=lambda: line.append(child.stdout.readline()), daemon=True)
    reader.start()
    try:
        reader.join(30)
        assert line == ["before-backend-call\n"], child.stderr.read() if child.poll() is not None else line
        child.kill()
        child.wait(timeout=15)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=15)
        for stream in (child.stdin, child.stdout, child.stderr):
            stream.close()
    assert _apply()["status"] == "pending" and _status() == "pending"
    # The dead child's locks were released by the OS: the next change proceeds.
    assert _set(capsys, monkeypatch, "-g", "usai", value=VALUE)[0] == 0


def test_concurrent_scoped_and_global_sets_lose_no_binding_or_evidence(monkeypatch, tmp_path, capsys):
    import os

    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    secretstore.set_secret("github", None, VALUE)
    script = '''
        import io, sys
        from acq_py import cli
        sys.stdin = io.StringIO(sys.argv[3])
        rc = cli.main(["--backend", "msb", "secret", "set", sys.argv[1], sys.argv[2], "--json"])
        sys.exit(rc)
    '''
    jobs = [("-g", "usai", ROTATED + "-1"), ("box", "github", ROTATED + "-2"), ("-g", "github", ROTATED + "-3"),
            ("box", "usai", ROTATED + "-4")]
    children = [_child(script, tmp_path, *job) for job in jobs]
    results = [child.communicate(input=None, timeout=120) for child in children]
    assert [child.returncode for child in children] == [0, 0, 0, 0], results
    held = msb.held_read("box")
    assert {entry["service"] for entry in held.bindings.values()} == {"usai", "github"}
    for service in ("usai", "github"):
        assert held.apply[service]["status"] in ("pending", "failed")
        assert _status(service=service) in ("pending", "failed", "unknown")
    assert ROTATED.encode() not in b"".join(p.read_bytes() for p in state.state_dir().rglob("*") if p.is_file())
    assert os.listdir(state.state_dir() / "locks")


def test_a_refeed_attempt_made_while_a_start_proves_delivery_is_not_promoted_by_it(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _create(capsys, tmp_path)
    assert _acq(capsys, "stop", "box", "--json")[0] == 0
    secretstore.set_secret("usai", None, ROTATED)
    msb._begin_start_attempts("box")  # what a start does just before `msb start`
    begun = _apply()["attempt"]
    # A concurrent global change re-feeds the (now running) guest: its own attempt, still unproven.
    secretstore.set_secret("usai", None, VALUE)
    rec = msb.held_read("box")
    assert msb._put(rec, msb.BoundSecret("usai", msb.service_binding("usai"), False), VALUE)
    assert _apply()["attempt"] != begun and _apply()["status"] == "pending"
    assert msb.confirm_delivery("box") == []
    assert _apply()["status"] == "pending" and _apply()["applied_revision"] is None


def test_a_late_write_cannot_resurrect_a_removed_legacy_or_absent_record():
    secretstore.set_secret("usai", None, VALUE)
    path = msb.held_path("old")
    path.parent.mkdir(parents=True)
    binding = {"service": "usai", "host": "api.gsa.usai.gov", "scope": "global"}
    path.write_text(json.dumps({"schema": 1, "sandbox": "old", "complete": True, "services": [],
                                "bindings": {"USAI_API_KEY": binding}}), encoding="utf-8")
    legacy = msb.held_read("old")
    assert legacy.present and legacy.instance is None
    path.unlink()  # `acq rm` between the read and the write
    with pytest.raises(msb.MsbError):
        msb._held_apply(legacy, lambda r: r.note("usai"))
    assert not path.exists()
    absent = msb.held_read("never-created")
    assert not absent.present
    msb.HeldRecord("never-created", complete=True).save()  # created by someone else meanwhile
    with pytest.raises(msb.MsbError):
        msb._held_apply(absent, lambda r: r.note("usai"))
    assert "usai" not in msb.held_read("never-created").services


def test_a_value_only_write_does_not_clear_an_interrupted_endpoint_write(monkeypatch):
    key = secretstore.key_for("example")
    secretstore.set_secret("example", None, "first", "api.example.com", "EXAMPLE_KEY")
    original = secretstore._stage_atomic

    def fail_metadata(path, content):
        if path.parent.name == "meta":
            raise OSError("synthetic metadata failure")
        return original(path, content)

    with monkeypatch.context() as patch:
        patch.setattr(secretstore, "_stage_atomic", fail_metadata)
        with pytest.raises(secretstore.SecretStoreError):
            secretstore.set_secret("example", None, "second", "new.example.com", "EXAMPLE_KEY")
    secretstore.store(key, "third")  # an import or rotation: value only
    record = json.loads((state.state_dir() / "secret-rev" / f"{key}.json").read_text())
    assert record["pending"] is not None
    assert secretstore.current_revision(key) is None
    secretstore.set_secret("example", None, "fourth", "new.example.com", "EXAMPLE_KEY")
    assert secretstore.current_revision(key) is not None


def test_a_malformed_revision_record_breaks_neither_create_nor_a_rewrite(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    (state.state_dir() / "secret-rev").mkdir(parents=True, exist_ok=True)
    (state.state_dir() / "secret-rev" / "acq.usai.json").write_text("{not json")
    _create(capsys, tmp_path)  # evidence is simply unknown
    assert _apply()["status"] == "unknown" and _status() == "unknown"
    assert _set(capsys, monkeypatch, "-g", "usai", value=ROTATED)[0] == 0  # the write replaces it
    assert secretstore.current_revision("acq.usai") is not None


def test_secret_tool_clear_of_an_absent_item_is_not_a_failure(monkeypatch):
    calls = []

    def tool(argv, stdin=None):
        calls.append(argv[1])
        return (1, "") if argv[1] in ("clear", "lookup") else (0, "")

    monkeypatch.setattr(secretstore, "backend_name", lambda: "keychain-linux")
    monkeypatch.setattr(secretstore.hostexec, "which", lambda name: "/bin/secret-tool")
    monkeypatch.setattr(secretstore, "_run_tool", tool)
    secretstore.delete("acq.absent")  # nonzero clear, item confirmed absent by lookup
    assert calls == ["clear", "lookup"]
