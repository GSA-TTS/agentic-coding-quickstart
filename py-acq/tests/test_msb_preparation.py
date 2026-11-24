"""Executable synthetic CLI contract tests, not evidence of native MSB isolation.

Run with the Python package's ordinary test suite in the reviewed workspace sandbox.
The fake never executes guest argv. Host subprocesses exercise both raw pipes.
"""

import json
import os
import shlex
import sys
import time

import pytest

from acq_py import msb_preparation as runner
from acq_py.runtime_preparation import InvocationIdentity, PreparationError

pytestmark = pytest.mark.skipif(os.name != "posix", reason="POSIX transport only")

FAKE = r'''
import json
import os
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
args = sys.argv[2:]
mode = (root / "mode").read_text()
verb = args[0]
with (root / "calls").open("a") as stream:
    stream.write(json.dumps(args) + "\n")
assert not os.isatty(0) and not os.isatty(1) and not os.isatty(2)
assert sys.stdin.buffer.read() == b""
job_id = "job_" + "1" * 32
boot_id = "boot_" + "2" * 32
state_path = root / "job"

def publish_job(job):
    # Killing the host attach transport must not truncate authoritative backend
    # state. Native MSB owns that state outside the attach client process.
    pending = root / ("job.pending." + str(os.getpid()))
    with pending.open("w") as stream:
        if mode == "stdout-cap-interrupted-publication" and verb == "attach":
            stream.write('{"version":')
            stream.flush()
            os.write(1, b"X" * 2048)
            time.sleep(20)  # Transport is killed while only the private file is partial.
        else:
            stream.write(json.dumps(job))
    pending.replace(state_path)

if args == ["--version"]:
    print("msb 0.7.15" if mode == "old-version" else "msb 0.7.16")
    sys.exit(0)
if args[-1] == "--help":
    if mode == "help-cap":
        os.write(1, b"X" * 300000)
    print("--detach --no-stdin --timeout --user --all --limit --format --job --signal"
          + ("" if mode == "missing-capability" else " --read-only"))
    sys.exit(0)
if verb == "exec":
    assert "--no-stdin" in args and "--detach" in args and "--timeout" in args
    assert "-t" not in args and "--tty" not in args
    assert args[args.index("--user") + 1] == "agent"
    assert args[args.index("--timeout") + 1].endswith("ms")
    assert args[args.index("--timeout") + 1] != "0ms"
    job = dict(version=1, id=job_id, runtime_boot_id=boot_id,
               command=args[args.index("--") + 1:], state="running", tty=False,
               stdin_closed=True, pid=123, created_at=100, started_at=101,
               finished_at=None, exit_code=None, failure=None, error=None, timed_out=False)
    publish_job(job)
    if mode == "exec-refused":
        sys.exit(1)
    if mode == "bad-id":
        print(job_id + "\n" + job_id)
    else:
        print(job_id)
    sys.exit(0)
if verb in ("jobs", "inspect"):
    if verb == "jobs":
        limit = int(args[args.index("--limit") + 1])
        if not 1 <= limit <= 100:
            sys.exit(2)  # Native MSB rejects unsupported page sizes before execution.
        assert args == ["jobs", "--all", "--limit", "100", "--format", "json", "sandbox"]
    else:
        assert args == ["inspect", "--job", job_id, "--format", "json", "sandbox"]
    if mode == "control-stderr-cap":
        os.write(2, b"X" * 20000)
    if mode == "control-stdout-cap":
        os.write(1, b"X" * 300000)
    if mode == "inventory-hang":
        time.sleep(20)
    if mode == "malformed-inventory":
        print('{"items": [], "items": [], "next_cursor": null}')
        sys.exit(0)
    items = [json.loads(state_path.read_text())] if state_path.exists() else []
    if items:
        if mode == "wrong-id":
            items[0]["id"] = "job_" + "4" * 32
        if mode == "wrong-command":
            items[0]["command"] = ["/unrelated"]
        if mode == "wrong-boot" and (root / "attached").exists():
            items[0]["runtime_boot_id"] = "boot_" + "3" * 32
        if mode == "unknown-state":
            items[0]["state"] = "mystery"
        if mode == "bool-exit" and items[0]["state"] == "exited":
            items[0]["exit_code"] = False
        if mode == "extra-field":
            items[0]["unknown"] = 1
        if mode == "missing-job":
            items = []
        if mode == "duplicate-job":
            items *= 2
    if mode == "too-many":
        items = [dict(id="job_" + format(i, "032x")) for i in range(101)]
    if verb == "inspect":
        print(json.dumps(items[0] if len(items) == 1 else items))
    else:
        cursor = "opaque" if mode == "pagination" else None
        if mode.startswith("page-boundary"):
            # At the explicit cap pre-launch; the new job adds another page.
            items = [dict(id="job_" + format(i, "032x")) for i in range(100)]
            cursor = "opaque" if state_path.exists() else None
        print(json.dumps(dict(items=items, next_cursor=cursor)))
    sys.exit(0)
if verb in ("signal", "kill"):
    assert args[args.index("--job") + 1] == job_id
    if verb == "signal":
        assert args[args.index("--signal") + 1] == "TERM"
    if mode == "cleanup-refused" or (mode == "term-ignored" and verb == "signal"):
        sys.exit(1)
    job = json.loads(state_path.read_text())
    job.update(state="exited", exit_code=-1, finished_at=102)
    publish_job(job)
    sys.exit(0)
if verb == "attach":
    assert args == ["attach", "--read-only", "--job", job_id, "sandbox"]
    (root / "attached").touch()
    if mode in ("attach-hang", "term-ignored", "cleanup-refused"):
        time.sleep(20)
    if mode in ("stdout-cap", "page-boundary-cleanup"):
        os.write(1, b"X" * 2048)
    if mode == "stderr-cap":
        os.write(2, b"X" * 20000)
    if mode == "corrupted-backend-state":
        state_path.write_text('{"version":')
        os.write(1, b"X" * 2048)
        time.sleep(20)
    job = json.loads(state_path.read_text())
    job.update(state="exited", exit_code=0, finished_at=102)
    if mode in ("signal-exit", "native-timeout"):
        job.update(exit_code=-1, timed_out=mode == "native-timeout")
    if mode == "typed-failure":
        job["exit_code"] = 1
    if mode == "backend-failure":
        job["failure"] = "not-authoritative-success"
    publish_job(job)
    if mode == "invalid-utf8":
        os.write(1, b"\xff")
    elif mode == "typed-failure":
        print(json.dumps(dict(schemaVersion="acq-runtime-model-outcome/v1", outcome="failure",
                             stage="membership", reason="connection", failureClass="transient")))
    else:
        print('{"sourceOutcome":"live","metadataOutcome":"not-requested"}')
    sys.exit(1 if mode in ("signal-exit", "native-timeout", "attach-refused", "typed-failure") else 0)
sys.exit(99)
'''


@pytest.fixture
def fake(tmp_path, monkeypatch):
    script = tmp_path / "synthetic msb.py"
    script.write_text(FAKE)
    (tmp_path / "mode").write_text("success")
    # The actual trusted command resolver handles a multi-element override.
    monkeypatch.setenv("ACQ_MSB_BIN", shlex.join([sys.executable, str(script), str(tmp_path)]))
    monkeypatch.setattr(runner, "CLEANUP_SECONDS", 0.5)
    return tmp_path


@pytest.fixture
def identity():
    return InvocationIdentity("attempt-1", "instance-1", "generation-1",
                              "1" * 64, "2" * 64, "3" * 64)


def run(identity, **kwargs):
    return runner.run_preparation(
        "sandbox", identity, node="/usr/local/bin/node", artifact="/trusted/preparation.mjs",
        provider_root="/trusted/provider", global_dir="/home/agent/.config/opencode",
        base_config="/trusted/base.jsonc", **kwargs,
    )


def calls(fake):
    return [json.loads(line) for line in (fake / "calls").read_text().splitlines()]


def mode(fake, value):
    (fake / "mode").write_text(value)


def test_success_uses_real_pipes_exact_argv_and_host_identity(fake, identity):
    result = run(identity)
    assert result.identity is identity
    assert result.metadata_outcome == "not-requested"
    recorded = calls(fake)
    assert [args[0] for args in recorded] == [
        "--version", "exec", "attach", "jobs", "inspect", "signal", "kill", "jobs",
        "exec", "inspect", "attach", "inspect",
    ]
    launched = next(args for args in recorded if args[0] == "exec" and "--detach" in args)
    assert launched[launched.index("--") + 1:] == [
        "/usr/local/bin/node", "/trusted/preparation.mjs", "--provider-root", "/trusted/provider",
        "--global-dir", "/home/agent/.config/opencode", "--base-config", "/trusted/base.jsonc",
        "--mode", "live-required",
    ]


@pytest.mark.parametrize("value", [
    "old-version", "missing-capability", "help-cap", "pagination", "too-many",
    "malformed-inventory", "control-stderr-cap", "control-stdout-cap",
])
def test_preflight_refusal_never_launches(fake, identity, value):
    mode(fake, value)
    with pytest.raises(runner.ManagedJobError):
        run(identity)
    assert not any("--detach" in args for args in calls(fake))


@pytest.mark.parametrize("limit", [0, 101, 256])
def test_synthetic_cli_enforces_native_inventory_limit_range(fake, identity, monkeypatch, limit):
    monkeypatch.setattr(runner, "MAX_JOBS", limit)
    with pytest.raises(runner.ManagedJobError, match="control refused"):
        run(identity)
    assert not any("--detach" in args for args in calls(fake))


@pytest.mark.parametrize("value", ["exec-refused", "bad-id"])
def test_uncertain_launch_requires_quarantine_without_guessing_job(fake, identity, value):
    mode(fake, value)
    with pytest.raises(runner.CleanupUnconfirmed, match="launch identity unavailable"):
        run(identity)
    assert not any(args[0] in ("signal", "kill") and "--help" not in args for args in calls(fake))


@pytest.mark.parametrize("value", [
    "stdout-cap", "stderr-cap", "invalid-utf8", "signal-exit", "native-timeout",
    "attach-refused", "typed-failure", "backend-failure",
])
def test_output_and_terminal_failures_clean_exact_guest_job(fake, identity, value):
    mode(fake, value)
    with pytest.raises(PreparationError) as error:
        run(identity)
    assert not isinstance(error.value, runner.CleanupUnconfirmed)
    assert "sourceOutcome" not in str(error.value)
    assert any(args[:3] == ["signal", "--job", "job_" + "1" * 32] for args in calls(fake))
    assert json.loads((fake / "job").read_text())["state"] == "exited"


def test_output_cap_during_fixture_publication_preserves_cleanup_evidence(fake, identity):
    mode(fake, "stdout-cap-interrupted-publication")
    with pytest.raises(runner.ManagedJobError, match="output limit exceeded") as error:
        run(identity)
    assert not isinstance(error.value, runner.CleanupUnconfirmed)
    # Prove the attach process was interrupted during a partial write, not merely
    # before or after it. The running record remained available to guest TERM.
    pending = list(fake.glob("job.pending.*"))
    assert len(pending) == 1
    assert pending[0].read_text() == '{"version":'
    job = json.loads((fake / "job").read_text())
    assert job["id"] == "job_" + "1" * 32
    assert job["runtime_boot_id"] == "boot_" + "2" * 32
    assert job["state"] == "exited" and job["exit_code"] == -1
    assert ["signal", "--job", job["id"], "--signal", "TERM", "sandbox"] in calls(fake)


def test_corrupted_authoritative_state_still_requires_quarantine(fake, identity):
    mode(fake, "corrupted-backend-state")
    with pytest.raises(runner.CleanupUnconfirmed, match="quarantine"):
        run(identity)
    assert (fake / "job").read_text() == '{"version":'
    assert ["signal", "--job", "job_" + "1" * 32, "--signal", "TERM", "sandbox"] in calls(fake)
    assert ["kill", "--job", "job_" + "1" * 32, "sandbox"] in calls(fake)


@pytest.mark.parametrize("value", [
    "wrong-command", "wrong-boot", "unknown-state", "bool-exit", "extra-field",
    "missing-job", "duplicate-job", "wrong-id",
])
def test_invalid_exact_job_cannot_confirm_cleanup(fake, identity, value):
    mode(fake, value)
    with pytest.raises(runner.CleanupUnconfirmed):
        run(identity)


def test_shared_deadline_and_guest_timeout(fake, identity):
    mode(fake, "attach-hang")
    start = time.monotonic()
    with pytest.raises(runner.ManagedJobError, match="deadline"):
        run(identity, timeout=2)
    assert time.monotonic() - start < 4
    launched = next(args for args in calls(fake) if "--detach" in args)
    assert 0 < int(launched[launched.index("--timeout") + 1][:-2]) < 2000
    assert json.loads((fake / "job").read_text())["state"] == "exited"


def test_term_escalation_is_guest_kill_not_host_kill(fake, identity, monkeypatch):
    mode(fake, "term-ignored")
    # Leave enough cleanup budget to reach the escalation phase.
    monkeypatch.setattr(runner, "CLEANUP_SECONDS", 2.0)
    with pytest.raises(runner.ManagedJobError, match="deadline"):
        run(identity, timeout=2)
    assert ["kill", "--job", "job_" + "1" * 32, "sandbox"] in calls(fake)


def test_unconfirmed_guest_cleanup_is_not_success(fake, identity):
    mode(fake, "cleanup-refused")
    with pytest.raises(runner.CleanupUnconfirmed, match="quarantine"):
        run(identity, timeout=2)
    assert json.loads((fake / "job").read_text())["state"] == "running"


def test_keyboard_interrupt_cleans_up_and_propagates(fake, identity, monkeypatch):
    capture = runner._capture

    def interrupt(command, args, deadline, stdout_limit=runner.CONTROL_BYTES):
        if args[0] == "attach" and "--help" not in args:
            raise KeyboardInterrupt
        return capture(command, args, deadline, stdout_limit)

    monkeypatch.setattr(runner, "_capture", interrupt)
    with pytest.raises(KeyboardInterrupt):
        run(identity)
    assert json.loads((fake / "job").read_text())["state"] == "exited"


def test_retained_job_cannot_be_reused_as_new_invocation(fake, identity):
    run(identity)
    with pytest.raises(runner.CleanupUnconfirmed, match="launch identity unavailable"):
        run(identity)


@pytest.mark.parametrize("value", ["page-boundary", "page-boundary-cleanup"])
def test_new_job_crossing_inventory_page_uses_direct_inspection(fake, identity, value):
    mode(fake, value)
    if value == "page-boundary":
        assert run(identity).identity is identity
    else:
        with pytest.raises(runner.ManagedJobError, match="output limit exceeded") as error:
            run(identity)
        assert not isinstance(error.value, runner.CleanupUnconfirmed)
        assert json.loads((fake / "job").read_text())["state"] == "exited"
    recorded = [args for args in calls(fake) if "--help" not in args]
    assert sum(args[0] == "jobs" for args in recorded) == 1
    launch = next(i for i, args in enumerate(recorded) if "--detach" in args)
    assert any(args[0] == "inspect" for args in recorded[launch + 1:])
    assert not any(args[0] == "jobs" for args in recorded[launch + 1:])


@pytest.mark.parametrize("timeout", [0, -1, True, float("inf"), float("nan"), 301])
def test_invalid_timeout_has_no_side_effect(fake, identity, timeout):
    with pytest.raises(runner.ManagedJobError, match="invalid"):
        run(identity, timeout=timeout)
    assert not (fake / "calls").exists()


def test_rejects_numeric_user_before_cli(fake, identity):
    with pytest.raises(runner.ManagedJobError, match="invalid"):
        run(identity, guest_user="1000")
    assert not (fake / "calls").exists()


def test_clean_parent_environment_is_constructed_before_node(fake, identity):
    assert run(identity, ca_bundle="/var/lib/acq/host/guest-ca.pem").identity is identity
    launched = next(args for args in calls(fake) if "--detach" in args)
    argv = launched[launched.index("--") + 1:]
    assert argv[:4] == ["/bin/sh", "-c", runner._CLEAN_LAUNCH, "acq-preparation"]
    assert argv[4:7] == ["/var/lib/acq/host/guest-ca.pem", "usai", "/usr/local/bin/node"]
    entries = [launched[i + 1] for i, token in enumerate(launched) if token == "-e"]
    assert entries == list(runner._INITIAL_ENV)
    assert "NODE_OPTIONS=" in entries and "LD_PRELOAD=" in entries
    assert not any(entry.startswith("USAI_API_KEY=") for entry in entries)
    assert 'exec /usr/bin/env -i' in argv[2]


@pytest.mark.parametrize("path", ["relative", "/a/../ca", "/a//ca", "/ca\n", "/ca;echo"])
def test_invalid_ca_path_refuses_before_transport(fake, identity, path):
    with pytest.raises(runner.ManagedJobError, match="CA path"):
        run(identity, ca_bundle=path)
    assert not (fake / "calls").exists()


def test_clean_launch_never_runs_as_root(fake, identity):
    with pytest.raises(runner.ManagedJobError, match="unprivileged"):
        run(identity, guest_user="root", ca_bundle="/var/lib/acq/host/guest-ca.pem")
    assert not (fake / "calls").exists()


def test_none_clean_launch_does_not_require_or_forward_usai(fake, identity):
    assert run(identity, ca_bundle="/var/lib/acq/host/guest-ca.pem", usai=False).identity is identity
    launched = next(args for args in calls(fake) if "--detach" in args)
    argv = launched[launched.index("--") + 1:]
    assert argv[5] == "none"
    assert 'if test "$provider" = usai; then test -n "${USAI_API_KEY:-}"; fi' in argv[2]
    assert 'if test "$provider" = usai; then set -- "USAI_API_KEY=$USAI_API_KEY" "$@"; fi' in argv[2]


def test_parent_hup_during_control_capture_survives_host_reap_failure(fake, monkeypatch):
    import signal
    from acq_py.cli import _Terminated

    interruption = _Terminated(signal.SIGHUP)
    original_reap = runner._reap_host
    selector_factory = runner.selectors.DefaultSelector

    class InterruptedSelector:
        def __enter__(self):
            self.selector = selector_factory()
            return self

        def __exit__(self, *args):
            self.selector.close()

        def register(self, *args):
            return self.selector.register(*args)

        def get_map(self):
            return self.selector.get_map()

        def select(self, *args):
            raise interruption

    def failed_reap(proc):
        original_reap(proc)  # Do not leave the real synthetic subprocess behind.
        raise runner.ManagedJobError("synthetic transport reap failure")

    monkeypatch.setattr(runner.selectors, "DefaultSelector", InterruptedSelector)
    monkeypatch.setattr(runner, "_reap_host", failed_reap)
    with pytest.raises(_Terminated) as caught:
        runner._capture(tuple(runner.msb.msb_command()), ["jobs", "--all", "--limit", "100",
                                                       "--format", "json", "sandbox"], time.monotonic() + 5)
    assert caught.value is interruption
