"""Fresh terminal profile selection at the real kit planning/dispatch seams.

No no-op preparation barrier is used. Native terminal handoff qualification is
separate from these offline selection tests.
"""

from dataclasses import replace
from contextlib import contextmanager
import json
from types import SimpleNamespace

import pytest

from acq_py import fresh_inputs, fresh_launch, kit_msb, kitspec, msb, msb_preparation, provider_input, provider_validator, security
from acq_py.commands import common, lifecycle, session
from acq_py.runtime_preparation import parse_result


@pytest.fixture
def selection(monkeypatch):
    entries = tuple(kitspec.SelectedKit(kitspec.builtin_kit_ref(name), role, name)
                    for name, role in kit_msb._FRESH_PROFILE)
    selected = kitspec.KitSelection(entries, 4, 5, None)
    monkeypatch.setattr(kit_msb, "selection_for", lambda *args, **kwargs: selected)
    return selected


def test_real_plan_suppresses_only_legacy_renderer_without_mutating_bundle(selection):
    original = kitspec.load_bundled_kit("opencode")
    plan, code = lifecycle._plan_msb_kits(
        "opencode", [], common.OPENCODE_DEVENV_IMAGE, "create", True,
    )
    assert code is None and plan is not None
    prepared = plan.kits
    adapted = next(kit.spec for kit in prepared if kit.name == "opencode")
    assert adapted.commands == tuple(cmd for cmd in original.commands
                                     if cmd.argv != kit_msb._LEGACY_RENDERER)
    assert len(original.commands) == len(adapted.commands) + 1
    assert kitspec.load_bundled_kit("opencode") == original
    assert kit_msb.startup_body(next(k for k in prepared if k.name == "opencode"), [], ro_mount=True)
    script = kit_msb.startup_script(prepared, [], ro_mount=True)
    assert script is not None and "render-provider-config" not in script


@pytest.mark.parametrize("kind", ["daemon", "team", "custom", "provider", "image", "windows"])
def test_negative_profile_refuses_before_resolution_or_fetch(selection, monkeypatch, kind, capsys):
    selected = selection
    if kind in ("daemon", "team", "custom"):
        name = {"daemon": "opencode-server", "team": "opencode-team", "custom": "custom"}[kind]
        selected = replace(selection, kits=(*selection.kits, kitspec.SelectedKit("/custom/" + name, "extra", None)))
    elif kind == "provider":
        selected = replace(selection, kits=tuple(replace(entry, ref="/custom/provider", bundled=None)
                                                if entry.role == "provider" else entry for entry in selection.kits))
    monkeypatch.setattr(kit_msb, "selection_for", lambda *args, **kwargs: selected)
    monkeypatch.setattr(kit_msb, "WINDOWS", kind == "windows")

    def forbidden(*args, **kwargs):
        pytest.fail("unsupported profile reached bundle resolution/fetch")

    monkeypatch.setattr(kit_msb, "resolve", forbidden)
    plan, code = lifecycle._plan_msb_kits(
        "opencode", [], "custom-image" if kind == "image" else common.OPENCODE_DEVENV_IMAGE,
        "create", True,
    )
    assert plan is None and code != 0
    assert "plain packaged" in capsys.readouterr().out


def test_other_agents_keep_existing_selection_path(selection, monkeypatch):
    marker = []
    monkeypatch.setattr(kit_msb, "resolve", lambda selected: marker)
    assert kit_msb.select("shell", [], image_is_default=False) is marker


def test_every_plain_profile_selection_suppresses_legacy_renderer(selection):
    selected = kit_msb.select("opencode", [], image_is_default=True)
    assert kit_msb.is_fresh_profile(selected)
    assert all(cmd.argv != kit_msb._LEGACY_RENDERER for kit in selected for cmd in kit.spec.commands)


def test_changed_renderer_shape_refuses(selection):
    selected = kit_msb.resolve(selection)
    bad = [replace(kit, spec=replace(kit.spec, commands=())) if kit.name == "opencode" else kit
           for kit in selected]
    with pytest.raises(msb.MsbError, match="renderer shape"):
        kit_msb.fresh_commands(bad)


@pytest.fixture
def operational(tmp_path, monkeypatch, selection):
    """Real mounted receipts/coordinator/parser; only backend/store boundaries fake."""
    monkeypatch.setattr(provider_input, "input_root", lambda backend, name: tmp_path / "inputs" / name)
    monkeypatch.setattr(provider_validator, "validate_bundles", lambda paths: None)
    inputs = fresh_inputs.prepare("box")
    host = tmp_path / "host"
    host.mkdir()
    monkeypatch.setattr(security, "host_config_dir", lambda name: host)
    binding = {"service": "usai", "host": "api.gsa.usai.gov", "scope": "global"}
    current = SimpleNamespace(env="USAI_API_KEY", host="api.gsa.usai.gov", revision=None)
    snapshot = SimpleNamespace(instance="i:" + "1" * 32, services={"usai": SimpleNamespace(current=current)})
    monkeypatch.setattr(msb, "held_read", lambda name: SimpleNamespace(complete=True, bindings={"USAI_API_KEY": binding}, instance=snapshot.instance))
    monkeypatch.setattr(msb, "held_apply_snapshot", lambda name, **kwargs: snapshot)
    events = []

    @contextmanager
    def store():
        events.append("store-enter")
        try:
            yield
        finally:
            events.append("store-exit")

    monkeypatch.setattr(msb, "store_shared", store)
    doc = {"name": "box", "status": "Running", "pending_changes": [], "created_at": "instance-1",
           "storage": {"path": "/trusted/msb/sandboxes/box"}, "active_config": {
               "deployment_profile": "single_tenant", "image": {"Oci": {"reference": common.OPENCODE_DEVENV_IMAGE}},
               "env": [{"key": provider_input.ROOT_ENV, "value": inputs.guest_root}],
               "mounts": [{"guest": guest, "host": str(source), "type": "Bind", "options": {"readonly": True}}
                          for guest, source in [(inputs.guest_root, inputs.generation), (security.HOST_CONFIG_GUEST_DIR, host)]],
               "network": {"tls": {"enabled": True, "verify_upstream": True, "bypass": [],
                                    "scoped_verify_upstream": [], "intercept_ca": {"cert_path": None}},
                           "secrets": {"secrets": [{"env_var": "USAI_API_KEY", "allowed_hosts": [{"exact": "api.gsa.usai.gov"}],
                               "require_tls_identity": True, "placeholder": "$MSB_USAI_API_KEY", "passthrough_hosts": [],
                               "substitution": {"headers": True, "body": False, "query": False},
                               "source": {"kind": "env", "var": "USAI_API_KEY"}}]}}}}
    monkeypatch.delenv("MSB_HOME", raising=False)
    monkeypatch.setattr(msb, "msb_command", lambda: ["/trusted/msb"])
    monkeypatch.setattr(fresh_launch, "_public_ca", lambda path: b"public-certificate-fixture")
    monkeypatch.setattr(msb_preparation, "_capabilities", lambda *args: None)

    def control(command, args, deadline):
        if args[0] == "inspect":
            events.append("inspect")
            return json.dumps(doc).encode()
        assert args[0] == "jobs"
        return b'{"items":[],"next_cursor":null}'

    monkeypatch.setattr(msb_preparation, "_control", control)
    old = tmp_path / "old-config"
    old.write_text("old configuration")

    def producer(command, name, identity, argv, user, deadline, previous, env):
        events.append("producer")
        assert user == "agent" and argv[:2] == ("/bin/sh", "-c")
        assert msb_preparation.PROFILE_NODE in argv
        assert argv[argv.index("--provider-root") + 1] == inputs.guest_root
        assert tuple(env) == msb_preparation._INITIAL_ENV
        return parse_result(identity, returncode=0, stdout=b'{"sourceOutcome":"live","metadataOutcome":"not-requested"}')

    monkeypatch.setattr(msb_preparation, "_run_job", producer)
    return SimpleNamespace(doc=doc, inputs=inputs, events=events, snapshot=snapshot, old=old, host=host, producer=producer)


def test_real_coordinator_accepts_fresh_success_with_unknown_revision(operational):
    fresh_launch.prepare_locked("box")
    assert operational.events == ["store-enter", "inspect", "producer", "inspect", "store-exit"]
    assert not list(operational.host.glob("preparation-ca-*"))


@pytest.mark.parametrize("change", ["instance", "binding", "mount", "ca"])
def test_changed_identity_refuses_completed_success(operational, monkeypatch, change):
    def producer(*args):
        result = operational.producer(*args)
        if change == "instance":
            operational.doc["created_at"] = "replacement"
        elif change == "binding":
            operational.doc["active_config"]["network"]["secrets"]["secrets"][0]["allowed_hosts"] = []
        elif change == "mount":
            operational.doc["active_config"]["mounts"][0]["options"]["readonly"] = False
        else:
            monkeypatch.setattr(fresh_launch, "_public_ca", lambda path: b"rotated")
        return result
    monkeypatch.setattr(msb_preparation, "_run_job", producer)
    with pytest.raises(msb.MsbError):
        fresh_launch.prepare_locked("box")


def test_lifecycle_failure_with_old_config_emits_no_success(operational, monkeypatch, capsys):
    def failed(command, name, identity, *args):
        return parse_result(identity, returncode=1, stdout=(
            b'{"schemaVersion":"acq-runtime-model-outcome/v1","outcome":"failure",'
            b'"stage":"membership","reason":"connection","failureClass":"transient"}'))
    monkeypatch.setattr(msb_preparation, "_run_job", failed)
    monkeypatch.setattr(kit_msb, "check_prereqs", lambda name: None)
    monkeypatch.setattr(kit_msb, "ensure_kits_applied", lambda *args, **kwargs: kit_msb.ApplyResult(applied=["opencode"]))
    monkeypatch.setattr(lifecycle.ssh_agent, "forwarding_sock", lambda name: None)
    plan, code = lifecycle._plan_msb_kits("opencode", [], common.OPENCODE_DEVENV_IMAGE, "create", True)
    assert code is None
    result, code = lifecycle._apply_msb_kits("box", plan, [], "create", True, ro_required=True)
    assert result is None and code != 0
    envelope = json.loads(capsys.readouterr().out)
    assert "error" in envelope and "data" not in envelope
    assert operational.old.read_text() == "old configuration"


@pytest.mark.parametrize("command", ["exec", "shell"])
def test_public_commands_refuse_missing_record_before_guest_effects(monkeypatch, capsys, command):
    monkeypatch.setattr(msb, "exists", lambda name: True)
    records = iter([{"agent": "opencode"}, None])
    monkeypatch.setattr(session.state, "record_read", lambda *args: next(records))
    monkeypatch.setattr(session, "prepare_session", lambda *args: pytest.fail("public bypass reached guest setup"))
    parsed = SimpleNamespace(name="box", cmd=["anything"])
    rc = getattr(session, "run_" + command)(parsed, True, "msb")
    assert rc != 0 and "unsupported" in capsys.readouterr().out


@pytest.mark.parametrize("ending", ["normal", "term", "hup", "handoff", "uncertain", "ack-refused", "preparation-failed", "interrupt-ack",
                                    "hup-control", "hup-recheck", "hup-sync"])
@pytest.mark.parametrize("verb", ["attach", "exec", "shell"])
def test_attach_dispatch_prepares_acknowledges_under_locks_then_waits(operational, monkeypatch, capsys, ending, verb, request):
    from acq_py import kits, lock
    from acq_py.cli import _Terminated
    import signal

    hup = ending == "hup" or ending.startswith("hup-")
    interruption = _Terminated(signal.SIGHUP if hup else signal.SIGTERM)
    if ending.startswith("hup-"):
        def cli_hup(signum, frame):
            assert signum == signal.SIGHUP
            raise interruption
        previous_hup = signal.getsignal(signal.SIGHUP)
        signal.signal(signal.SIGHUP, cli_hup)
        # Restore even if an assertion below fails; the fixture owns this install.
        request.addfinalizer(lambda: signal.signal(signal.SIGHUP, previous_hup))

    events = operational.events
    record = {"agent": "opencode", "image": common.OPENCODE_DEVENV_IMAGE}
    monkeypatch.setattr(msb, "exists", lambda name: True)
    monkeypatch.setattr(session.state, "record_read", lambda *args: record)
    monkeypatch.setattr(kit_msb, "cli_kits_read", lambda name: ([], []))

    @contextmanager
    def selected(*args):
        yield

    @contextmanager
    def sandbox(*args):
        if "sandbox-exit" in events:
            yield  # cleanup reacquires the same lifecycle lock after handoff
            return
        events.append("sandbox-enter")
        try:
            yield
        finally:
            events.append("sandbox-exit")
            if ending == "handoff":
                raise interruption

    monkeypatch.setattr(kits, "recorded_provider_selection", selected)
    monkeypatch.setattr(lock, "sandbox_lock", sandbox)
    monkeypatch.setattr(session, "prepare_session", lambda *args: [])
    monkeypatch.setattr(msb, "start_directory", lambda name: None)
    monkeypatch.setattr(msb, "agent_shell", lambda name: "/bin/sh")
    monkeypatch.setattr(fresh_launch.hostexec, "stdin_is_tty", lambda: True)
    monkeypatch.setattr(fresh_launch.hostexec, "terminal_env", lambda: ["TERM=xterm"])
    launched = []
    opaque = ["printf", "%s", "spaces and ; $(not-host-code)", "", "--standalone"]
    payload = {"attach": ["/usr/local/bin/opencode", "--standalone"],
               "exec": opaque, "shell": ["/bin/sh", "-l"]}[verb]
    expected_tty = verb != "exec"

    def invoke():
        return getattr(session, "run_" + verb)(SimpleNamespace(name="box", cmd=list(opaque)), True, "msb")

    class Foreground:
        def __init__(self, argv, **kwargs):
            events.append("foreground")
            assert events[-2] == "inspect"  # actual identity recheck immediately before spawn
            assert "producer" in events and "store-exit" not in events
            assert kwargs == {"stdout": 2}  # stdin/stderr inherited, no capture/replay
            assert ("--tty" in argv) is expected_tty and "--no-stdin" not in argv
            assert ("--no-tty" in argv) is not expected_tty
            entries = [argv[i + 1] for i, token in enumerate(argv) if token == "-e"]
            ca = next(entry.split("=", 1)[1] for entry in entries if entry.startswith("NODE_EXTRA_CA_CERTS="))
            assert "SSL_CERT_FILE=" + ca in entries
            assert "NODE_TLS_REJECT_UNAUTHORIZED=1" in entries
            self.ca = operational.host / ca.rsplit("/", 1)[1]
            assert self.ca.read_bytes() == b"public-certificate-fixture"
            launched.extend(argv[argv.index("--") + 1:])
            assert launched == ["/bin/sh", "-c", 'exec "$@"', launched[3], *payload]
            assert launched[3].startswith("acq-launch-")
            self.ended = False

        def wait(self, timeout=None):
            if timeout is not None:
                assert self.ended
                events.append("host-reaped")
                return -signal.SIGTERM
            assert events[-1] == "sandbox-exit"
            assert self.ca.read_bytes() == b"public-certificate-fixture"
            # Only the session copy remains once preparation ends.
            assert list(operational.host.glob("preparation-ca-*")) == [self.ca]
            events.append("wait")
            if ending == "interrupt-ack":
                self.ended = True
                return -signal.SIGINT
            if ending != "normal":
                raise interruption  # parent only; fake child receives no group signal
            self.ended = True
            return 7

        def poll(self):
            return 7 if self.ended else None

        def send_signal(self, signum):
            assert signum == (signal.SIGHUP if hup else signal.SIGTERM)
            self.ended = True
            events.append("host-terminate")

        def kill(self):
            pytest.fail("responsive host process required no kill")

    monkeypatch.setattr(fresh_launch.subprocess, "Popen", Foreground)
    original = msb_preparation._control

    def masked_hup():
        events.append("parent-hup")
        try:
            signal.getsignal(signal.SIGHUP)(signal.SIGHUP, None)
        except BaseException:
            raise msb_preparation.ManagedJobError("synthetic finalizer masked signal")

    if ending == "hup-sync":
        original_write = fresh_launch._write_attempt
        def interrupted_sync(owner, phase):
            if phase == "active" and "parent-hup" not in events:
                masked_hup()
            return original_write(owner, phase)
        monkeypatch.setattr(fresh_launch, "_write_attempt", interrupted_sync)

    def control(command, args, deadline):
        if ending == "hup-recheck" and args[:2] == ["inspect", "box"] and "ack" in events and "parent-hup" not in events:
            masked_hup()
        if args[0] in ("signal", "kill"):
            assert args[1:3] == ["--job", "job_" + "a" * 32]
            events.append("guest-" + args[0])
            return b""
        if args[:2] == ["inspect", "--job"]:
            assert args == ["inspect", "--job", "job_" + "a" * 32, "--format", "json", "box"]
            if ending == "hup-control" and "parent-hup" not in events:
                masked_hup()
            if ending == "ack-refused" or (ending == "uncertain" and "wait" in events):
                raise msb_preparation.ManagedJobError("synthetic exact-job status unavailable")
            exited = ending in ("normal", "interrupt-ack") or "guest-signal" in events
            return json.dumps({"id": "job_" + "a" * 32, "version": 1,
                "runtime_boot_id": "boot_" + "b" * 32, "command": launched, "tty": expected_tty,
                "stdin_closed": False, "pid": 123, "created_at": 100, "started_at": 101,
                "finished_at": 102 if exited else None, "exit_code": 7 if exited else None,
                "state": "exited" if exited else "running",
                "failure": None, "error": None, "timed_out": False}).encode()
        if args[0] == "jobs":
            assert args == ["jobs", "--all", "--limit", "100", "--format", "json", "box"]
        if args[0] == "jobs" and launched:
            events.append("ack")
            if ending == "interrupt-ack":
                handler = signal.getsignal(signal.SIGINT)
                assert handler is fresh_launch.hostexec._ignore_interrupt
                handler(signal.SIGINT, None)
            return json.dumps({"items": [{"id": "job_" + "a" * 32, "version": 1,
                    "runtime_boot_id": "boot_" + "b" * 32, "command": launched, "tty": expected_tty,
                "state": "running", "failure": None, "error": None, "timed_out": False}],
                "next_cursor": None}).encode()
        return original(command, args, deadline)

    monkeypatch.setattr(msb_preparation, "_control", control)
    if ending == "interrupt-ack":
        died = []
        monkeypatch.setattr(fresh_launch.hostexec, "_die_of_interrupt", lambda: died.append("SIGINT"))
        assert invoke() == 130
        assert died == ["SIGINT"]
        assert "host-terminate" not in events
        assert not list(operational.host.glob("preparation-ca-*"))
        return
    if ending == "preparation-failed":
        def refused(command, name, identity, *args):
            return parse_result(identity, returncode=1, stdout=(
                b'{"schemaVersion":"acq-runtime-model-outcome/v1","outcome":"failure",'
                b'"stage":"membership","reason":"authentication","failureClass":"hard"}'))
        monkeypatch.setattr(msb_preparation, "_run_job", refused)
        assert invoke() != 0
        assert "foreground" not in events and "wait" not in events
        assert not list(operational.host.glob("preparation-ca-*"))
        assert "error" in json.loads(capsys.readouterr().out)
        return
    if ending == "ack-refused":
        assert invoke() != 0
        assert "wait" not in events
        assert "host-terminate" in events and "host-reaped" in events
        assert kit_msb.hc_has("box", "fresh-quarantine")
        assert len(list(operational.host.glob("preparation-ca-*"))) == 1
        envelope = json.loads(capsys.readouterr().out)
        assert "error" in envelope and "data" not in envelope
        return
    if ending != "normal":
        with pytest.raises(_Terminated) as caught:
            invoke()
        assert caught.value is interruption
        assert "host-terminate" in events and "host-reaped" in events
        assert events.index("sandbox-exit") < events.index("host-terminate")
        if ending == "uncertain":
            assert kit_msb.hc_has("box", "fresh-quarantine")
            assert len(list(operational.host.glob("preparation-ca-*"))) == 1
        else:
            assert "guest-signal" in events
            assert not list(operational.host.glob("preparation-ca-*"))
        assert not capsys.readouterr().out
        return
    rc = invoke()
    assert rc == 7
    assert events.index("producer") < events.index("foreground") < events.index("ack") < events.index("store-exit")
    assert events[-3:] == ["store-exit", "sandbox-exit", "wait"]
    assert not list(operational.host.glob("preparation-ca-*"))
    assert json.loads(capsys.readouterr().out)["data"]["exit_code"] == 7


def test_active_binding_refusal_happens_before_guest_preparation(operational):
    operational.doc["active_config"]["network"]["secrets"]["secrets"][0]["require_tls_identity"] = False
    with pytest.raises(msb.MsbError):
        fresh_launch.prepare_locked("box")
    assert "producer" not in operational.events


def test_mount_source_not_current_pointer_is_authoritative(operational):
    operational.doc["active_config"]["mounts"][0]["host"] = str(operational.inputs.generation.parent.parent / "current")
    with pytest.raises(msb.MsbError):
        fresh_launch.prepare_locked("box")
    assert "producer" not in operational.events


def test_create_provider_stage_uses_real_fresh_generation(operational, monkeypatch, selection):
    monkeypatch.setattr(lifecycle, "_provider_gate", lambda *args, **kwargs: [])
    monkeypatch.setattr(provider_input, "record_write", lambda *args: None)
    plan, code = lifecycle._plan_msb_kits("opencode", [], common.OPENCODE_DEVENV_IMAGE, "create", True)
    assert code is None
    generation = lifecycle._provider_prepare("box", plan.kits, ro_mount=True)
    receipt = fresh_inputs.read_existing("box", generation)
    assert receipt.generation != operational.inputs.generation
    assert provider_input.msb_flags(generation)[1].endswith(":" + receipt.guest_root + ":ro")
    assert not (generation.parent.parent / "current").exists()


@pytest.mark.parametrize("command", ["start", "restart"])
def test_start_negative_profile_precedes_resume_or_stop(selection, monkeypatch, command, capsys):
    from acq_py import kits

    bad = replace(selection, kits=selection.kits[:-1])
    monkeypatch.setattr(kit_msb, "selection_for", lambda *args, **kwargs: bad)
    monkeypatch.setattr(kit_msb, "cli_kits_read", lambda name: ([], []))
    monkeypatch.setattr(lifecycle, "_start_record", lambda *args: ({"agent": "opencode", "image": common.OPENCODE_DEVENV_IMAGE}, None))

    @contextmanager
    def selected(*args):
        yield

    monkeypatch.setattr(kits, "recorded_provider_selection", selected)
    monkeypatch.setattr(lifecycle, "_resume", lambda *args: pytest.fail("unsupported profile resumed/stopped"))
    monkeypatch.setattr(msb, "held_flags", lambda *args: pytest.fail("unsupported profile reached binding setup"))
    assert lifecycle._start_locked(command, "box", True) != 0
    assert "error" in json.loads(capsys.readouterr().out)


def test_trust_refusal_precedes_legacy_profile_and_all_guest_effects(monkeypatch, capsys):
    from acq_py import lock

    @contextmanager
    def sandbox(*args):
        yield

    monkeypatch.setattr(lock, "sandbox_lock", sandbox)
    monkeypatch.setattr(session.state, "record_read", lambda *args: {"agent": "opencode", "ro_host_config": True})
    monkeypatch.setattr(security, "mount_check", lambda *args, **kwargs: ("missing", "fixture missing mount"))
    monkeypatch.setattr(security, "ro_mount_version_problem", lambda: None)
    monkeypatch.setattr(fresh_launch, "existing_profile", lambda *args: pytest.fail("profile hid security exception"))
    monkeypatch.setattr(session, "prepare_session", lambda *args: pytest.fail("untrusted guest setup"))
    assert session.fresh_attach("box", True, command="run") != 0
    assert json.loads(capsys.readouterr().out)["error"]["code"] == "security_exception"


def test_session_ca_removed_on_acknowledgment_refusal_before_spawn(operational, monkeypatch):
    monkeypatch.setattr(msb, "start_directory", lambda name: None)
    monkeypatch.setattr(msb, "agent_shell", lambda name: "/bin/sh")
    monkeypatch.setattr(fresh_launch.hostexec, "stdin_is_tty", lambda: False)

    def unavailable(*args, **kwargs):
        assert len(list(operational.host.glob("preparation-ca-*"))) == 2
        raise OSError("synthetic executable unavailable")

    monkeypatch.setattr(fresh_launch.subprocess, "Popen", unavailable)
    from acq_py import lock

    @contextmanager
    def no_reacquisition(*args):
        pytest.fail("confirmed pre-child failure must retire its attempt under the already-held lifecycle lock")
        yield

    monkeypatch.setattr(lock, "sandbox_lock", no_reacquisition)
    with pytest.raises(msb.MsbError):
        with fresh_launch.own_launch("box") as owner:
            fresh_launch.admit_locked("box", None, ["NODE_EXTRA_CA_CERTS=/unapproved", "SSL_CERT_FILE=/unapproved"],
                                       json_mode=False, ownership=owner)
    assert not list(operational.host.glob("preparation-ca-*"))
    assert owner.completed and owner.proc is None and not owner.spawned
    assert not list(fresh_launch._attempts("box").iterdir())
    assert not kit_msb.hc_has("box", "fresh-quarantine")
    fresh_launch._admission_attempts("box")


@pytest.mark.parametrize("condition", ["failed-preparation", "quarantine", "agent-args"])
def test_other_agent_token_cannot_reattach_recorded_opencode(monkeypatch, tmp_path, capsys, condition):
    from acq_py import lock

    @contextmanager
    def sandbox(*args):
        yield

    monkeypatch.setattr(lock, "sandbox_lock", sandbox)
    monkeypatch.setattr(msb, "exists", lambda name: True)
    monkeypatch.setattr(lifecycle.state, "record_read", lambda *args: {"agent": "opencode"})
    monkeypatch.setattr(lifecycle, "_scope_advice", lambda *args: pytest.fail("mismatch reached effects"))
    monkeypatch.setattr(lifecycle, "_heal_on_reattach", lambda *args: pytest.fail("mismatch healed"))
    monkeypatch.setattr(lifecycle, "_launch_after_envelope", lambda *args: pytest.fail("mismatch launched"))
    monkeypatch.setattr(fresh_launch, "admit_locked", lambda *args, **kwargs: pytest.fail("mismatch admitted"))
    if condition == "quarantine":
        host = tmp_path / "host"
        host.mkdir()
        monkeypatch.setattr(security, "host_config_dir", lambda name: host)
        kit_msb.hc_write("box", "fresh-quarantine", "1")
    parsed = SimpleNamespace(target="shell", path=str(tmp_path), name="box", kit=[], image=None,
                             publish=[], clone=False, agent_args=["serve"] if condition == "agent-args" else [])
    monkeypatch.setattr(lifecycle, "_create_opts", lambda *args: (lifecycle._NO_OPTS, None))
    assert lifecycle._run_run(parsed, True, "msb") != 0
    assert "error" in json.loads(capsys.readouterr().out)


def test_real_kit_update_caller_refuses_before_kit_application(selection, monkeypatch, capsys):
    from acq_py.commands import kit as kit_command

    record = {"agent": "opencode", "image": common.OPENCODE_DEVENV_IMAGE, "ro_host_config": True}
    monkeypatch.setattr(kit_command, "_trusted_record", lambda *args: (record, None))
    monkeypatch.setattr(msb, "running_names", lambda: ["box"])
    monkeypatch.setattr(kit_command.ssh_agent, "ensure_forward", lambda name: None)
    monkeypatch.setattr(kit_msb, "cli_kits_read", lambda name: ([], []))
    monkeypatch.setattr(kit_msb, "ensure_agent_user", lambda *args: pytest.fail("update reached guest setup"))
    monkeypatch.setattr(kit_msb, "apply_kit", lambda *args, **kwargs: pytest.fail("update rendered snapshot"))
    assert kit_command._kit_update_locked("box", True, "msb") != 0
    assert "error" in json.loads(capsys.readouterr().out)


def test_single_kit_apply_cannot_restore_snapshot_renderer(selection, monkeypatch):
    monkeypatch.setattr(kit_msb.state, "record_read", lambda *args: {"agent": "opencode"})
    monkeypatch.setattr(kit_msb, "apply_kit", lambda *args, **kwargs: pytest.fail("single kit rendered"))
    original = next(kit for kit in kit_msb.resolve(selection) if kit.name == "opencode")
    with pytest.raises(msb.MsbError, match="single-kit"):
        kit_msb.apply_single("box", original, ro_required=True)


@pytest.mark.parametrize("paginated", [False, True])
def test_foreground_full_or_incomplete_inventory_refuses_before_spawn(monkeypatch, paginated):
    monkeypatch.setattr(msb, "msb_command", lambda: ["/trusted/msb"])

    def control(command, args, deadline):
        assert args == ["jobs", "--all", "--limit", "100", "--format", "json", "box"]
        return json.dumps({"items": [{"id": "job_" + format(i, "032x")} for i in range(100)],
                           "next_cursor": "more" if paginated else None}).encode()

    monkeypatch.setattr(msb_preparation, "_control", control)
    monkeypatch.setattr(fresh_launch.subprocess, "Popen", lambda *args, **kwargs: pytest.fail("inventory refusal launched"))
    with pytest.raises((msb.MsbError, msb_preparation.ManagedJobError)):
        with fresh_launch.own_launch("box") as owner:
            fresh_launch._acknowledge_foreground("box", None, [], lambda: None, json_mode=False, ownership=owner)


@pytest.mark.parametrize("target", ["opencode", "box"])
def test_run_early_record_schema_refusal_uses_structured_boundary(monkeypatch, tmp_path, capsys, target):
    from acq_py import state

    def unreadable(*args):
        raise state.StateSchemaError("synthetic unsupported record schema")

    monkeypatch.setattr(msb, "exists", lambda name: True)
    monkeypatch.setattr(lifecycle.state, "record_read", unreadable)
    monkeypatch.setattr(lifecycle, "_create_opts", lambda *args: (lifecycle._NO_OPTS, None))
    monkeypatch.setattr(lifecycle, "_scope_advice", lambda *args: pytest.fail("schema refusal reached effects"))
    parsed = SimpleNamespace(target=target, path=str(tmp_path), name="box", kit=[], image=None,
                             publish=[], clone=False, agent_args=[])
    assert lifecycle._run_run(parsed, True, "msb") != 0
    assert json.loads(capsys.readouterr().out)["error"]["code"] == "state_schema_unsupported"


def test_recreate_workspace_overlap_precedes_profile_and_credential_effects(monkeypatch, tmp_path, capsys):
    record = {"agent": "opencode", "workspace": str(tmp_path), "ro_host_config": True}
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(lifecycle.state, "record_read", lambda *args: record)
    monkeypatch.setattr(security, "mount_check", lambda *args, **kwargs: ("missing", "fixture mount missing"))
    monkeypatch.setattr(security, "ro_mount_version_problem", lambda: None)
    monkeypatch.setattr(fresh_launch, "existing_profile", lambda *args: pytest.fail("profile hid workspace overlap"))
    monkeypatch.setattr(lifecycle, "_scope_advice", lambda *args: pytest.fail("unsafe workspace reached credentials"))
    monkeypatch.setattr(msb, "remove", lambda *args: pytest.fail("unsafe workspace removed guest"))
    parsed = SimpleNamespace(recreate="box", yes=True, clone=False)
    assert lifecycle.run_recreate(parsed, True, "msb") != 0
    error = json.loads(capsys.readouterr().out)["error"]
    assert error["code"] == "validation_failed"
    assert "contains acq's state directory" in error["message"]


def test_none_profile_runs_real_runner_and_empty_inventory_not_usai(operational, selection, monkeypatch):
    selected = replace(selection, kits=tuple(entry for entry in selection.kits if entry.role != "provider"))
    monkeypatch.setattr(kit_msb, "selection_for", lambda *args, **kwargs: selected)
    plan, code = lifecycle._plan_msb_kits("opencode", [], common.OPENCODE_DEVENV_IMAGE, "create", True)
    assert code is None and kit_msb.is_fresh_profile(plan.kits)
    inputs = fresh_inputs.prepare("box", usai=False)
    operational.doc["active_config"]["env"][0]["value"] = inputs.guest_root
    operational.doc["active_config"]["mounts"][0].update(guest=inputs.guest_root, host=str(inputs.generation))
    operational.doc["active_config"]["network"]["secrets"]["secrets"] = []
    monkeypatch.setattr(msb, "held_read", lambda name: SimpleNamespace(complete=True, bindings={}, instance=operational.snapshot.instance))
    operational.snapshot.services = {}

    def producer(command, name, identity, argv, user, deadline, previous, env):
        assert argv[5] == "none"
        assert argv[argv.index("--provider-root") + 1] == inputs.guest_root
        assert list((inputs.generation / "models/providers").iterdir()) == []
        assert user == "agent" and tuple(env) == msb_preparation._INITIAL_ENV
        operational.events.append("empty-producer")
        return parse_result(identity, returncode=0, stdout=b'{"sourceOutcome":"live","metadataOutcome":"not-requested"}')

    monkeypatch.setattr(msb_preparation, "_run_job", producer)
    fresh_launch.prepare_locked("box")
    assert "empty-producer" in operational.events
    assert not list(operational.host.glob("preparation-ca-*"))


@pytest.mark.parametrize("whole_job", [True, False])
def test_sigint_matches_foreground_shell_loop_semantics(monkeypatch, tmp_path, whole_job):
    import signal

    ca = tmp_path / "public.crt"
    ca.write_text("public fixture")

    class Child:
        def wait(self):
            if whole_job:
                fresh_launch.hostexec._ignore_interrupt(signal.SIGINT, None)
            return -signal.SIGINT

        def poll(self):
            return -signal.SIGINT

    owner = fresh_launch.LaunchOwnership("box", proc=Child(), ca_path=ca)
    died = []
    monkeypatch.setattr(fresh_launch.hostexec, "_die_of_interrupt", lambda: died.append("SIGINT"))
    assert fresh_launch.wait_admitted(owner) == 130
    assert died == (["SIGINT"] if whole_job else [])
    assert not ca.exists()


def test_unrelated_support_failure_still_prepares_but_does_not_claim_full_provenance(operational, monkeypatch, capsys):
    from acq_py import kits

    monkeypatch.setattr(kit_msb, "check_prereqs", lambda name: None)
    monkeypatch.setattr(kit_msb, "ensure_kits_applied", lambda *args, **kwargs:
                        kit_msb.ApplyResult(applied=["opencode", "usai-provider"], incomplete=["git-ssh-sign"]))
    monkeypatch.setattr(lifecycle.ssh_agent, "forwarding_sock", lambda name: None)
    monkeypatch.setattr(lifecycle.ssh_agent, "provision_bridge", lambda name: None)
    monkeypatch.setattr(kit_msb, "cli_kits_write", lambda *args: None)
    monkeypatch.setattr(kits, "kit_applied_write", lambda *args: None)
    applied = []
    monkeypatch.setattr(kits, "provenance_write", lambda *args, **kwargs: applied.append(kwargs["applied"]))
    plan, code = lifecycle._plan_msb_kits("opencode", [], common.OPENCODE_DEVENV_IMAGE, "create", True)
    assert code is None
    result, code = lifecycle._apply_msb_kits("box", plan, [], "create", True, ro_required=True)
    assert code is None and result.incomplete == ["git-ssh-sign"]
    assert "producer" in operational.events and applied == [False]


def test_durable_active_attempt_allows_live_owner_but_refuses_abandoned(operational, monkeypatch):
    import os

    owner = fresh_launch.LaunchOwnership("box", command=("/trusted/msb",), argv=("/bin/sh",),
                                         job="job_" + "a" * 32, boot="boot_" + "b" * 32)
    fresh_launch._begin_attempt(owner)
    try:
        with pytest.raises(msb.MsbError, match="unresolved"):
            fresh_launch._admission_attempts("box")
        fresh_launch._write_attempt(owner, "active")
        monkeypatch.setattr(fresh_launch, "_terminal_job", lambda previous, deadline: False)
        fresh_launch._admission_attempts("box")  # another healthy session may coexist
    finally:
        os.close(owner.attempt_fd)
        owner.attempt_fd = None
    with pytest.raises(msb.MsbError, match="abandoned"):
        fresh_launch._admission_attempts("box")


def test_spawned_process_without_job_id_still_retains_exclusion_and_ca(operational, monkeypatch):
    from acq_py import lock

    @contextmanager
    def lifecycle_lock(*args):
        yield

    class Child:
        def poll(self):
            return None

        def send_signal(self, signum):
            pass

        def wait(self, timeout=None):
            return 0  # Host exit is not evidence of guest cleanup.

    monkeypatch.setattr(lock, "sandbox_lock", lifecycle_lock)
    with fresh_launch.own_launch("box") as owner:
        fresh_launch._begin_attempt(owner)
        owner.ca_path = operational.host / "preparation-ca-lost-id.crt"
        owner.ca_path.write_bytes(b"public fixture")
        owner.proc = Child()
        owner.spawned = True
    assert not owner.completed and owner.ca_path.exists()
    assert kit_msb.hc_has("box", "fresh-quarantine")
    with pytest.raises(msb.MsbError, match="abandoned"):
        fresh_launch._admission_attempts("box")


def test_pending_persistence_failure_never_spawns_and_blocks_next_admission(operational, monkeypatch):
    real_write = fresh_launch._write_attempt

    def disk_full(owner, phase):
        raise OSError("synthetic disk full")

    monkeypatch.setattr(fresh_launch, "_write_attempt", disk_full)
    monkeypatch.setattr(msb, "start_directory", lambda name: None)
    monkeypatch.setattr(msb, "agent_shell", lambda name: "/bin/sh")
    monkeypatch.setattr(fresh_launch.subprocess, "Popen", lambda *args, **kwargs: pytest.fail("failed persistence spawned"))
    with pytest.raises(msb.MsbError):
        with fresh_launch.own_launch("box") as owner:
            fresh_launch.admit_locked("box", None, [], json_mode=False, ownership=owner)
    monkeypatch.setattr(fresh_launch, "_write_attempt", real_write)
    with pytest.raises(msb.MsbError, match="abandoned"):
        fresh_launch._admission_attempts("box")


@pytest.mark.parametrize("disk_full", [False, True])
def test_cleanup_excludes_concurrent_admission_even_if_quarantine_write_fails(operational, monkeypatch, disk_full):
    from acq_py import lock

    held = []
    @contextmanager
    def lifecycle_lock(*args):
        held.append(True)
        try:
            yield
        finally:
            held.pop()

    monkeypatch.setattr(lock, "sandbox_lock", lifecycle_lock)
    real_write = fresh_launch._write_attempt
    with fresh_launch.own_launch("box") as owner:
        owner.command = ("/trusted/msb",)
        owner.argv = ("/bin/sh",)
        owner.job, owner.boot = "job_" + "a" * 32, "boot_" + "b" * 32
        fresh_launch._begin_attempt(owner)
        fresh_launch._write_attempt(owner, "active")
        owner.spawned = True
        if disk_full:
            def failed_write(*args):
                raise OSError("synthetic disk full")
            monkeypatch.setattr(fresh_launch, "_write_attempt", failed_write)
        def end_host(target):
            assert held  # no external admission can acquire lifecycle lock here
            if not disk_full:
                with pytest.raises(msb.MsbError, match="unresolved"):
                    fresh_launch._admission_attempts("box")
            return True
        monkeypatch.setattr(fresh_launch, "_end_host", end_host)
        monkeypatch.setattr(fresh_launch, "_end_guest", lambda target: False)
        monkeypatch.setattr(kit_msb, "hc_write", lambda *args: (_ for _ in ()).throw(OSError("disk full")))
    monkeypatch.setattr(fresh_launch, "_write_attempt", real_write)
    assert not owner.completed
    with pytest.raises(msb.MsbError, match="abandoned"):
        fresh_launch._admission_attempts("box")


@pytest.mark.parametrize("replacement", ["instance", "inode", "removed-and-recreated"])
def test_late_owner_cannot_mutate_replacement_instance(operational, monkeypatch, replacement, capsys):
    from acq_py import lock

    @contextmanager
    def lifecycle_lock(*args):
        yield

    monkeypatch.setattr(lock, "sandbox_lock", lifecycle_lock)
    ended = []
    monkeypatch.setattr(fresh_launch, "_end_host", lambda owner: ended.append(owner.name) or True)
    monkeypatch.setattr(fresh_launch, "_end_guest", lambda owner: pytest.fail("old owner addressed replacement guest"))
    with fresh_launch.own_launch("box") as owner:
        fresh_launch._begin_attempt(owner)
        owner.spawned = True
        owner.ca_path = operational.host / "preparation-ca-old.crt"
        owner.ca_path.write_bytes(b"old public CA")
        if replacement == "removed-and-recreated":
            kit_msb.remove_host_config("box")
            operational.host.mkdir()
            operational.snapshot.instance = "i:" + "2" * 32
            fresh_launch._attempts("box").mkdir()
        elif replacement == "instance":
            operational.snapshot.instance = "i:" + "2" * 32
        else:
            owner.attempt_path.unlink()
        if replacement != "instance":
            owner.attempt_path.write_bytes(b"replacement attempt")
        owner.ca_path.write_bytes(b"replacement public CA")
        replacement_record = owner.attempt_path.read_bytes()
        monkeypatch.setattr(kit_msb, "hc_write", lambda *args: pytest.fail("old owner quarantined replacement"))
    assert ended == ["box"]
    assert owner.retired and not owner.completed
    assert owner.attempt_path.read_bytes() == replacement_record
    assert owner.ca_path.read_bytes() == b"replacement public CA"
    assert "unconfirmed" in capsys.readouterr().err


def test_attempt_parent_chain_synced_before_pending_record(operational, monkeypatch):
    import os

    observed = []
    sync = fresh_launch._sync_dir
    write = fresh_launch._write_attempt
    def observe_sync(path):
        observed.append(("sync", path))
        sync(path)
    def observe_write(owner, phase):
        observed.append(("write", phase))
        write(owner, phase)
    monkeypatch.setattr(fresh_launch, "_sync_dir", observe_sync)
    monkeypatch.setattr(fresh_launch, "_write_attempt", observe_write)
    owner = fresh_launch.LaunchOwnership("box")
    try:
        fresh_launch._begin_attempt(owner)
        root = fresh_launch._attempts("box")
        expected = [("sync", path) for path in (root, *root.parents)]
        assert observed[:len(expected)] == expected
        assert observed[len(expected)] == ("write", "pending")
    finally:
        if owner.attempt_fd is not None:
            os.close(owner.attempt_fd)


def test_attempt_parent_sync_failure_prevents_spawn(operational, monkeypatch):
    sync = fresh_launch._sync_dir
    def failed_parent(path):
        if path == fresh_launch._attempts("box").parent:
            raise OSError("synthetic parent fsync failure")
        sync(path)
    monkeypatch.setattr(fresh_launch, "_sync_dir", failed_parent)
    monkeypatch.setattr(msb, "start_directory", lambda name: None)
    monkeypatch.setattr(msb, "agent_shell", lambda name: "/bin/sh")
    monkeypatch.setattr(fresh_launch.subprocess, "Popen", lambda *args, **kwargs: pytest.fail("unsynced directory spawned"))
    with pytest.raises(msb.MsbError):
        with fresh_launch.own_launch("box") as owner:
            fresh_launch.admit_locked("box", None, [], json_mode=False, ownership=owner)
    assert not owner.spawned and owner.attempt_fd is None
    assert not list(operational.host.glob("preparation-ca-*"))


@pytest.mark.parametrize("primary", ["hup", "ordinary", "none"])
def test_pre_attempt_ca_unlink_failure_preserves_primary_and_restores_handlers(monkeypatch, tmp_path, capsys, primary):
    import signal
    from pathlib import Path
    from acq_py.cli import _Terminated

    interruption = _Terminated(signal.SIGHUP)
    ordinary = RuntimeError("primary fixture failure")
    cleanup = OSError("private-path-and-value-must-not-be-printed")
    def handler(signum, frame):
        raise interruption

    watched = (signal.SIGHUP, signal.SIGTERM, signal.SIGINT)
    original = {sig: signal.getsignal(sig) for sig in watched}
    ca = tmp_path / "public.crt"
    ca.write_bytes(b"public fixture")
    unlink = Path.unlink
    def failed_unlink(path, *args, **kwargs):
        if path == ca:
            raise cleanup
        return unlink(path, *args, **kwargs)
    monkeypatch.setattr(Path, "unlink", failed_unlink)
    try:
        signal.signal(signal.SIGHUP, handler)
        signal.signal(signal.SIGTERM, handler)
        with pytest.raises(BaseException) as caught:
            with fresh_launch.own_launch("box") as owner:
                owner.ca_path = ca
                assert owner.attempt_path is None
                owner.interrupt_handler = fresh_launch.hostexec._hold_interrupt()
                owner.interrupt_held = owner.interrupt_handler is not None
                if primary == "hup":
                    signal.getsignal(signal.SIGHUP)(signal.SIGHUP, None)
                if primary == "ordinary":
                    raise ordinary
        assert caught.value is {"hup": interruption, "ordinary": ordinary, "none": cleanup}[primary]
        assert signal.getsignal(signal.SIGHUP) is handler
        assert signal.getsignal(signal.SIGTERM) is handler
        assert signal.getsignal(signal.SIGINT) == original[signal.SIGINT]
        assert ca.exists()
        diagnostic = capsys.readouterr().err
        assert "private-path" not in diagnostic and str(ca) not in diagnostic
        assert ("original termination or failure preserved" in diagnostic) is (primary != "none")
    finally:
        for sig, previous in original.items():
            signal.signal(sig, previous)


def test_finalizer_attempts_all_restorations_after_close_and_handler_failure(monkeypatch, capsys):
    import signal

    primary = RuntimeError("original")
    calls = []
    def previous(signum, frame):
        pass
    def failed_close(fd):
        calls.append(("close", fd))
        raise OSError("close failed")
    def restore(sig, handler):
        if handler is previous:
            calls.append(("restore", sig))
            if sig == signal.SIGINT:
                raise OSError("restore failed")
        return previous
    monkeypatch.setattr(fresh_launch, "_release_launch", lambda owner: None)
    monkeypatch.setattr(fresh_launch.os, "close", failed_close)
    monkeypatch.setattr(signal, "getsignal", lambda sig: previous)
    monkeypatch.setattr(signal, "signal", restore)
    with pytest.raises(RuntimeError) as caught:
        with fresh_launch.own_launch("box") as owner:
            owner.attempt_fd = 123456
            owner.interrupt_handler = previous
            owner.interrupt_held = True
            raise primary
    assert caught.value is primary
    assert calls == [("close", 123456), ("restore", signal.SIGINT),
                     ("restore", signal.SIGTERM), ("restore", signal.SIGHUP)]
    assert "original termination or failure preserved" in capsys.readouterr().err
