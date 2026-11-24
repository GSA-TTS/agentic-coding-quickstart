"""Local, unqualified microsandbox 0.7.16 preparation-only experiment.

No resolver, lifecycle operations, credentials, HTTP or persistent evidence.
See docs/explorations/python-sdk-transport.md for caller obligations and limits.
"""

from __future__ import annotations

import asyncio
import importlib
import importlib.metadata
import math
import re
from dataclasses import dataclass, field
from typing import Any

from .runtime_preparation import (
    MAX_OUTPUT_BYTES,
    InvocationIdentity,
    PreparationError,
    PreparationResult,
    build_argv,
    parse_result,
)


class TransportError(PreparationError):
    """Execution refused; never contains guest output or SDK diagnostics."""


class UncertainExecution(TransportError):
    """Caller must quarantine this attempt/instance, not retry or authorize reuse."""


@dataclass
class CleanupState:
    """Caller-owned, single-attempt disposition, including when cancellation wins.

    Not identity or launch evidence. Allocate a fresh instance for every call.
    A confirmed terminal alone does not establish a closed, valid protocol.
    """

    dispatched: bool = False
    started: bool = False
    confirmed_terminal: bool = False
    closed: bool = False
    uncertain: bool = False


def _sdk_types() -> tuple[Any, Any]:
    # Lazy by design: importing this experiment must not configure an SDK runtime.
    sdk = importlib.import_module("microsandbox")
    if importlib.metadata.version("microsandbox") != "0.7.16":
        raise TransportError("preinstalled microsandbox 0.7.16 required")
    return sdk.Stdin, sdk.ExecEventType


def _seconds(value: float) -> None:
    if (type(value) not in (int, float) or not 0 < value <= 300
            or not math.isfinite(value)):
        raise TransportError("invalid execution budget")


def _environment(env: dict[str, str]) -> dict[str, str]:
    if type(env) is not dict or len(env) > 128:
        raise TransportError("invalid explicit environment")
    size = 0
    for key, value in env.items():
        if (type(key) is not str or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) is None
                or type(value) is not str or "\x00" in value):
            raise TransportError("invalid explicit environment")
        if len(key) + len(value) > 32768:
            raise TransportError("invalid explicit environment")
        try:
            size += len(key.encode("utf-8")) + len(value.encode("utf-8"))
        except UnicodeError:
            raise TransportError("invalid explicit environment") from None
        if size > 32768:
            raise TransportError("invalid explicit environment")
    return env.copy()


async def _until(future: asyncio.Future[Any], deadline: float,
                 cancellations: list[asyncio.CancelledError] | None = None) -> Any:
    # wait_for cancels its operand and can wait indefinitely for cancellation.
    # Keep the same in-flight recv through timeout/cancellation and cleanup.
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            raise TransportError("execution deadline exceeded")
        try:
            done, _ = await asyncio.wait((future,), timeout=remaining)
            if not done:
                raise TransportError("execution deadline exceeded")
            return future.result()
        except asyncio.CancelledError as error:
            if cancellations is None or future.cancelled():
                raise
            if not cancellations:
                cancellations.append(error)


def _discard(future: asyncio.Future[Any]) -> None:
    if not future.cancelled():
        future.exception()


@dataclass
class _Stream:
    kinds: Any
    cap: int
    state: CleanupState
    handle: Any = None
    opening: asyncio.Future[Any] | None = None
    receiving: asyncio.Future[Any] | None = None
    started: bool = False
    exited: int | None = None
    closed: bool = False
    total: int = 0
    stdout: bytearray = field(default_factory=bytearray)

    async def recv(self, deadline: float,
                   cancellations: list[asyncio.CancelledError] | None = None) -> Any:
        if self.receiving is None:
            self.receiving = asyncio.ensure_future(self.handle.recv())
        event = await _until(self.receiving, deadline, cancellations)
        self.receiving = None
        return event

    def accept(self, event: Any, *, collecting: bool) -> None:
        if event is None:
            self.closed = True
            self.state.closed = True
            if self.exited is None:
                raise UncertainExecution("stream closed without observed exit")
            return
        if self.exited is not None:
            raise TransportError("event after exit")
        kind, pid, data, code = event.event_type, event.pid, event.data, event.code
        if kind is self.kinds.STARTED:
            if (self.started or type(pid) is not int or not 0 < pid <= 2**32 - 1
                    or data is not None or code is not None):
                raise TransportError("invalid started event")
            self.started = True
            self.state.started = True
        elif kind is self.kinds.STDOUT or kind is self.kinds.STDERR:
            if not self.started or pid is not None or code is not None:
                raise TransportError("out of order output")
            self.output(data, kind is self.kinds.STDOUT, collecting)
        elif kind is self.kinds.EXITED:
            if (not self.started or type(code) is not int or not -(2**31) <= code < 2**31
                    or pid is not None or data is not None):
                raise TransportError("invalid exit event")
            self.exited = code
            self.state.confirmed_terminal = True
        elif kind is self.kinds.FAILED:
            raise UncertainExecution("SDK failed event; termination unverified")
        elif kind is self.kinds.STDIN_ERROR:
            raise TransportError("unexpected stdin error")
        else:
            raise TransportError("unknown execution event")

    def output(self, data: Any, stdout: bool, collecting: bool) -> None:
        # PyO3 Vec<u8> getters can expose list[int]; accept bytes as well.
        if type(data) not in (bytes, list):
            raise TransportError("invalid output data")
        if len(data) > self.cap - self.total:
            raise TransportError("combined output limit exceeded")
        if type(data) is list and any(type(n) is not int or not 0 <= n <= 255 for n in data):
            raise TransportError("invalid output data")
        self.total += len(data)
        if collecting and stdout:
            self.stdout.extend(data)

    async def drain(self, deadline: float, *, collecting: bool,
                    cancellations: list[asyncio.CancelledError] | None = None) -> None:
        while not self.closed:
            self.accept(await self.recv(deadline, cancellations), collecting=collecting)
            # A ready SDK future / empty event must not starve timers or cancellation.
            try:
                await asyncio.sleep(0)
            except asyncio.CancelledError as error:
                if cancellations is None:
                    raise
                if not cancellations:
                    cancellations.append(error)

    def abandon(self) -> None:
        # No second reader is started. Native cancellation is NOT termination proof.
        for pending in (self.opening, self.receiving):
            if pending is not None:
                pending.cancel()
                pending.add_done_callback(_discard)


async def _cleanup(stream: _Stream, deadline: float,
                   cancellations: list[asyncio.CancelledError]) -> None:
    control = None
    try:
        if stream.handle is None:
            if stream.opening is None:
                raise UncertainExecution("execution handle unavailable")
            stream.handle = await _until(stream.opening, deadline, cancellations)
        if stream.exited is None:
            control = asyncio.ensure_future(stream.handle.kill())
            await _until(control, deadline, cancellations)
        await stream.drain(deadline, collecting=False, cancellations=cancellations)
        if stream.exited is None:
            raise UncertainExecution("cleanup has no observed exit")
    except Exception:
        raise UncertainExecution("cleanup could not verify termination and stream closure") from None
    finally:
        if control is not None:
            control.cancel()
            control.add_done_callback(_discard)


async def _settle(stream: _Stream, seconds: float) -> tuple[bool, asyncio.CancelledError | None]:
    deadline = asyncio.get_running_loop().time() + seconds
    cancellations: list[asyncio.CancelledError] = []
    try:
        # Inline cleanup: no detached supervisor task to outlive this attempt.
        # _until shields the operand, records repeated cancellation, and always
        # checks the same deadline rather than granting a fresh cleanup budget.
        await _cleanup(stream, deadline, cancellations)
        settled = True
    except (Exception, asyncio.CancelledError):
        settled = False
    finally:
        stream.abandon()
    stream.state.uncertain = not settled
    return settled, cancellations[0] if cancellations else None


async def _execute(stream: _Stream, sandbox: Any, argv: tuple[str, ...],
                   env: dict[str, str], stdin: Any, timeout: float,
                   cleanup_timeout: float) -> None:
    deadline = asyncio.get_running_loop().time() + timeout
    try:
        stream.state.dispatched = True
        stream.state.uncertain = True
        stream.opening = asyncio.ensure_future(sandbox.exec_stream(
            argv[0], list(argv[1:]), user="agent", env=env, timeout=timeout,
            stdin=stdin, tty=False,
        ))
        stream.handle = await _until(stream.opening, deadline)
        await stream.drain(deadline, collecting=True)
        stream.state.uncertain = False
    except (Exception, asyncio.CancelledError) as primary:
        settled, later_cancel = await _settle(stream, cleanup_timeout)
        cancellation = primary if isinstance(primary, asyncio.CancelledError) else later_cancel
        if cancellation is not None:
            if not settled:
                raise cancellation from UncertainExecution("cancelled execution requires quarantine")
            raise cancellation from None
        if not settled:
            raise UncertainExecution("execution requires quarantine; cleanup unverified") from None
        if isinstance(primary, TransportError):
            if isinstance(primary, UncertainExecution):
                stream.state.uncertain = True
            raise primary from None
        raise TransportError("SDK execution refused") from None


async def prepare(sandbox: Any, expected: InvocationIdentity, *, state: CleanupState, node: str,
                  artifact: str, provider_root: str, global_dir: str, base_config: str,
                  env: dict[str, str], timeout: float = 30.0,
                  cleanup_timeout: float = 2.0,
                  max_output_bytes: int = MAX_OUTPUT_BYTES) -> PreparationResult:
    """Run once on a caller-owned connected Sandbox; never redispatch.

    Caller owns identity, lifecycle barrier, trusted paths, clean guest baseline,
    explicit environment and CA. An SDK env override is NOT an environment reset.
    Cancellation stays CancelledError; an UncertainExecution cause requires the
    same quarantine as a directly raised UncertainExecution.
    """
    if type(expected) is not InvocationIdentity:
        raise TransportError("invalid host invocation identity")
    if type(state) is not CleanupState or any(value is not False for value in (
        state.dispatched, state.started, state.confirmed_terminal, state.closed, state.uncertain,
    )):
        raise TransportError("fresh caller cleanup state required")
    _seconds(timeout)
    _seconds(cleanup_timeout)
    if type(max_output_bytes) is not int or not 0 < max_output_bytes <= MAX_OUTPUT_BYTES:
        raise TransportError("invalid combined output limit")
    argv = build_argv(node=node, artifact=artifact, provider_root=provider_root,
                      global_dir=global_dir, base_config=base_config)
    clean_env = _environment(env)
    try:
        stdin_type, kinds = _sdk_types()
        stdin = stdin_type.null()
    except Exception:
        raise TransportError("preinstalled microsandbox 0.7.16 types unavailable") from None
    stream = _Stream(kinds, max_output_bytes, state)
    await _execute(stream, sandbox, argv, clean_env, stdin, timeout, cleanup_timeout)
    if stream.exited is None:  # Defensive: parse only an observed EXITED status.
        raise UncertainExecution("execution exit unverified")
    return parse_result(expected, returncode=stream.exited, stdout=bytes(stream.stdout))
