"""Adapter-only fakes; NOT PyO3 cancellation, native transport or guest proof."""

import asyncio
from dataclasses import dataclass
from enum import Enum
from types import SimpleNamespace

import pytest

from acq_py import sdk_preparation as sdk
from acq_py.runtime_preparation import InvocationIdentity, PreparationError, build_argv


class Kind(Enum):
    STARTED = "started"
    STDOUT = "stdout"
    STDERR = "stderr"
    EXITED = "exited"
    FAILED = "failed"
    STDIN_ERROR = "stdin_error"


class Stdin:
    @staticmethod
    def null():
        return NULL


NULL = object()
BLOCK = object()
SUCCESS = b'{"sourceOutcome":"live","metadataOutcome":"not-requested"}'
PATHS = dict(node="/usr/bin/node", artifact="/opt/acq/preparation.mjs",
             provider_root="/opt/providers/generation.1", global_dir="/home/agent/config",
             base_config="/opt/acq/base config.jsonc")
IDENTITY = InvocationIdentity("attempt-1", "instance-1", "generation-1",
                              "1" * 64, "2" * 64, "3" * 64)


@dataclass
class Event:
    event_type: object
    pid: object = None
    data: object = None
    code: object = None


def started(pid=42):
    return Event(Kind.STARTED, pid=pid)


def output(data=SUCCESS, kind=Kind.STDOUT):
    return Event(kind, data=data)


def exited(code=0):
    return Event(Kind.EXITED, code=code)


class Handle:
    def __init__(self, events, *, kill_events=(), kill_error=False, kill_block=False):
        self.events = list(events)
        self.kill_events = list(kill_events)
        self.kill_error = kill_error
        self.kill_block = kill_block
        self.receivers = 0
        self.max_receivers = 0
        self.recv_calls = 0
        self.kills = 0
        self.kill_completed = False
        self.blocked = asyncio.Event()
        self.kill_entered = asyncio.Event()
        self.released = asyncio.Event()
        self.control_release = asyncio.Event()

    async def recv(self):
        self.receivers += 1
        self.max_receivers = max(self.max_receivers, self.receivers)
        self.recv_calls += 1
        assert self.receivers == 1
        try:
            event = self.events.pop(0) if self.events else None
            if event is BLOCK:
                self.blocked.set()
                await self.released.wait()
                event = self.events.pop(0) if self.events else None
            if isinstance(event, Exception):
                raise event
            return event
        finally:
            self.receivers -= 1

    async def kill(self):
        self.kills += 1
        self.kill_entered.set()
        if self.kill_block:
            await self.control_release.wait()
        if self.kill_error:
            raise RuntimeError("SDK-diagnostic-canary")
        await asyncio.sleep(0)
        self.events.extend(self.kill_events)
        self.released.set()
        self.kill_completed = True


class Sandbox:
    def __init__(self, handle, *, block=False, error=False):
        self.handle = handle
        self.block = block
        self.error = error
        self.calls = []
        self.entered = asyncio.Event()
        self.release = asyncio.Event()

    async def exec_stream(self, cmd, args=None, **kwargs):
        self.calls.append((cmd, args, kwargs))
        self.entered.set()
        if self.block:
            await self.release.wait()
        if self.error:
            raise RuntimeError("SDK-diagnostic-canary")
        return self.handle


@pytest.fixture(autouse=True)
def types(monkeypatch):
    monkeypatch.setattr(sdk, "_sdk_types", lambda: (Stdin, Kind))


async def call(sandbox, state=None, **kwargs):
    return await sdk.prepare(sandbox, IDENTITY,
                             state=state if state is not None else sdk.CleanupState(),
                             **{**PATHS, "env": {"SSL_CERT_FILE": "/opt/acq/ca.pem"},
                                "timeout": 0.5, "cleanup_timeout": 0.05, **kwargs})


def test_fast_output_real_shaped_bytes_and_fixed_invocation():
    async def scenario():
        handle = Handle([started(), output(list(SUCCESS[:17])),
                         output(b"\xff\x00", Kind.STDERR), output(SUCCESS[17:]), exited(), None])
        sandbox, state = Sandbox(handle), sdk.CleanupState()
        env = {"SSL_CERT_FILE": "/opt/acq/ca.pem", "PLACEHOLDER": "not-a-real-credential"}
        result = await call(sandbox, state, env=env)
        assert result.identity is IDENTITY
        assert result.metadata_outcome == "not-requested"
        assert state == sdk.CleanupState(True, True, True, True, False)
        argv = build_argv(**PATHS)
        assert sandbox.calls == [(argv[0], list(argv[1:]), dict(
            user="agent", env=env, timeout=0.5, stdin=NULL, tty=False))]
        assert sandbox.calls[0][2]["env"] is not env
        assert handle.max_receivers == 1 and handle.kills == 0
    asyncio.run(scenario())


@pytest.mark.parametrize("events", [
    [output(), started(), exited()],
    [exited(), started(), exited()],
    [started(), started(), exited()],
    [started(), output(), exited(), exited()],
    [started(), output(), exited(), output(b"late")],
    [started(), Event("stdout", data=SUCCESS), exited()],
    [started(True), exited()],
    [started(0), exited()],
    [started(2**32), exited()],
    [started(), exited(False)],
    [started(), exited(2**31)],
    [Event(Kind.STARTED, pid=3, data=b"unexpected")],
    [started(), Event(Kind.STDOUT, data=SUCCESS, pid=4)],
    [started(), Event(Kind.EXITED, code=0, data=b"unexpected")],
    [started(), output([True])],
    [started(), output([256])],
    [started(), output([-1])],
    [started(), output("guest-diagnostic-canary")],
    [started(), output(bytearray(SUCCESS))],
    [started(), object()],
    [started(), Event(Kind.STDIN_ERROR, data=b"guest-diagnostic-canary", code=32), exited()],
])
def test_malformed_duplicate_and_out_of_order_refuse(events):
    async def scenario():
        handle, state = Handle(events), sdk.CleanupState()
        with pytest.raises(sdk.TransportError) as error:
            await call(Sandbox(handle), state)
        assert "diagnostic-canary" not in str(error.value)
        assert handle.max_receivers == 1
    asyncio.run(scenario())


@pytest.mark.parametrize("events", [
    [], [started()], [Event(Kind.FAILED, data=b"guest-diagnostic-canary", code=2)],
    [started(), Event(Kind.FAILED, data=b"guest-diagnostic-canary", code=5)],
    [started(), RuntimeError("SDK-diagnostic-canary")],
])
def test_missing_exit_is_uncertain_never_no_spawn(events):
    async def scenario():
        state, handle = sdk.CleanupState(), Handle(events)
        with pytest.raises(sdk.UncertainExecution) as error:
            await call(Sandbox(handle), state)
        assert state.dispatched and state.uncertain and not state.confirmed_terminal
        assert handle.kill_completed
        assert error.value.__cause__ is None
        assert "canary" not in str(error.value)
    asyncio.run(scenario())


@pytest.mark.parametrize("payload,code", [(b"\xff", 0), (b"{}", 0),
                                         (SUCCESS, 1), (SUCCESS, -9)])
def test_only_closed_protocol_and_success_exit_returns(payload, code):
    async def scenario():
        state, handle = sdk.CleanupState(), Handle([started(), output(payload), exited(code)])
        with pytest.raises(PreparationError):
            await call(Sandbox(handle), state)
        assert state.confirmed_terminal and state.closed and not state.uncertain
        assert handle.kills == 0
    asyncio.run(scenario())


def test_combined_cap_boundary_and_overflow_never_truncates_to_success():
    async def scenario():
        for extra, succeeds in [(0, True), (1, False)]:
            handle = Handle([started(), output(), output(b"x" * (3 + extra), Kind.STDERR), exited()])
            if succeeds:
                await call(Sandbox(handle), max_output_bytes=len(SUCCESS) + 3)
                assert handle.kills == 0
            else:
                with pytest.raises(sdk.TransportError, match="output limit"):
                    await call(Sandbox(handle), max_output_bytes=len(SUCCESS) + 3)
                assert handle.kill_completed
    asyncio.run(scenario())


def test_deadline_preserves_blocked_reader_for_kill_and_drain():
    async def scenario():
        handle = Handle([started(), BLOCK], kill_events=[exited(-9)])
        state = sdk.CleanupState()
        with pytest.raises(sdk.TransportError, match="deadline"):
            await call(Sandbox(handle), state, timeout=0.01)
        assert handle.kill_completed and handle.max_receivers == 1
        assert state.confirmed_terminal and state.closed and not state.uncertain
    asyncio.run(scenario())


def test_exit_requires_eof_not_just_a_valid_success_document():
    async def scenario():
        handle = Handle([started(), output(), exited(), BLOCK])
        state = sdk.CleanupState()
        with pytest.raises(sdk.UncertainExecution):
            await call(Sandbox(handle), state, timeout=0.01, cleanup_timeout=0.01)
        assert state.confirmed_terminal and not state.closed and state.uncertain
        assert handle.kills == 0
    asyncio.run(scenario())


@pytest.mark.parametrize("kill_error,kill_block,kill_events", [
    (True, False, []), (False, True, []), (False, False, []),
])
def test_failed_control_or_no_exit_is_bounded_uncertainty(kill_error, kill_block, kill_events):
    async def scenario():
        handle = Handle([started(), BLOCK], kill_error=kill_error,
                        kill_block=kill_block, kill_events=kill_events)
        state = sdk.CleanupState()
        start = asyncio.get_running_loop().time()
        with pytest.raises(sdk.UncertainExecution):
            await call(Sandbox(handle), state, timeout=0.01, cleanup_timeout=0.01)
        assert asyncio.get_running_loop().time() - start < 0.5
        assert state.uncertain and not state.confirmed_terminal
        assert handle.max_receivers == 1 and handle.kills == 1
    asyncio.run(scenario())


@pytest.mark.parametrize("kill_error", [False, True])
def test_cancel_preserves_primary_and_exposes_caller_disposition(kill_error):
    async def scenario():
        handle = Handle([started(), BLOCK], kill_events=[exited(-9)], kill_error=kill_error)
        state = sdk.CleanupState()
        task = asyncio.create_task(call(Sandbox(handle), state))
        await handle.blocked.wait()
        task.cancel("original cancellation")
        with pytest.raises(asyncio.CancelledError) as error:
            await task
        assert error.value.args == ("original cancellation",)
        assert state.uncertain is kill_error
        assert isinstance(error.value.__cause__, sdk.UncertainExecution) is kill_error
        assert state.confirmed_terminal is (not kill_error)
        assert handle.max_receivers == 1
    asyncio.run(scenario())


def test_repeated_cancellation_keeps_first_error_and_original_cleanup_deadline():
    async def scenario():
        handle = Handle([started(), BLOCK], kill_block=True)
        state = sdk.CleanupState()
        task = asyncio.create_task(call(Sandbox(handle), state, cleanup_timeout=0.02))
        await handle.blocked.wait()
        task.cancel("first")
        await handle.kill_entered.wait()
        start = asyncio.get_running_loop().time()
        for _ in range(100):
            if task.done():
                break
            task.cancel("later")
            await asyncio.sleep(0)
        with pytest.raises(asyncio.CancelledError) as error:
            await task
        assert error.value.args == ("first",)
        assert state.uncertain and handle.kills == 1
        assert asyncio.get_running_loop().time() - start < 0.5
        await asyncio.sleep(0)
        assert handle.receivers == 0
    asyncio.run(scenario())


@pytest.mark.parametrize("eventually_opens", [False, True])
def test_cancellation_during_dispatch_never_redispatches(eventually_opens):
    async def scenario():
        handle = Handle([started(), exited(-9)])
        sandbox, state = Sandbox(handle, block=True), sdk.CleanupState()
        task = asyncio.create_task(call(sandbox, state, cleanup_timeout=0.02))
        await sandbox.entered.wait()
        task.cancel("dispatch cancellation")
        if eventually_opens:
            sandbox.release.set()
        with pytest.raises(asyncio.CancelledError) as error:
            await task
        assert error.value.args == ("dispatch cancellation",)
        assert len(sandbox.calls) == 1
        assert state.uncertain is (not eventually_opens)
        assert handle.kills == int(eventually_opens)
    asyncio.run(scenario())


def test_dispatch_exception_is_uncertain_not_retryable_no_spawn():
    async def scenario():
        sandbox, state = Sandbox(None, error=True), sdk.CleanupState()
        with pytest.raises(sdk.UncertainExecution):
            await call(sandbox, state)
        assert state.dispatched and state.uncertain
        assert len(sandbox.calls) == 1
    asyncio.run(scenario())


def test_dispatch_deadline_is_uncertain_without_a_handle():
    async def scenario():
        sandbox, state = Sandbox(None, block=True), sdk.CleanupState()
        with pytest.raises(sdk.UncertainExecution):
            await call(sandbox, state, timeout=0.01, cleanup_timeout=0.01)
        assert state.dispatched and state.uncertain and len(sandbox.calls) == 1
    asyncio.run(scenario())


def test_cancel_first_arriving_during_cleanup_is_primary():
    async def scenario():
        handle = Handle([started(), output(b"x" * 1025)], kill_block=True,
                        kill_events=[exited(-9)])
        state = sdk.CleanupState()
        task = asyncio.create_task(call(Sandbox(handle), state))
        await handle.kill_entered.wait()
        task.cancel("cleanup cancellation")
        handle.control_release.set()
        with pytest.raises(asyncio.CancelledError) as error:
            await task
        assert error.value.args == ("cleanup cancellation",)
        assert handle.kill_completed and state.confirmed_terminal
        assert not state.uncertain
    asyncio.run(scenario())


def test_cancellation_exception_identity_is_preserved(monkeypatch):
    original_until = sdk._until
    observed = []

    async def watch(future, deadline, cancellations=None):
        try:
            return await original_until(future, deadline, cancellations)
        except asyncio.CancelledError as error:
            observed.append(error)
            raise

    monkeypatch.setattr(sdk, "_until", watch)

    async def scenario():
        handle = Handle([started(), BLOCK], kill_events=[exited(-9)])
        task = asyncio.create_task(call(Sandbox(handle)))
        await handle.blocked.wait()
        task.cancel("same object")
        with pytest.raises(asyncio.CancelledError) as error:
            await task
        assert observed and error.value is observed[0]
    asyncio.run(scenario())


@pytest.mark.parametrize("kwargs", [
    {"timeout": True}, {"timeout": 0}, {"timeout": float("inf")}, {"timeout": float("nan")},
    {"timeout": 301}, {"timeout": 10**1000},
    {"cleanup_timeout": False}, {"cleanup_timeout": -1},
    {"max_output_bytes": True}, {"max_output_bytes": 0}, {"max_output_bytes": 1025},
    {"env": None}, {"env": {"A": True}}, {"env": {"BAD=NAME": "value"}},
    {"env": {"A": "\x00"}}, {"env": {"A": "\ud800"}}, {"env": {"A": "x" * 32769}},
    {"node": "node"}, {"artifact": "/opt/../file"},
])
def test_invalid_inputs_never_dispatch(kwargs):
    async def scenario():
        sandbox, state = Sandbox(None), sdk.CleanupState()
        with pytest.raises(PreparationError):
            await call(sandbox, state, **kwargs)
        assert sandbox.calls == [] and state == sdk.CleanupState()
    asyncio.run(scenario())


def test_fresh_state_and_host_identity_required():
    async def scenario():
        sandbox = Sandbox(None)
        for state in (None, {}, sdk.CleanupState(dispatched=True)):
            with pytest.raises(sdk.TransportError):
                await sdk.prepare(sandbox, IDENTITY, state=state, **PATHS, env={})
        with pytest.raises(sdk.TransportError):
            await sdk.prepare(sandbox, {}, state=sdk.CleanupState(), **PATHS, env={})
        assert sandbox.calls == []
    asyncio.run(scenario())


def test_loader_is_lazy_version_pinned_and_does_not_resolve_sandbox(monkeypatch):
    # Exercise the real loader definition without loading a native extension.
    monkeypatch.undo()
    imports = []

    def load(name):
        imports.append(name)
        return SimpleNamespace(Stdin=Stdin, ExecEventType=Kind)

    monkeypatch.setattr(sdk.importlib, "import_module", load)
    monkeypatch.setattr(sdk.importlib.metadata, "version", lambda name: "0.7.16")
    assert sdk._sdk_types() == (Stdin, Kind)
    assert imports == ["microsandbox"]
    monkeypatch.setattr(sdk.importlib.metadata, "version", lambda name: "0.8.1")
    with pytest.raises(sdk.TransportError, match="0.7.16"):
        sdk._sdk_types()


def test_installed_sdk_types_with_fake_execution(monkeypatch):
    """Optional real native-package seam, never a native VM execution test."""
    monkeypatch.undo()
    package = pytest.importorskip("microsandbox")
    if sdk.importlib.metadata.version("microsandbox") != "0.7.16":
        pytest.skip("requires the pinned isolated SDK installation")

    async def scenario():
        kinds = package.ExecEventType
        events = iter([
            Event(kinds.STARTED, pid=42),
            Event(kinds.STDOUT, data=list(SUCCESS)),
            Event(kinds.EXITED, code=0), None,
        ])

        class RealTypeHandle:
            async def recv(self):
                return next(events)

            async def kill(self):
                pytest.fail("successful fake execution must not be killed")

        class RealTypeSandbox:
            async def exec_stream(self, *args, **kwargs):
                assert isinstance(kwargs["stdin"], package.Stdin)
                return RealTypeHandle()

        state = sdk.CleanupState()
        result = await call(RealTypeSandbox(), state)
        assert result.source_outcome == "live"
        assert state.confirmed_terminal and state.closed and not state.uncertain

    asyncio.run(scenario())
