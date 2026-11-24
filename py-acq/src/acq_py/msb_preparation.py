"""Narrow POSIX managed-job transport for the guest preparation protocol.

No lifecycle writes, activation, credential handling, or guest shell. See
docs/explorations/python-msb-preparation.md for the trust and cancellation limits.
"""

from __future__ import annotations

import json
import math
import os
import re
import selectors
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import PurePosixPath

from . import msb
from .runtime_preparation import (
    MAX_OUTPUT_BYTES,
    InvocationIdentity,
    PreparationError,
    PreparationResult,
    build_argv,
    parse_result,
)

CONTROL_BYTES = 262144
STDERR_BYTES = 16384
# MSB 0.7.16 accepts --limit only in 1..100. Refuse an incomplete page before
# launch; supervise the acknowledged job directly rather than enumerating again.
MAX_JOBS = 100
CLEANUP_SECONDS = 5.0
# Host-selected provisioned devenv runtime. Never resolve this with guest PATH
# or command -v; image qualification is separate from transport qualification.
PROFILE_NODE = "/usr/bin/node"
_JOB = re.compile(r"job_[0-9a-f]{32}")
_BOOT = re.compile(r"boot_[0-9a-f]{32}")
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")
_USER = re.compile(r"[a-z_][a-z0-9_-]{0,31}")

# Fixed guest program, never assembled from provider data. The placeholder is
# expanded only inside the target VM and is never captured on the host. This is
# operational hygiene for the provisioned OS, not malicious-root attestation.
_CLEAN_LAUNCH = (
    'set -eu; set +x; ca=$1; provider=$2; shift 2; '
    'if test "$provider" = usai; then test -n "${USAI_API_KEY:-}"; fi; '
    'test -f "$ca"; test -s "$ca"; '
    'test ! -w "$ca"; test "$(/usr/bin/wc -c < "$ca")" -le 2097152; '
    'p=$ca; while test "$p" != /; do '
    'test ! -L "$p"; test ! -w "$p"; p=${p%/*}; test -n "$p" || p=/; done; '
    'test ! -w /; '
    'if test "$provider" = usai; then set -- "USAI_API_KEY=$USAI_API_KEY" "$@"; fi; '
    'exec /usr/bin/env -i HOME=/home/agent PATH=/usr/bin:/bin LANG=C '
    '"NODE_EXTRA_CA_CERTS=$ca" "$@"'
)
# These overrides take effect before the fixed shell starts. env -i then drops
# all remaining variables before Node (including unrelated injected secrets).
_INITIAL_ENV = (
    "PATH=/usr/bin:/bin", "ENV=", "BASH_ENV=", "SHELLOPTS=", "BASHOPTS=",
    "LD_PRELOAD=", "LD_LIBRARY_PATH=", "LD_AUDIT=", "NODE_OPTIONS=",
    "NODE_PATH=", "NODE_EXTRA_CA_CERTS=", "NODE_TLS_REJECT_UNAUTHORIZED=1",
)


class ManagedJobError(PreparationError):
    """Fixed diagnostic; never contains backend output or argv."""


class CleanupUnconfirmed(ManagedJobError):
    """Launch may have occurred; caller must quarantine rather than activate."""


@dataclass(frozen=True)
class _Output:
    code: int
    stdout: bytes


@dataclass(frozen=True)
class _Job:
    boot: str
    state: str
    code: int | None
    timed_out: bool
    failed: bool


def _remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ManagedJobError("MSB preparation deadline exceeded")
    return remaining


def _reap_host(proc: subprocess.Popen[bytes]) -> None:
    # This only ends the host transport group. It says NOTHING about the guest.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        raise ManagedJobError("MSB host transport cleanup unconfirmed") from None


def _capture(command: tuple[str, ...], args: list[str], deadline: float,
             stdout_limit: int = CONTROL_BYTES) -> _Output:
    _remaining(deadline)
    try:
        proc = subprocess.Popen(
            [*command, *args], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True,
        )
    except OSError:
        raise ManagedJobError("MSB transport unavailable") from None
    if proc.stdout is None or proc.stderr is None:
        _reap_host(proc)
        raise ManagedJobError("MSB transport pipes unavailable")
    buffers = [bytearray(), bytearray()]
    limits = (stdout_limit, STDERR_BYTES)
    try:
        with selectors.DefaultSelector() as selector:
            for index, stream in enumerate((proc.stdout, proc.stderr)):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, index)
            while selector.get_map():
                for key, _ in selector.select(min(_remaining(deadline), 0.05)):
                    index = key.data
                    chunk = os.read(key.fd, min(8192, limits[index] - len(buffers[index]) + 1))
                    if not chunk:
                        selector.unregister(key.fileobj)
                    elif len(buffers[index]) + len(chunk) > limits[index]:
                        raise ManagedJobError("MSB preparation output limit exceeded")
                    else:
                        buffers[index].extend(chunk)
            try:
                code = proc.wait(timeout=_remaining(deadline))
            except subprocess.TimeoutExpired:
                raise ManagedJobError("MSB preparation deadline exceeded") from None
        return _Output(code, bytes(buffers[0]))
    except BaseException as exc:
        try:
            _reap_host(proc)
        except BaseException:
            if isinstance(exc, Exception):
                raise
            # A control-client reap failure must not replace parent termination
            # (_Terminated/SystemExit/KeyboardInterrupt) with an ordinary error.
            # The launch owner retains durable guest-cleanup exclusion.
        raise
    finally:
        proc.stdout.close()
        proc.stderr.close()


def _control(command: tuple[str, ...], args: list[str], deadline: float) -> bytes:
    result = _capture(command, args, deadline)
    if result.code != 0:
        raise ManagedJobError("MSB managed-job control refused")
    return result.stdout


def _capabilities(command: tuple[str, ...], deadline: float) -> None:
    # Only the qualified native version; do not infer future compatibility.
    version = _control(command, ["--version"], deadline).strip()
    if version != b"msb 0.7.16":
        raise ManagedJobError("unsupported MSB managed-job version")
    required = {
        "exec": (b"--detach", b"--no-stdin", b"--timeout", b"--user"),
        "attach": (b"--job", b"--read-only"),
        "jobs": (b"--all", b"--format", b"--limit"),
        "inspect": (b"--job", b"--format"),
        "signal": (b"--job", b"--signal"),
        "kill": (b"--job",),
    }
    for verb, flags in required.items():
        help_bytes = _control(command, [verb, "--help"], deadline)
        if any(re.search(rb"(?<![\w-])" + flag + rb"(?=[\s=,]|$)", help_bytes) is None
               for flag in flags):
            raise ManagedJobError("unsupported MSB managed-job capabilities")


def _unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _constant(_value: str) -> object:
    raise ValueError("nonfinite JSON")


def _inventory(raw: bytes) -> list[dict]:
    try:
        document = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique,
                              parse_constant=_constant)
    except (ValueError, RecursionError):
        raise ManagedJobError("invalid MSB job inventory") from None
    if (type(document) is not dict or set(document) != {"items", "next_cursor"}
            or type(document["items"]) is not list
            or len(document["items"]) > MAX_JOBS):
        raise ManagedJobError("invalid MSB job inventory")
    # No unqualified cursor syntax, truncated inventory, or unbounded traversal.
    if document["next_cursor"] is not None:
        raise ManagedJobError("MSB paginated job inventory unsupported")
    seen: set[str] = set()
    for item in document["items"]:
        if (type(item) is not dict or type(item.get("id")) is not str
                or _JOB.fullmatch(item["id"]) is None or item["id"] in seen):
            raise ManagedJobError("invalid or ambiguous MSB job identity")
        seen.add(item["id"])
    return document["items"]


def _job_fields(item: dict, argv: tuple[str, ...], boot: str | None) -> _Job:
    required = {"version", "id", "runtime_boot_id", "command", "state", "tty",
                "stdin_closed", "pid", "created_at", "started_at", "finished_at",
                "exit_code", "failure", "error", "timed_out"}
    if (set(item) != required or type(item["version"]) is not int or item["version"] != 1
            or type(item["runtime_boot_id"]) is not str
            or _BOOT.fullmatch(item["runtime_boot_id"]) is None
            or (boot is not None and item["runtime_boot_id"] != boot)
            or item["command"] != list(argv) or item["tty"] is not False
            or item["stdin_closed"] is not True or type(item["timed_out"]) is not bool
            or item["state"] not in ("running", "exited")):
        raise ManagedJobError("invalid MSB exact-job status")
    for field in ("created_at", "started_at", "pid"):
        if type(item[field]) is not int or item[field] <= 0:
            raise ManagedJobError("invalid MSB exact-job status")
    terminal = item["state"] == "exited"
    if terminal:
        if (type(item["exit_code"]) is not int or not -1 <= item["exit_code"] <= 255
                or type(item["finished_at"]) is not int
                or item["finished_at"] < item["started_at"]):
            raise ManagedJobError("invalid MSB exact-job terminal status")
    elif (item["exit_code"] is not None or item["finished_at"] is not None
          or item["timed_out"] or item["failure"] is not None or item["error"] is not None):
        raise ManagedJobError("invalid MSB exact-job running status")
    if item["started_at"] < item["created_at"]:
        raise ManagedJobError("invalid MSB exact-job timestamps")
    # Failure/error need no interpretation: any non-null value refuses success.
    return _Job(item["runtime_boot_id"], item["state"], item["exit_code"],
                item["timed_out"], item["failure"] is not None or item["error"] is not None)


def _status(command: tuple[str, ...], name: str, job: str, argv: tuple[str, ...],
            boot: str | None, deadline: float) -> _Job:
    # An acknowledged job can push the inventory onto another page. Never make
    # its supervision or cleanup depend on complete enumeration of other jobs.
    raw = _control(command, ["inspect", "--job", job, "--format", "json", name], deadline)
    try:
        item = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique,
                          parse_constant=_constant)
    except (ValueError, RecursionError):
        raise ManagedJobError("invalid MSB exact-job status") from None
    if type(item) is not dict or item.get("id") != job:
        raise ManagedJobError("MSB exact job identity mismatch")
    return _job_fields(item, argv, boot)


def _cleanup(command: tuple[str, ...], name: str, job: str, argv: tuple[str, ...],
             boot: str | None) -> None:
    deadline = time.monotonic() + CLEANUP_SECONDS
    # A refused signal can mean the job already exited. Only status confirms it.
    for args, grace in ((["signal", "--job", job, "--signal", "TERM", name],
                         min(1.0, CLEANUP_SECONDS / 3)),
                        (["kill", "--job", job, name], CLEANUP_SECONDS)):
        try:
            _control(command, args, min(deadline, time.monotonic() + 0.5))
        except ManagedJobError:
            pass
        phase_end = min(deadline, time.monotonic() + grace)
        while time.monotonic() < phase_end:
            try:
                status = _status(command, name, job, argv, boot,
                                 min(phase_end, time.monotonic() + 0.5))
                if boot is None:
                    boot = status.boot
                if status.state == "exited":
                    return
            except ManagedJobError:
                pass
            time.sleep(min(0.05, max(0.0, phase_end - time.monotonic())))
    raise CleanupUnconfirmed("MSB guest cleanup unconfirmed; quarantine required")


def _completed(command: tuple[str, ...], name: str, job: str, argv: tuple[str, ...],
               boot: str, deadline: float) -> _Job:
    while True:
        status = _status(command, name, job, argv, boot, deadline)
        if status.state == "exited":
            return status
        time.sleep(min(0.05, _remaining(deadline)))


def _run_job(command: tuple[str, ...], name: str, identity: InvocationIdentity,
             argv: tuple[str, ...], guest_user: str, deadline: float,
             previous: set[str], env: tuple[str, ...] = ()) -> PreparationResult:
    job: str | None = None
    boot: str | None = None
    try:
        # Floor to milliseconds: never round a guest deadline up beyond the host budget.
        milliseconds = math.floor(_remaining(deadline) * 1000)
        if milliseconds < 1:
            raise ManagedJobError("MSB preparation deadline exceeded")
        flags = [part for entry in env for part in ("-e", entry)]
        detached = _control(command, ["exec", "--detach", "--no-stdin", "--timeout",
                            f"{milliseconds}ms", "--user", guest_user, *flags, name, "--", *argv], deadline)
        if re.fullmatch(rb"job_[0-9a-f]{32}\n?", detached) is None:
            raise ManagedJobError("invalid MSB detached job identity")
        candidate = detached.decode("ascii").rstrip("\n")
        if candidate in previous:
            raise ManagedJobError("MSB detached job identity was reused")
        job = candidate
        initial = _status(command, name, job, argv, None, deadline)
        boot = initial.boot
        attached = _capture(command, ["attach", "--read-only", "--job", job, name],
                            deadline, MAX_OUTPUT_BYTES)
        final = _completed(command, name, job, argv, boot, deadline)
        if final.timed_out or final.failed:
            raise ManagedJobError("MSB preparation job failed or timed out")
        if final.code == 0 and attached.code != 0:
            raise ManagedJobError("MSB preparation attach failed")
        if final.code is None:
            raise ManagedJobError("MSB preparation terminal status missing")
        return parse_result(identity, returncode=final.code, stdout=attached.stdout)
    except BaseException:
        if job is None:
            raise CleanupUnconfirmed("MSB launch identity unavailable; quarantine required") from None
        try:
            _cleanup(command, name, job, argv, boot)
        except BaseException:
            raise CleanupUnconfirmed("MSB guest cleanup unconfirmed; quarantine required") from None
        raise


def run_preparation(name: str, identity: InvocationIdentity, *, node: str,
                    artifact: str, provider_root: str, global_dir: str,
                    base_config: str, guest_user: str = "agent",
                    timeout: float = 60.0, ca_bundle: str | None = None,
                    usai: bool = True) -> PreparationResult:
    """Return invocation-bound evidence, never permission to activate/reuse.

    Caller holds the lifecycle barrier and trusts the resolved host CLI, guest
    paths, mount provenance and identity. CleanupUnconfirmed requires quarantine.
    KeyboardInterrupt/SystemExit clean up then propagate if cleanup is confirmed.
    """
    if type(usai) is not bool:
        raise ManagedJobError("invalid provider selection")
    if os.name != "posix":
        raise ManagedJobError("MSB preparation requires POSIX")
    if (type(name) is not str or _NAME.fullmatch(name) is None
            or type(guest_user) is not str or _USER.fullmatch(guest_user) is None
            or type(identity) is not InvocationIdentity
            or type(timeout) not in (int, float) or not 0 < timeout <= 300
            or not math.isfinite(timeout)):
        raise ManagedJobError("invalid MSB preparation invocation")
    argv = build_argv(node=node, artifact=artifact, provider_root=provider_root,
                      global_dir=global_dir, base_config=base_config)
    env: tuple[str, ...] = ()
    if ca_bundle is not None:
        if (type(ca_bundle) is not str or not ca_bundle.startswith("/")
                or re.fullmatch(r"/[A-Za-z0-9._/-]+", ca_bundle) is None
                or PurePosixPath(ca_bundle).as_posix() != ca_bundle
                or ".." in PurePosixPath(ca_bundle).parts):
            raise ManagedJobError("invalid approved guest CA path")
        if guest_user != "agent":
            raise ManagedJobError("clean preparation requires the unprivileged agent user")
        argv = ("/bin/sh", "-c", _CLEAN_LAUNCH, "acq-preparation", ca_bundle, "usai" if usai else "none", *argv)
        env = _INITIAL_ENV
    deadline = time.monotonic() + timeout
    try:
        command = tuple(msb.msb_command())
    except OSError:
        raise ManagedJobError("MSB transport unavailable") from None
    if (not command or any(type(arg) is not str or "\0" in arg for arg in command)
            or not os.path.isabs(command[0])):
        raise ManagedJobError("invalid trusted MSB command")
    _capabilities(command, deadline)
    previous = {item["id"] for item in _inventory(
        _control(command, ["jobs", "--all", "--limit", str(MAX_JOBS),
                           "--format", "json", name], deadline))}
    return _run_job(command, name, identity, argv, guest_user, deadline, previous, env)
