"""Fresh target-VM preparation for the plain packaged terminal profile.

The caller holds the lifecycle lock; preparation additionally holds the shared
store lock. Guest completion is operational evidence, never host routing or
credential authority (ADR-0054). No result survives this call or permits reuse.
"""

from __future__ import annotations

import copy
import errno
import json
import os
import re
import signal
import stat
import subprocess
import sys
import threading
import time
import uuid
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from . import (
    errors,
    fresh_inputs,
    hostexec,
    kit_msb,
    kits,
    kitspec,
    lock,
    msb,
    msb_preparation,
    provider_input,
    security,
)
from .runtime_preparation import InvocationIdentity, PreparationError, require_current

GLOBAL_CONFIG = "/home/agent/.config/opencode"
_CA_LIMIT = 2 * 1024 * 1024


@dataclass
class LaunchOwnership:
    """One foreground launch's cleanup ownership, established before spawn.

    This is not reusable admission evidence. Callers keep this context outside
    their lifecycle lock, through the handoff and wait, including BaseException.
    """

    name: str
    command: tuple[str, ...] = ()
    argv: tuple[str, ...] = ()
    tty: bool = False
    proc: subprocess.Popen | None = None
    ca_path: Path | None = None
    job: str | None = None
    boot: str | None = None
    spawned: bool = False
    completed: bool = False
    ending_signal: int = signal.SIGTERM
    attempt_path: Path | None = None
    attempt_fd: int | None = None
    sandbox_instance: str | None = None
    retired: bool = False
    termination: BaseException | None = None
    interrupt_handler: hostexec._Handler | None = None
    interrupt_held: bool = False


@contextmanager
def own_launch(name: str) -> Iterator[LaunchOwnership]:
    owner = LaunchOwnership(name)
    saved: dict[int, hostexec._Handler] = {}
    failure: BaseException | None = None
    cleanup_failure: BaseException | None = None
    def terminated(signum: int, frame) -> None:
        previous = saved[signum]
        try:
            if callable(previous):
                previous(signum, frame)
        except BaseException as exc:
            if owner.termination is None:
                owner.termination = exc
                owner.ending_signal = signum
            raise

    try:
        if threading.current_thread() is threading.main_thread():
            for watched_signal in (signal.SIGTERM, signal.SIGHUP):
                previous = signal.getsignal(watched_signal)
                # Delegate the installed CLI handler; preserve ignored/default
                # dispositions rather than inventing a new termination policy.
                if callable(previous):
                    saved[watched_signal] = previous
                    signal.signal(watched_signal, terminated)
        yield owner
    except BaseException as exc:
        failure = exc
        exception_signal = getattr(exc, "signum", None)
        if exception_signal in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            owner.ending_signal = exception_signal
    finally:
        # Cleanup never replaces _Terminated/KeyboardInterrupt or a handoff
        # exception. The CLI boundary remains responsible for signal exit codes.
        try:
            _release_launch(owner)
        except BaseException as exc:
            cleanup_failure = exc
        if owner.attempt_fd is not None:
            try:
                os.close(owner.attempt_fd)
                owner.attempt_fd = None
            except BaseException as exc:
                if cleanup_failure is None:
                    cleanup_failure = exc
        if owner.interrupt_held and owner.interrupt_handler is not None:
            try:
                signal.signal(signal.SIGINT, owner.interrupt_handler)
                owner.interrupt_held = False
            except BaseException as exc:
                if cleanup_failure is None:
                    cleanup_failure = exc
        for saved_signal, previous in saved.items():
            try:
                signal.signal(saved_signal, previous)
            except BaseException as exc:
                if cleanup_failure is None:
                    cleanup_failure = exc
    if cleanup_failure is not None and (owner.termination is not None or failure is not None):
        try:
            print("acq: foreground finalization failed; original termination or failure preserved", file=sys.stderr)
        except BaseException:
            pass  # A failed diagnostic must not replace the primary exception.
    if owner.termination is not None:
        raise owner.termination
    if failure is not None:
        raise failure
    if cleanup_failure is not None:
        raise cleanup_failure


def _attempts(name: str) -> Path:
    # Host-only sibling, NOT inside the guest-mounted host-config directory.
    return security.host_config_dir(name).with_suffix(".fresh-launches")


def _sync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_attempt(owner: LaunchOwnership, phase: str) -> None:
    if owner.attempt_fd is None or owner.attempt_path is None:
        raise _refuse("foreground attempt persistence is unavailable")
    raw = json.dumps({"version": 1, "phase": phase, "instance": owner.sandbox_instance,
                      "job": owner.job, "boot": owner.boot,
                      "argv": owner.argv, "tty": owner.tty}, separators=(",", ":")).encode()
    if len(raw) > 131072:
        raise _refuse("foreground attempt exceeds the bounded record size")
    os.lseek(owner.attempt_fd, 0, os.SEEK_SET)
    os.ftruncate(owner.attempt_fd, 0)
    with os.fdopen(os.dup(owner.attempt_fd), "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    _sync_dir(owner.attempt_path.parent)


def _begin_attempt(owner: LaunchOwnership) -> None:
    import fcntl

    root = _attempts(owner.name)
    owner.sandbox_instance = msb.held_read(owner.name).instance
    if owner.sandbox_instance is None:
        raise _refuse("foreground attempt requires a current sandbox instance")
    provider_input._safe_dir(root)
    # Sync every containing directory, including parents created by _safe_dir.
    # Syncing only root would not persist its own entry after first creation.
    for directory in (root, *root.parents):
        _sync_dir(directory)
    owner.attempt_path = root / (uuid.uuid4().hex + ".json")
    owner.attempt_fd = os.open(owner.attempt_path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    fcntl.flock(owner.attempt_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    _write_attempt(owner, "pending")


def _admission_attempts(name: str) -> None:
    """Caller holds lifecycle lock. Healthy live owners may coexist; unknown may not."""
    import fcntl

    root = _attempts(name)
    if not os.path.lexists(root):
        return
    if root.is_symlink() or not root.is_dir():
        raise _refuse("unsafe foreground attempt directory")
    command = tuple(msb.msb_command())
    deadline = time.monotonic() + 15
    with os.scandir(root) as entries:
        for index, entry in enumerate(entries):
            if index >= 32 or re.fullmatch(r"[0-9a-f]{32}\.json", entry.name) is None:
                raise _refuse("foreground attempt inventory is unsafe or full")
            fd = os.open(root / entry.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_size > 131072 or info.st_nlink != 1:
                    raise _refuse("invalid foreground attempt record")
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError as exc:
                    if exc.errno not in (errno.EACCES, errno.EAGAIN):
                        raise
                else:
                    raise _refuse("abandoned foreground attempt requires sandbox removal/recreation")
                raw = os.read(fd, 131073)
                doc = json.loads(raw, object_pairs_hook=msb_preparation._unique)
                if (not isinstance(doc, dict) or set(doc) != {"version", "phase", "instance", "job", "boot", "argv", "tty"}
                        or doc["version"] != 1 or doc["phase"] != "active"
                        or not isinstance(doc["instance"], str) or doc["instance"] != msb.held_read(name).instance
                        or not isinstance(doc["argv"], list) or type(doc["tty"]) is not bool
                        or not all(isinstance(arg, str) for arg in doc["argv"])
                        or not isinstance(doc["job"], str) or msb_preparation._JOB.fullmatch(doc["job"]) is None
                        or not isinstance(doc["boot"], str) or msb_preparation._BOOT.fullmatch(doc["boot"]) is None):
                    raise _refuse("unresolved foreground attempt blocks admission")
                previous = LaunchOwnership(name, command=command, argv=tuple(doc["argv"]),
                                           tty=doc["tty"], job=doc["job"], boot=doc["boot"])
                if _terminal_job(previous, deadline):
                    raise _refuse("completed foreground attempt is awaiting owner cleanup")
            finally:
                os.close(fd)


def _terminal_job(owner: LaunchOwnership, deadline: float) -> bool:
    if owner.job is None or owner.boot is None:
        return False
    raw = msb_preparation._control(owner.command,
        ["inspect", "--job", owner.job, "--format", "json", owner.name], deadline)
    item = json.loads(raw, object_pairs_hook=msb_preparation._unique,
                      parse_constant=msb_preparation._constant)
    if (not isinstance(item, dict) or item.get("id") != owner.job
            or item.get("runtime_boot_id") != owner.boot
            or item.get("command") != list(owner.argv) or item.get("tty") is not owner.tty
            or type(item.get("stdin_closed")) is not bool):
        raise PreparationError("foreground exact-job identity changed")
    # Reuse the closed preparation status validator after validating the two
    # intentional foreground differences (TTY and open stdin) above.
    normalized = {**item, "tty": False, "stdin_closed": True}
    status = msb_preparation._job_fields(normalized, owner.argv, owner.boot)
    return status.state == "exited"


def _end_host(owner: LaunchOwnership) -> bool:
    if owner.proc is None:
        return not owner.spawned
    try:
        if owner.proc.poll() is not None:
            return True
        owner.proc.send_signal(owner.ending_signal)
        try:
            owner.proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            owner.proc.kill()
            owner.proc.wait(timeout=1)
        return True
    except BaseException:
        return False


def _end_guest(owner: LaunchOwnership) -> bool:
    if not owner.spawned:
        return True
    if owner.job is None or owner.boot is None:
        return False
    deadline = time.monotonic() + msb_preparation.CLEANUP_SECONDS
    for action in (None, "signal", "kill"):
        try:
            # Never signal a job unless its identity still matches. A boot or
            # argv mismatch is uncertainty, not permission to target another job.
            if _terminal_job(owner, deadline):
                return True
            if action is not None:
                flags = [action, "--job", owner.job]
                if action == "signal":
                    flags += ["--signal", "TERM"]
                msb_preparation._control(owner.command, [*flags, owner.name], deadline)
            phase_end = min(deadline, time.monotonic() + (0.2 if action != "kill" else 1.0))
            while time.monotonic() < phase_end:
                if _terminal_job(owner, deadline):
                    return True
                time.sleep(0.05)
        except (PreparationError, ValueError, TypeError, KeyError):
            continue
    return False


def _release_launch(owner: LaunchOwnership) -> None:
    if owner.completed or owner.retired:
        return
    if owner.attempt_path is None and not owner.spawned:
        if owner.ca_path is not None:
            owner.ca_path.unlink(missing_ok=True)
        owner.completed = True
        return
    try:
        with lock.sandbox_lock("msb", owner.name):
            try:
                _release_locked(owner)
            finally:
                # Publish abandonment before releasing the lifecycle lock even
                # if the durable phase update failed. No admission may observe
                # an old active record with a live ownership lock during cleanup.
                if owner.attempt_fd is not None:
                    os.close(owner.attempt_fd)
                    owner.attempt_fd = None
    except BaseException:
        if owner.attempt_fd is not None:
            os.close(owner.attempt_fd)
            owner.attempt_fd = None
        # The original durable pending/active record remains. Once ownership's
        # fd closes, its abandoned lock excludes the next admission even if a
        # disk-full condition prevented writing cleanup/quarantine state.
        print("acq: foreground cleanup unconfirmed; durable attempt retained; remove/recreate before admission", file=sys.stderr)


def _owns_current_attempt(owner: LaunchOwnership) -> bool:
    """Called under lifecycle lock; a reused name/path is not this owner."""
    if owner.attempt_path is None or owner.attempt_fd is None or owner.sandbox_instance is None:
        return False
    try:
        opened = os.fstat(owner.attempt_fd)
        current = owner.attempt_path.lstat()
        return (stat.S_ISREG(current.st_mode) and opened.st_nlink == current.st_nlink == 1
                and (opened.st_dev, opened.st_ino) == (current.st_dev, current.st_ino)
                and msb.held_read(owner.name).instance == owner.sandbox_instance)
    except (OSError, msb.MsbError):
        return False


def _release_locked(owner: LaunchOwnership) -> None:
    if not _owns_current_attempt(owner):
        # rm/recreate may have retired this attempt while its foreground owner
        # was still unwinding. Never address the replacement's guest or state.
        host_ended = _end_host(owner)
        owner.retired = host_ended
        print("acq: foreground attempt identity retired or unavailable; old guest cleanup remains unconfirmed; replacement state untouched",
              file=sys.stderr)
        return
    persisted = True
    if owner.attempt_fd is not None:
        try:
            _write_attempt(owner, "cleanup")
        except OSError:
            persisted = False
    host_ended = _end_host(owner)
    try:
        guest_ended = _end_guest(owner)
    except BaseException:
        guest_ended = False
    if host_ended and guest_ended and persisted:
        try:
            if owner.ca_path is not None:
                owner.ca_path.unlink(missing_ok=True)
            if owner.attempt_path is not None:
                owner.attempt_path.unlink(missing_ok=True)
                _sync_dir(owner.attempt_path.parent)
            owner.completed = True
            return
        except OSError:
            pass
    # A durable cleanup record already excludes admission. This compatibility
    # marker is supplementary, never the sole crash/disk-failure protection.
    kit_msb.hc_write(owner.name, "fresh-quarantine", "1")
    raise _refuse("foreground cleanup unconfirmed; durable attempt retained")


def _refuse(message: str) -> msb.MsbError:
    return msb.MsbError(errors.VALIDATION_FAILED, message,
                        "verify the packaged profile, MSB mounts and interception CA; recreate if necessary")


def existing_profile(name: str, record: dict) -> None:
    """Check recorded selection before any resume, heal, or guest command."""
    from .commands.common import OPENCODE_DEVENV_IMAGE

    try:
        with kits.recorded_provider_selection("msb", name):
            refs, extras = kit_msb.cli_kits_read(name)
            selection = kit_msb.selection_for("opencode", refs,
                                             image_is_default=record.get("image") == OPENCODE_DEVENV_IMAGE,
                                             extras=extras)
            kit_msb.require_fresh_profile(selection,
                                         image_is_default=record.get("image") == OPENCODE_DEVENV_IMAGE)
    except (kits.ProviderSelectionError, kitspec.KitSelectionError):
        raise _refuse("recorded fresh profile selection is unavailable") from None


def terminal_refusal() -> msb.MsbError:
    return msb.MsbError(errors.UNSUPPORTED,
                        "this command is unsupported for the fresh plain OpenCode profile",
                        "use plain acq run or attach without daemon/subcommand arguments; exec/shell also require fresh admission")


def _inspect(name: str) -> dict:
    command = tuple(msb.msb_command())
    raw = msb_preparation._control(command, ["inspect", name, "--format", "json"], time.monotonic() + 15)
    try:
        document = json.loads(raw, object_pairs_hook=msb_preparation._unique,
                              parse_constant=msb_preparation._constant)
        if (type(document) is not dict or document.get("name") != name
                or document.get("status") != "Running" or document.get("pending_changes") != []
                or not isinstance(document.get("created_at"), str)
                or type(document.get("active_config")) is not dict):
            raise ValueError
        return document
    except (ValueError, RecursionError):
        raise _refuse("fresh preparation requires an unambiguous running backend instance") from None


def _mounted_inputs(name: str, document: dict) -> fresh_inputs.PreparedInputs:
    from .commands.common import OPENCODE_DEVENV_IMAGE

    active = document["active_config"]
    if (active.get("image", {}).get("Oci", {}).get("reference") != OPENCODE_DEVENV_IMAGE
            or active.get("deployment_profile") != "single_tenant"):
        raise _refuse("backend image or deployment profile differs from the plain packaged profile")
    env = active.get("env")
    if not isinstance(env, list):
        raise _refuse("backend provider-input environment is unavailable")
    roots = [entry.get("value") for entry in env
             if isinstance(entry, dict) and entry.get("key") == provider_input.ROOT_ENV]
    if len(roots) != 1 or not isinstance(roots[0], str):
        raise _refuse("backend provider-input root is missing or ambiguous")
    entries = msb._inspect_mounts(json.dumps(document))
    mounts = [mount for guest, mount in entries if guest == roots[0]]
    if len(mounts) != 1 or not isinstance(mounts[0].get("host"), str):
        raise _refuse("backend provider-input source is missing or ambiguous")
    inputs = fresh_inputs.read_existing(name, Path(mounts[0]["host"]))
    if inputs.guest_root != roots[0]:
        raise _refuse("backend provider-input generation differs from its mounted source")
    msb._check_ro_mount(entries, inputs.guest_root, [str(inputs.generation)])
    msb._check_ro_mount(entries, security.HOST_CONFIG_GUEST_DIR,
                        [str(security.host_config_dir(name))])
    return inputs


def _ca_source(name: str, document: dict) -> Path:
    """Resolve only the host original public cert; never inspect/read a key."""
    tls = document["active_config"]["network"]["tls"]
    if (tls.get("enabled") is not True or tls.get("verify_upstream") is not True
            or tls.get("bypass") != [] or tls.get("scoped_verify_upstream") != []):
        raise _refuse("fresh preparation requires verified TLS interception")
    custom = tls["intercept_ca"].get("cert_path")
    if custom is not None:
        source = Path(custom)
    else:
        storage = Path(document["storage"]["path"])
        if storage.name != name or storage.parent.name != "sandboxes":
            raise _refuse("backend storage does not establish the resolved MSB home")
        home = storage.parent.parent
        override = os.environ.get("MSB_HOME")
        if override is not None and Path(override) != home:
            raise _refuse("MSB home override and backend storage disagree")
        source = home / "tls/ca.crt"
    storage = Path(document["storage"]["path"])
    if (not source.is_absolute() or source.name == "ca.key" or source.is_relative_to(storage)
            or ".." in source.parts or source.as_posix() != str(source)):
        raise _refuse("interception CA is not an approved host public source")
    # Never adopt a certificate under a guest-writable host mount.
    for _guest, mount in msb._inspect_mounts(json.dumps(document)):
        host = mount.get("host")
        if isinstance(host, str) and source.is_relative_to(Path(host)):
            raise _refuse("interception CA source overlaps a guest mount")
    return source


def _public_ca(source: Path) -> bytes:
    """Bounded no-follow public certificate read, including every ancestor."""
    for path in (source, *source.parents):
        info = path.lstat()
        if (stat.S_ISLNK(info.st_mode) or info.st_mode & 0o022
                or info.st_uid not in (0, os.getuid())):
            raise _refuse("interception CA source or ancestor is unsafe")
    raw = fresh_inputs._read(Path("/"), source.as_posix().lstrip("/"), _CA_LIMIT)
    # A public-only PEM, never a mixed cert/key file. TLS itself validates trust.
    cert = rb"-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\s*"
    if not raw or re.fullmatch(rb"(?:" + cert + rb")+", raw) is None:
        raise _refuse("interception CA source is not a bounded public-only certificate")
    return raw


def _stage_ca(name: str, raw: bytes) -> str:
    # This is runtime host state, never repository content or guest readback.
    root = security.host_config_dir(name)
    if root.is_symlink() or not root.is_dir():
        raise _refuse("trusted host-config directory is unavailable")
    target = root / ("preparation-ca-" + uuid.uuid4().hex + ".crt")
    provider_input._copy_out(raw, target, 0o444)
    return security.HOST_CONFIG_GUEST_DIR + "/" + target.name


def _binding_snapshot(name: str, *, usai: bool = True):
    held = msb.held_read(name)
    snapshot = msb.held_apply_snapshot(name, store_locked=True)
    current = snapshot.services.get("usai")
    binding = held.bindings.get("USAI_API_KEY")
    if not usai:
        if not held.complete or not snapshot.instance or binding is not None:
            raise _refuse("provider-NONE profile requires an instance with no USAi binding")
        return copy.deepcopy((snapshot, held.bindings))
    if (not held.complete or not snapshot.instance or current is None or current.current is None
            or current.current.env != "USAI_API_KEY" or current.current.host != "api.gsa.usai.gov"
            or binding is None or binding.get("service") != "usai"
            or binding.get("host") != "api.gsa.usai.gov"):
        raise _refuse("fresh preparation requires the current USAi instance and binding")
    # Unknown revisions remain unknown. Live success, not applied status, gates.
    return copy.deepcopy((snapshot, held.bindings))


def _active_binding(document: dict, *, usai: bool = True) -> None:
    entries = document["active_config"]["network"]["secrets"]["secrets"]
    if not isinstance(entries, list):
        raise _refuse("backend secret bindings unavailable")
    matches = [entry for entry in entries if isinstance(entry, dict) and entry.get("env_var") == "USAI_API_KEY"]
    if not usai:
        if matches:
            raise _refuse("provider-NONE profile unexpectedly has an active USAi binding")
        return
    if len(matches) != 1:
        raise _refuse("backend USAi binding is missing or ambiguous")
    entry = matches[0]
    if any(other is not entry and isinstance(other, dict)
           and ({"exact": "api.gsa.usai.gov"} in other.get("allowed_hosts", [])
                or other.get("placeholder") == "$MSB_USAI_API_KEY") for other in entries):
        raise _refuse("backend USAi routing or placeholder is ambiguous")
    if (entry.get("allowed_hosts") != [{"exact": "api.gsa.usai.gov"}]
            or entry.get("require_tls_identity") is not True
            or entry.get("placeholder") != "$MSB_USAI_API_KEY"
            or entry.get("source") != {"kind": "env", "var": "USAI_API_KEY"}
            or entry.get("passthrough_hosts") != []
            or entry.get("substitution") != {"headers": True, "body": False, "query": False}):
        raise _refuse("backend USAi binding differs from the selected routing")


def prepare_locked(name: str) -> None:
    """Current-invocation live refresh before lifecycle success; no launch lease."""
    try:
        with msb.store_shared():
            with _prepare_locked(name):
                pass
    except (PreparationError, fresh_inputs.FreshInputsError, ValueError, KeyError,
            TypeError, AttributeError, OSError, kits.ProviderSelectionError, kitspec.KitSelectionError) as exc:
        if isinstance(exc, msb_preparation.CleanupUnconfirmed):
            kit_msb.hc_write(name, "fresh-quarantine", "1")
            raise _refuse("fresh preparation cleanup is unconfirmed; stop/remove the sandbox before retry") from None
        raise _refuse("fresh target-guest preparation failed; no lifecycle success or launch admitted") from None


@contextmanager
def _prepare_locked(name: str) -> Iterator[tuple[Callable[[], None], str]]:
    _admission_attempts(name)
    if kit_msb.hc_has(name, "fresh-quarantine"):
        raise _refuse("fresh launch is quarantined; remove and recreate the sandbox")
    before = _inspect(name)
    inputs = _mounted_inputs(name, before)
    _active_binding(before, usai=inputs.usai)
    # Persisted provider selection, not a guest inventory or a stale receipt,
    # determines whether this invocation is USAi or explicit NONE.
    with kits.recorded_provider_selection("msb", name):
        refs, extras = kit_msb.cli_kits_read(name)
        selection = kit_msb.selection_for("opencode", refs, image_is_default=True, extras=extras)
        # _mounted_inputs has already checked the exact image against the pin.
        kit_msb.require_fresh_profile(selection, image_is_default=True)
        if any(entry.role == "provider" for entry in selection.kits) != inputs.usai:
            raise _refuse("mounted generation differs from the selected provider profile")
    binding = _binding_snapshot(name, usai=inputs.usai)
    source = _ca_source(name, before)
    certificate = _public_ca(source)
    ca = _stage_ca(name, certificate)
    instance = binding[0].instance
    if instance is None:
        raise _refuse("missing sandbox instance")
    identity = InvocationIdentity(uuid.uuid4().hex, instance,
                                  inputs.generation.name, inputs.routing_digest,
                                  inputs.artifact_sha256, inputs.base_config_sha256)
    def recheck() -> None:
        after = _inspect(name)
        if (before["created_at"] != after["created_at"]
                or before["active_config"] != after["active_config"]
                or _mounted_inputs(name, after) != inputs or _binding_snapshot(name, usai=inputs.usai) != binding
                or _ca_source(name, after) != source or _public_ca(source) != certificate):
            raise _refuse("fresh preparation identity, bindings, mounts or CA changed")

    try:
        result = msb_preparation.run_preparation(
            name, identity, node=msb_preparation.PROFILE_NODE, artifact=inputs.guest_artifact,
            provider_root=inputs.guest_root, global_dir=GLOBAL_CONFIG,
            base_config=inputs.guest_base_config, ca_bundle=ca, usai=inputs.usai,
        )
        recheck()
        require_current(result, identity)
        yield recheck, ca
    finally:
        (security.host_config_dir(name) / ca.rsplit("/", 1)[1]).unlink(missing_ok=True)


def admit_locked(name: str, workspace: str | None, env: list[str], *, json_mode: bool,
                 ownership: LaunchOwnership, agent_args: list[str] | None = None,
                 guest_command: list[str] | None = None, tty: bool | None = None) -> LaunchOwnership:
    """Prepare then acknowledge foreground launch while both locks are held.

    Foreground stdio is connected before the harness can emit anything. The
    caller releases the lifecycle lock before wait_admitted; no detached replay.
    """
    if agent_args:
        raise terminal_refusal()
    if ownership.name != name or ownership.spawned or ownership.ca_path is not None:
        raise _refuse("invalid foreground cleanup ownership")
    try:
        with msb.store_shared():
            with _prepare_locked(name) as (recheck, ca):
                # A distinct attempt-private public copy survives the preparation
                # context until foreground completion. Never hand the harness
                # the backend's inaccessible/writable runtime-state CA path.
                source = security.host_config_dir(name) / ca.rsplit("/", 1)[1]
                public = fresh_inputs._read(source.parent, source.name, _CA_LIMIT)
                session_ca = _stage_ca(name, public)
                retained = security.host_config_dir(name) / session_ca.rsplit("/", 1)[1]
                ownership.ca_path = retained
                session_env = [entry for entry in env if entry.split("=", 1)[0] not in
                               ("NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "NODE_TLS_REJECT_UNAUTHORIZED")]
                session_env += ["NODE_EXTRA_CA_CERTS=" + session_ca, "SSL_CERT_FILE=" + session_ca,
                                "NODE_TLS_REJECT_UNAUTHORIZED=1"]
                _acknowledge_foreground(name, workspace, session_env, recheck,
                                        json_mode=json_mode, ownership=ownership,
                                        guest_command=guest_command, tty=tty)
                return ownership
    except (PreparationError, fresh_inputs.FreshInputsError, ValueError, KeyError, TypeError, AttributeError, OSError,
            kits.ProviderSelectionError, kitspec.KitSelectionError) as exc:
        if ownership.termination is not None:
            raise ownership.termination from None
        if isinstance(exc, msb_preparation.CleanupUnconfirmed):
            kit_msb.hc_write(name, "fresh-quarantine", "1")
        raise _refuse("fresh preparation or foreground launch acknowledgment failed; no launch success reported") from None
    except BaseException:
        # Preserve termination even if a context finalizer replaced it with an
        # adapter error not covered by the ordinary conversion above.
        if ownership.termination is not None:
            raise ownership.termination from None
        raise


def _launch_inventory(command: tuple[str, ...], name: str, deadline: float) -> list[dict]:
    return msb_preparation._inventory(msb_preparation._control(
        command, ["jobs", "--all", "--limit", str(msb_preparation.MAX_JOBS), "--format", "json", name], deadline))


def _acknowledge_foreground(name: str, workspace: str | None, env: list[str], recheck: Callable[[], None],
                            *, json_mode: bool, ownership: LaunchOwnership,
                            guest_command: list[str] | None = None, tty: bool | None = None) -> None:
    command = tuple(msb.msb_command())
    deadline = time.monotonic() + 15
    previous = _launch_inventory(command, name, deadline)
    if len(previous) >= msb_preparation.MAX_JOBS:
        raise _refuse("managed-job inventory has no room for unambiguous launch acknowledgment")
    nonce = "acq-launch-" + uuid.uuid4().hex
    # User exec argv remains separate positional data, never shell source or
    # authority for host configuration. The fixed wrapper only execs "$@".
    payload = ["/usr/local/bin/opencode", "--standalone"] if guest_command is None else guest_command
    if not payload or any(not isinstance(arg, str) or "\0" in arg for arg in payload):
        raise _refuse("invalid foreground guest command")
    guest = ["/bin/sh", "-c", 'exec "$@"', nonce, *payload]
    tty = hostexec.stdin_is_tty() if tty is None else tty
    flags = ["exec", "--tty" if tty else "--no-tty", "-u", "agent"]
    directory = msb.start_directory(name) or workspace
    if directory:
        flags += ["-w", directory]
    entries = ["HOME=/home/agent", "SHELL=" + msb.agent_shell(name), *env]
    if tty:
        entries += hostexec.terminal_env()
    for entry in entries:
        flags += ["-e", entry]
    recheck()
    ownership.command, ownership.argv, ownership.tty = command, tuple(guest), tty
    _begin_attempt(ownership)
    # Match hostexec.run_foreground: capture whole-job SIGINT before spawn,
    # including the acknowledgment/handoff interval. Never SIG_IGN the child.
    hostexec._interrupted = False
    ownership.interrupt_handler = hostexec._hold_interrupt()
    ownership.interrupt_held = ownership.interrupt_handler is not None
    ownership.spawned = True
    try:
        ownership.proc = subprocess.Popen([*command, *flags, name, "--", *guest], stdout=2 if json_mode else None)
    except OSError:
        # Synchronous Popen failure returned no process and cannot have admitted
        # a guest job. Retire the pending attempt while the caller STILL owns
        # the lifecycle lock. Reacquiring later may itself need an unavailable
        # host executable; unlike lost acknowledgment, no backend reconciliation
        # is needed for this confirmed pre-child failure.
        ownership.spawned = False
        _release_locked(ownership)
        raise
    old = {item["id"] for item in previous}
    while time.monotonic() < deadline:
        matches = [item for item in _launch_inventory(command, name, deadline)
                   if item["id"] not in old and item.get("command") == guest]
        if len(matches) > 1:
            raise _refuse("foreground launch acknowledgment is ambiguous")
        if matches:
            item = matches[0]
            if (item.get("version") != 1 or item.get("tty") is not tty
                    or item.get("state") not in ("running", "exited")
                    or not isinstance(item.get("runtime_boot_id"), str)
                    or msb_preparation._BOOT.fullmatch(item["runtime_boot_id"]) is None
                    or item.get("failure") is not None or item.get("error") is not None
                    or item.get("timed_out") is not False):
                raise _refuse("foreground launch acknowledgment is malformed")
            ownership.job, ownership.boot = item["id"], item["runtime_boot_id"]
            _terminal_job(ownership, deadline)  # validate exact foreground job, including terminal fields
            recheck()
            _write_attempt(ownership, "active")
            return
        time.sleep(0.05)
    raise _refuse("foreground launch was not acknowledged before the deadline; cleanup may require quarantine")


def wait_admitted(admitted: LaunchOwnership) -> int:
    """Keep inherited terminal input/output and child status, outside locks."""
    proc = admitted.proc
    if proc is None:
        raise _refuse("foreground launch has no acknowledged process")
    # Normally installed before spawn; standalone test callers may arrive here
    # without it. Do not reset an interrupt observed during acknowledgment.
    if not admitted.interrupt_held:
        hostexec._interrupted = False
        admitted.interrupt_handler = hostexec._hold_interrupt()
        admitted.interrupt_held = admitted.interrupt_handler is not None
    previous = admitted.interrupt_handler
    try:
        code = proc.wait()
        _release_launch(admitted)
        if not admitted.completed:
            message = ("foreground instance was retired; old guest completion remains unconfirmed; replacement untouched"
                       if admitted.retired else "foreground completion is unconfirmed; durable exclusion retained")
            raise _refuse(message)
    finally:
        if previous is not None:
            signal.signal(signal.SIGINT, previous)
            admitted.interrupt_held = False
    if code == -signal.SIGINT and hostexec._interrupted and previous is not None:
        hostexec._die_of_interrupt()
    return hostexec.exit_status(code)
