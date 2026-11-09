"""``create``, ``run``, ``create --recreate``, ``ls``, ``stop``, ``rm``: the sandbox
lifecycle, with the image, kit and substrate resolution those verbs share
(ADR-0040m, ADR-0030).

Create, recreate, rm (and the create-or-reattach step of ``run``) each hold the
per-sandbox lifecycle lock (``lock.sandbox_lock``) for their whole transaction,
so two acq commands never interleave on one sandbox's guest and host records.
"""

from __future__ import annotations

import json
import os
import sys
import time

from .. import envelope, errors, kits, lock, msb, sbx, security, state
from . import common

# Substrate-contract seam (internal test seam, never a secret, never written to
# output). ``ACQ_SUBSTRATE_STATE`` is a JSON object mapping an image to its
# substrate state: ``"ok"`` or a list of gap tokens. A ``"*"`` key applies to any
# overridden image not otherwise named. Absent means unknown -> a kit cannot be
# applied to an unverified image (fail closed). The default devenv base is ``"ok"``
# by construction and never consults the seam.
SUBSTRATE_STATE_ENV = "ACQ_SUBSTRATE_STATE"

# Substrate-contract gap tokens (ADR-0030 "bring-your-own image contract"). A kit
# installs into single-user Nix + devenv + direnv at the pinned /nix store, run by
# the agent user. Addressable gaps are provisioned in-guest; unaddressable gaps
# fail closed.
_ADDRESSABLE_SUBSTRATE_GAPS = frozenset({"nix", "devenv", "direnv", "agent-user"})

_UNADDRESSABLE_SUBSTRATE_GAPS = frozenset({"non-linux", "read-only-filesystem"})


def _resolve_image(flag_image: str | None, agent: str) -> str:
    """Resolve the base image (ADR-0022 precedence).

    ``--image`` flag, then ``ACQ_IMAGE``, then ``ACQ_MSB_IMAGE``, then the
    devenv-shell default for every agent (ADR-0030).
    """
    if flag_image:
        return flag_image
    acq_image = os.environ.get("ACQ_IMAGE")
    if acq_image:
        return acq_image
    msb_image = os.environ.get("ACQ_MSB_IMAGE")
    if msb_image:
        return msb_image
    return common._default_image_for_agent(agent)


def _resolve_image_for_kit(
    image_flag: str | None, agent: str, kit_name: str | None, command: str, emit_json: bool
) -> tuple[str | None, list[tuple[str, list[str]]], int | None]:
    """Resolve the base image and, for a kit, plan the substrate contract (ADR-0030).

    A kit installs into the devenv substrate, so acq verifies the selected image
    against the bring-your-own image contract and provisions addressable gaps
    in-guest rather than rejecting. Returns ``(image, provision_steps, exit_code)``:
    ``provision_steps`` are the substrate bootstrap steps to run before the agent
    install (empty for the default devenv base, which satisfies the contract by
    construction); ``exit_code`` is non-``None`` when the substrate is unverifiable
    or a gap is unaddressable (fail closed).
    """
    image = _resolve_image(image_flag, agent)
    provision, exit_code = _substrate_plan(image, kit_name, command, emit_json)
    if exit_code is not None:
        return None, [], exit_code
    return image, provision, None


def _substrate_gaps(image: str) -> list[str] | None:
    """The substrate gap list for an image (empty == satisfied), or ``None`` (unknown).

    The default devenv base satisfies the contract by construction. An overridden
    image is verified against the deterministic seam; without the seam its state is
    unknown and a kit cannot be applied (fail closed, ADR-0041m).
    """
    if image == common.OPENCODE_DEVENV_IMAGE:
        return []
    raw = os.environ.get(SUBSTRATE_STATE_ENV)
    if raw is None:
        return None
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(doc, dict):
        return None
    entry = doc.get(image)
    if entry is None:
        entry = doc.get("*")
    if entry is None:
        return None
    if entry == "ok":
        return []
    if isinstance(entry, list):
        return [g for g in entry if isinstance(g, str)]
    return None


# Addressable substrate gaps in the order they are provisioned, each with the
# guest user its step runs as. The agent user is created first, as root (it cannot
# run its own ``useradd``), as Bash's ``_acq_msb_ensure_agent_user`` does; the
# single-user Nix, devenv and direnv installs then run as that agent user, whose
# profile the kits install into.
_SUBSTRATE_STEPS: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    ("agent-user", "root", ("useradd", "-m", "agent")),
    ("nix", "agent", ("install-nix", "--single-user")),
    ("devenv", "agent", ("nix", "profile", "install", "devenv")),
    ("direnv", "agent", ("nix", "profile", "install", "direnv")),
)


def _substrate_provision_steps(gaps: list[str]) -> list[tuple[str, list[str]]]:
    """In-guest bootstrap steps for addressable substrate gaps, as ``(user, argv)``.

    The order is fixed by :data:`_SUBSTRATE_STEPS` (agent user first), whatever
    order the gaps were reported in.

    TODO(quarterly): these argv are PLACEHOLDER bootstrap steps — the quarterly
    cadence re-sources the pinned single-user Nix / devenv install from the control
    plane. They are data, never executed here (forwarded to the backend seam), and
    carry no credential.
    """
    wanted = set(gaps)
    return [(user, list(argv)) for gap, user, argv in _SUBSTRATE_STEPS if gap in wanted]


def _substrate_plan(
    image: str, kit_name: str | None, command: str, emit_json: bool
) -> tuple[list[tuple[str, list[str]]], int | None]:
    """Plan the substrate contract for a kit on an image; returns ``(steps, exit_code)``.

    A ``None`` kit needs no substrate. Otherwise the image's gaps are classified:
    unknown or unaddressable gaps fail closed; addressable gaps yield bootstrap
    steps to run in-guest (the default devenv base has none).
    """
    if kit_name is None:
        return [], None
    gaps = _substrate_gaps(image)
    if gaps is None:
        return [], common._operational_failure(
            command,
            errors.VALIDATION_FAILED,
            f"cannot verify the substrate contract for image {image!r}; kit '{kit_name}' needs single-user Nix + devenv + direnv",
            "use the default devenv base, or verify the image satisfies the substrate contract (ADR-0030)",
            emit_json,
        )
    unaddressable = [g for g in gaps if g in _UNADDRESSABLE_SUBSTRATE_GAPS]
    if unaddressable:
        return [], common._operational_failure(
            command,
            errors.VALIDATION_FAILED,
            f"image {image!r} does not satisfy the substrate contract (unaddressable: {', '.join(unaddressable)})",
            "use a Linux image that permits in-guest provisioning, or the default devenv base",
            emit_json,
        )
    addressable = [g for g in gaps if g in _ADDRESSABLE_SUBSTRATE_GAPS]
    return _substrate_provision_steps(addressable), None


def _validate_kit_flag(kit_flag: str | None, command: str, emit_json: bool) -> tuple[str | None, int | None]:
    """Validate an explicit ``--kit``; returns ``(kit_name, exit_code)``.

    An explicit ``--kit`` must name a built-in agent kit (ADR-0030 "Agent kit
    inference"): an unknown name is a usage error (exit 2), and team/personal kit
    sources are never resolved here.
    """
    if kit_flag is None:
        return None, None
    if not kits.is_agent_kit(kit_flag):
        return None, common._usage_failure(
            command,
            f"unknown kit: {kit_flag!r} (built-in agent kits: {', '.join(kits.AGENT_KIT_NAMES)})",
            emit_json,
        )
    return kit_flag, None


def _apply_agent_kit(
    backend: str, name: str, kit_name: str, provision_steps: list[tuple[str, list[str]]], command: str, emit_json: bool
) -> int | None:
    """Apply a built-in agent kit to a sandbox (create-time install, ADR-0030).

    Idempotent and host-authoritative: a sandbox already on ``kit_name`` is a
    no-op (no duplicate install), tracked by the applied-kit record (ADR-0041m).
    Addressable substrate gaps are provisioned in-guest (bootstrap single-user Nix
    + devenv + direnv + the agent user) before the agent install. acq never
    executes kit code on the host, and the install argv carries no credential
    (ADR-0038m §46, §7). Returns an emitted exit code on failure, else ``None``.
    """
    if not common._supports(backend, "kit-apply"):
        return common._operational_failure(
            command,
            errors.UNSUPPORTED,
            f"kit apply is not supported on the {backend} backend",
            "the agent kit requires kit-apply; use a backend that supports it (msb in this slice)",
            emit_json,
        )
    existing = kits.kit_applied_read(backend, name)
    if existing and existing.get("kit") == kit_name:
        return None  # already applied: idempotent no-op
    try:
        if provision_steps:
            common._adapter(backend).provision_substrate(name, provision_steps)
        common._adapter(backend).kit_apply(name, kit_name, kits.agent_kit_install(kit_name))
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    try:
        kits.kit_applied_write(backend, name, kit_name, kits.agent_kit_entrypoint(kit_name))
    except OSError as exc:
        # The kit is installed but acq could not record it. Report it through the
        # error contract; the caller discards the half-created sandbox.
        return common._operational_failure(
            command,
            errors.FAILURE,
            f"could not record the applied kit for sandbox '{name}': {exc.strerror or exc}",
            "check that the acq state directory is writable and has free space, then retry",
            emit_json,
        )
    return None


def _discard_half_created(backend: str, name: str) -> None:
    """Remove a just-created sandbox (and its host records) after a failed kit apply.

    Mirrors the exec-ready timeout cleanup in ``_create_sandbox``: a sandbox
    created but left without its agent binary must not strand.
    """
    _remove_quietly(common._adapter(backend), name)
    _clear_host_records(backend, name)


def _discard_recreated_guest(backend: str, name: str) -> None:
    """Remove a recreated guest whose kit apply failed, keeping its state record.

    Recreation promises that host records survive: the state record (agent,
    workspace, image, ``ro_host_config``) is the authority a retried
    ``create --recreate`` rebuilds from, so only the guest and the applied-kit
    record (which no longer describes any guest) go.
    """
    _remove_quietly(common._adapter(backend), name)
    kits.kit_applied_remove(backend, name)


def _clear_host_records(backend: str, name: str) -> None:
    """Drop every per-sandbox host record: the state record and the applied-kit record.

    A leftover applied-kit record would make the next create of the same name
    skip the agent install, so the two always go together.
    """
    state.record_remove(backend, name)
    kits.kit_applied_remove(backend, name)


def _has_host_records(backend: str, name: str) -> bool:
    """True when any per-sandbox host record exists, readable or not."""
    return state.record_path(backend, name).exists() or kits.kit_applied_present(backend, name)


def _lock_failure(command: str, name: str, exc: lock.SandboxLockTimeout, emit_json: bool) -> int:
    """Report that another acq command holds the sandbox's lifecycle lock."""
    return common._operational_failure(
        command,
        errors.TIMEOUT,
        str(exc),
        exc.remediation or f"wait for the other acq command on sandbox '{name}' to finish, then retry",
        emit_json,
    )


def _reattach_workspace(
    backend: str, name: str, typed: str, emit_json: bool
) -> tuple[str | None, int | None]:
    """Gate a typed-path re-attach and pick its workspace.

    The same host-authoritative checks as run-by-name apply: an unreadable or
    newer-schema record fails closed, and a sandbox whose recorded read-only
    trusted-config mount is missing or unconfirmed is refused (ADR-0035,
    ADR-0041m). The launch directory is the recorded workspace, not the path typed
    this time, because an older build may have recorded a different form (e.g. a
    symlink path). An absent record falls back to the typed path.
    """
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return None, common._operational_failure(
            "run",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    gate = common._trusted_gate(record, backend, "run", name, emit_json)
    if gate is not None:
        return None, gate
    return (record or {}).get("workspace") or typed, None


def _wait_exec_ready(backend: str, name: str) -> bool:
    adapter = common._adapter(backend)
    deadline = time.monotonic() + adapter.ready_timeout_s()
    while True:
        if adapter.exec_ready(name):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)


def _create_sandbox(
    backend: str,
    agent: str,
    workspace: str,
    name: str,
    image: str,
    kit_name: str | None,
    *,
    ro_host_config: bool | None = None,
) -> dict:
    """Create + exec-ready gate + record write; returns the result record data.

    On msb the egress policy is derived from the built-in kits plus ``kit_name``
    (the agent kit about to be applied, if any); see ``msb.egress_flags``.
    """
    adapter = common._adapter(backend)
    error_cls = sbx.SbxError if backend == "sbx" else msb.MsbError
    if backend == "sbx":
        adapter.create(name, image, workspace, agent=agent)
    else:
        adapter.create(
            name,
            image,
            workspace,
            memory=msb.DEFAULT_MEMORY,
            cpus=msb.DEFAULT_CPUS,
            egress_kits=kits.egress_kit_names(kit_name),
        )
    if not _wait_exec_ready(backend, name):
        # A half-created sandbox must not strand (legacy cleanup).
        _remove_quietly(adapter, name)
        raise error_cls(
            errors.TIMEOUT,
            f"sandbox '{name}' did not become exec-ready",
            f"check {backend} logs, then remove the half-created sandbox and retry",
        )
    # The guest is brand new, so no kit is installed in it. An applied-kit record
    # left by a sandbox of the same name that was removed outside acq would
    # otherwise make the kit apply a no-op on a guest without the agent.
    kits.kit_applied_remove(backend, name)
    try:
        state.record_write(backend, name, agent=agent, workspace=workspace, image=image, ro_host_config=ro_host_config)
    except OSError as exc:
        # Without its host record the guest is unusable (run/attach refuse a
        # sandbox with no readable record), so it must not strand either. The
        # failure is raised as the adapter's error so every caller reports it
        # through the same envelope path as a backend failure.
        _remove_quietly(adapter, name)
        raise error_cls(
            errors.FAILURE,
            f"could not write the host state record for sandbox '{name}': {exc.strerror or exc}",
            "check that the acq state directory is writable and has free space, then retry",
        ) from exc
    return {
        "name": name,
        "backend": backend,
        "agent": agent,
        "workspace": workspace,
        "state": "running",
        "image": image,
    }


def _remove_quietly(adapter, name: str) -> None:
    """Best-effort removal of a sandbox acq just created and cannot keep."""
    try:
        adapter.remove(name)
    except common._ADAPTER_ERRORS:
        pass


def _print_create_human(data: dict) -> None:
    line = (
        f"sandbox '{data['name']}' created (backend {data['backend']}, "
        f"agent {data['agent']}, workspace {data['workspace']})"
    )
    if data.get("kit"):
        line += f"; applied kit '{data['kit']}' (entrypoint {data['entrypoint']})"
    print(line)


def run_create(parsed, emit_json: bool, backend: str) -> int:
    if parsed.recreate is not None:
        return run_recreate(parsed, emit_json, backend)
    if not parsed.agent or parsed.agent not in common.KNOWN_AGENTS:
        return common._usage_failure(
            "create",
            f"unknown agent: {parsed.agent!r} (expected one of: {', '.join(sorted(common.KNOWN_AGENTS))})",
            emit_json,
        )
    workspace, exit_code = common._validate_workspace("create", parsed.path, emit_json)
    if exit_code is not None:
        return exit_code
    assert workspace is not None  # nosec B101 # resolver contract; narrows the type for mypy
    kit_name, exit_code = _validate_kit_flag(parsed.kit, "create", emit_json)
    if exit_code is not None:
        return exit_code
    if kit_name is None:
        kit_name = kits.agent_kit_for(parsed.agent)  # implicit inference (built-in only)
    name = parsed.name or common._derive_name(parsed.agent, workspace)
    workspace = common._mount_workspace(backend, workspace)
    try:
        with lock.sandbox_lock(backend, name):
            return _create_locked(parsed, emit_json, backend, name, workspace, kit_name)
    except lock.SandboxLockTimeout as exc:
        return _lock_failure("create", name, exc, emit_json)


def _create_locked(parsed, emit_json: bool, backend: str, name: str, workspace: str, kit_name: str | None) -> int:
    """The body of ``create`` once the sandbox's lifecycle lock is held."""
    adapter = common._adapter(backend)
    if adapter.exists(name):
        return common._operational_failure(
            "create",
            errors.SANDBOX_EXISTS,
            f"sandbox '{name}' already exists",
            f"re-attach with 'acq run {name}', or remove it with 'acq rm {name}'",
            emit_json,
        )
    # Fail closed BEFORE create when the agent needs a kit the backend can't apply
    # (never strand a half-provisioned sandbox missing its agent binary). SBX
    # declares kit-apply unsupported in this slice: it will instead use a neutral
    # shell launcher token (ADR-0030 "on both backends" rollout) once kit-apply
    # lands there — reconcile later.
    if kit_name is not None and not common._supports(backend, "kit-apply"):
        return common._operational_failure(
            "create",
            errors.UNSUPPORTED,
            f"agent '{parsed.agent}' requires the '{kit_name}' kit, which the {backend} backend cannot apply",
            "use a backend that supports kit-apply (msb in this slice), or choose an agent without a kit",
            emit_json,
        )
    image, provision_steps, exit_code = _resolve_image_for_kit(parsed.image, parsed.agent, kit_name, "create", emit_json)
    if exit_code is not None:
        return exit_code
    assert image is not None  # nosec B101 # resolver contract; narrows the type for mypy
    try:
        data = _create_sandbox(backend, parsed.agent, workspace, name, image, kit_name)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("create", exc.code, exc.message, exc.remediation, emit_json)
    entrypoint = None
    if kit_name is not None:
        gate = _apply_agent_kit(backend, name, kit_name, provision_steps, "create", emit_json)
        if gate is not None:
            _discard_half_created(backend, name)
            return gate
        entrypoint = kits.agent_kit_entrypoint(kit_name)
    data["kit"] = kit_name
    data["entrypoint"] = entrypoint
    if emit_json:
        print(json.dumps(envelope.success("create", data)))
    else:
        _print_create_human(data)
    return errors.EXIT_SUCCESS


def _recreate_ineligible(record: dict, backend: str, name: str, emit_json: bool) -> int | None:
    """Refuse recreation of a sandbox that is not in the security exception.

    Returns an emitted exit code when the sandbox passes the trusted-config gate
    (nothing to recover), else ``None`` (recreation is the sanctioned recovery).
    """
    try:
        security.assert_trusted(record, backend, name)
    except security.SecurityException:
        return None
    return common._operational_failure(
        "create",
        errors.VALIDATION_FAILED,
        f"sandbox '{name}' is not missing its read-only mount; recreation is "
        "only for the security exception",
        f"re-attach with 'acq run {name}' instead",
        emit_json,
    )


def run_recreate(parsed, emit_json: bool, backend: str) -> int:
    """``acq create --recreate NAME [--yes]`` — security-exception recreation.

    Recreates a sandbox that is missing the host-enforced read-only trusted-config
    mount (ADR-0035, ADR-0041m). It is explicit and consent-gated: a non-interactive
    run without ``--yes`` refuses with ``consent_required`` (automation never infers
    consent). Host-held records (agent/workspace/image/ro_host_config) and secrets
    are preserved; only the guest filesystem is lost. Recreation is refused for a
    sandbox that is NOT in the security exception — it is never a general "reset".
    """
    name = parsed.recreate
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return common._operational_failure(
            "create",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"remove the unreadable record for '{name}', or recreate it out of band",
            emit_json,
        )
    if record is None:
        return common._operational_failure(
            "create",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' has no host state record to recreate",
            "create it with 'acq create', or list sandboxes with 'acq ls'",
            emit_json,
        )
    exit_code = _recreate_ineligible(record, backend, name, emit_json)
    if exit_code is not None:
        return exit_code
    if not parsed.yes:
        if emit_json or not sys.stdin.isatty():
            return common._operational_failure(
                "create",
                errors.CONSENT_REQUIRED,
                f"refusing to recreate '{name}' non-interactively without --yes",
                f"re-run with 'acq create --recreate {name} --yes' to consent",
                emit_json,
            )
        answer = input(
            f"recreate sandbox '{name}' (guest filesystem is lost; host records "
            "and secrets are preserved)? [y/N] "
        )
        if answer.strip().lower() not in ("y", "yes"):
            if emit_json:
                print(json.dumps(envelope.success("create", {"name": name, "backend": backend, "recreated": False})))
            else:
                print("cancelled.")
            return errors.EXIT_SUCCESS
    try:
        with lock.sandbox_lock(backend, name):
            return _recreate_locked(name, emit_json, backend)
    except lock.SandboxLockTimeout as exc:
        return _lock_failure("create", name, exc, emit_json)


def _recreate_locked(name: str, emit_json: bool, backend: str) -> int:
    """The body of ``create --recreate`` once the lifecycle lock is held.

    The record is read again under the lock: another command may have removed
    the sandbox while the consent prompt was open.
    """
    adapter = common._adapter(backend)
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return common._operational_failure(
            "create",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"remove the unreadable record for '{name}', or recreate it out of band",
            emit_json,
        )
    if record is None:
        return common._operational_failure(
            "create",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' has no host state record to recreate",
            "create it with 'acq create', or list sandboxes with 'acq ls'",
            emit_json,
        )
    # Eligibility again, under the lock: a concurrent recreate may have rebuilt
    # the sandbox while this one waited, and its guest must not be destroyed.
    exit_code = _recreate_ineligible(record, backend, name, emit_json)
    if exit_code is not None:
        return exit_code
    agent = record.get("agent") or "shell"
    workspace = record.get("workspace") or common.DEFAULT_GUEST_WORKSPACE
    if record.get("workspace"):
        # Records written before msb workspaces were canonicalized hold the symlink form.
        workspace = common._mount_workspace(backend, workspace)
    image = record.get("image") or common._default_image_for_agent(agent)
    ro_host_config = bool(record.get("ro_host_config"))
    # Fail closed BEFORE recreation when the recorded agent needs a kit the
    # backend can't apply: a legacy sbx opencode sandbox must not be recreated
    # and then discarded because kit-apply is unsupported there (ADR-0040m).
    kit_name = kits.agent_kit_for(agent)
    if kit_name is not None and not common._supports(backend, "kit-apply"):
        return common._operational_failure(
            "create",
            errors.UNSUPPORTED,
            f"agent '{agent}' requires the '{kit_name}' kit, which the {backend} backend cannot apply",
            "use a backend that supports kit-apply (msb in this slice) to recreate this sandbox",
            emit_json,
        )
    # Verify the recorded image's substrate contract before recreating: a kit on an
    # unverifiable or unaddressable image fails closed, an addressable gap is
    # provisioned in-guest after recreation.
    provision_steps, exit_code = _substrate_plan(image, kit_name, "create", emit_json)
    if exit_code is not None:
        return exit_code
    try:
        # Compute the msb egress policy BEFORE removing the old guest: a policy
        # that cannot be computed must refuse with the existing sandbox intact.
        if backend == "msb":
            msb.egress_flags(kits.egress_kit_names(kit_name))
        # Preserve host records + secrets; lose only the guest filesystem. If the
        # guest is already gone (removed out of band) there is nothing to destroy:
        # recreate from host authority either way.
        if adapter.exists(name):
            adapter.remove(name)
        data = _create_sandbox(backend, agent, workspace, name, image, kit_name, ro_host_config=ro_host_config)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("create", exc.code, exc.message, exc.remediation, emit_json)
    # The guest filesystem was destroyed, so a prior applied-kit record no longer
    # describes the fresh guest (``_create_sandbox`` cleared it): re-apply the
    # agent kit (if any) so the recreated sandbox has its agent binary (ADR-0030
    # create-time install). On failure the state record stays, so the recreate
    # can be retried.
    entrypoint = None
    if kit_name is not None:
        gate = _apply_agent_kit(backend, name, kit_name, provision_steps, "create", emit_json)
        if gate is not None:
            _discard_recreated_guest(backend, name)
            return gate
        entrypoint = kits.agent_kit_entrypoint(kit_name)
    data["kit"] = kit_name
    data["entrypoint"] = entrypoint
    data = {**data, "recreated": True}
    if emit_json:
        print(json.dumps(envelope.success("create", data)))
    else:
        print(f"recreated sandbox '{name}' (host records and secrets preserved).")
    return errors.EXIT_SUCCESS


def _run_prepare_locked(
    parsed, emit_json: bool, backend: str, target: str, name: str, workspace: str, kit_name: str | None
) -> tuple[dict | None, int | None]:
    """Create-or-reattach for ``run AGENT PATH`` with the lifecycle lock held.

    Returns ``(data, None)`` with the result data (whose ``workspace`` and
    ``entrypoint`` drive the launch), or ``(None, exit_code)`` once a failure has
    been reported. The launch itself happens after the lock is released: an
    interactive session must not block other commands on the sandbox.
    """
    adapter = common._adapter(backend)
    action = "reattached" if adapter.exists(name) else "created"
    if action == "reattached":
        recorded, exit_code = _reattach_workspace(backend, name, workspace, emit_json)
        if exit_code is not None:
            return None, exit_code
        workspace = recorded or workspace
    image: str | None = None
    entrypoint: str | None = None
    if not adapter.exists(name):
        if kit_name is None:
            kit_name = kits.agent_kit_for(target)  # implicit inference (built-in only)
        if kit_name is not None and not common._supports(backend, "kit-apply"):
            return None, common._operational_failure(
                "run",
                errors.UNSUPPORTED,
                f"agent '{target}' requires the '{kit_name}' kit, which the {backend} backend cannot apply",
                "use a backend that supports kit-apply (msb in this slice), or choose an agent without a kit",
                emit_json,
            )
        image, provision_steps, exit_code = _resolve_image_for_kit(parsed.image, target, kit_name, "run", emit_json)
        if exit_code is not None:
            return None, exit_code
        assert image is not None  # nosec B101 # resolver contract; narrows the type for mypy
        try:
            _create_sandbox(backend, target, workspace, name, image, kit_name)
        except common._ADAPTER_ERRORS as exc:
            return None, common._operational_failure("run", exc.code, exc.message, exc.remediation, emit_json)
        if kit_name is not None:
            gate = _apply_agent_kit(backend, name, kit_name, provision_steps, "run", emit_json)
            if gate is not None:
                _discard_half_created(backend, name)
                return None, gate
            entrypoint = kits.agent_kit_entrypoint(kit_name)
    else:
        # Re-attach: the kit (if any) was applied at create time; read the
        # recorded kit/entrypoint (lenient) so the launch surfaces provenance.
        applied = kits.kit_applied_read(backend, name)
        if applied:
            kit_name = applied.get("kit")
            entrypoint = applied.get("entrypoint")
    data: dict = {
        "name": name,
        "backend": backend,
        "agent": target,
        "workspace": workspace,
        "state": "running",
        "action": action,
    }
    if action == "created":
        data["image"] = image
    data["kit"] = kit_name
    data["entrypoint"] = entrypoint
    return data, None


def run_run(parsed, emit_json: bool, backend: str) -> int:
    """Create (if missing) then launch, or re-attach an existing sandbox by name.

    In ``--json`` mode the create/attach result is emitted as one JSON envelope on
    stdout, and the launched child's own output is routed to stderr so stdout
    stays a single document (ADR-0038m §2). In interactive use the child inherits
    stdio. The child's exit status is ``run``'s exit status (ADR-0038m §1).
    """
    adapter = common._adapter(backend)
    target = parsed.target
    if target in common.KNOWN_AGENTS:
        workspace, exit_code = common._validate_workspace("run", parsed.path, emit_json)
        if exit_code is not None:
            return exit_code
        assert workspace is not None  # nosec B101 # resolver contract; narrows the type for mypy
        kit_name, exit_code = _validate_kit_flag(parsed.kit, "run", emit_json)
        if exit_code is not None:
            return exit_code
        name = parsed.name or common._derive_name(target, workspace)
        workspace = common._mount_workspace(backend, workspace)
        try:
            with lock.sandbox_lock(backend, name):
                data, exit_code = _run_prepare_locked(parsed, emit_json, backend, target, name, workspace, kit_name)
        except lock.SandboxLockTimeout as exc:
            return _lock_failure("run", name, exc, emit_json)
        if data is None:
            return exit_code if exit_code is not None else errors.EXIT_FAILURE
        if emit_json:
            print(json.dumps(envelope.success("run", data)))
        # Launch in the foreground; the child's status is `run`'s exit status. In
        # --json mode the child's stdout is routed to stderr so stdout stays one
        # JSON document. A recorded kit entrypoint wins over the agent token.
        return _launch_after_envelope(backend, name, data["workspace"], data["entrypoint"] or target, emit_json)

    # Not a known agent: re-attach to an existing sandbox by name, else fail
    # closed as ambiguous (a token that is neither agent nor sandbox is a usage
    # error, matching the legacy dispatch).
    if not adapter.exists(target):
        return common._usage_failure(
            "run",
            f"'{target}' is not a known agent or an existing sandbox",
            emit_json,
        )
    # Re-attach by sandbox name (host-authoritative record supplies agent/workspace).
    # A sandbox whose host record is absent or unreadable must fail closed, never
    # launch a bare `/bin/sh -l` without a workspace.
    try:
        record = state.record_read(backend, target)
    except state.StateSchemaError as exc:
        return common._operational_failure(
            "run",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {target}'",
            emit_json,
        )
    if record is None:
        return common._operational_failure(
            "run",
            errors.VALIDATION_FAILED,
            f"sandbox '{target}' has no readable host state record; cannot determine the agent to launch",
            f"create it with 'acq create', or remove it with 'acq rm {target}'",
            emit_json,
        )
    gate = common._trusted_gate(record, backend, "run", target, emit_json)
    if gate is not None:
        return gate
    agent = record.get("agent")
    workspace = record.get("workspace")
    if emit_json:
        print(
            json.dumps(
                envelope.success(
                    "run",
                    {"name": target, "backend": backend, "agent": agent, "workspace": workspace, "state": "running", "action": "reattached"},
                )
            )
        )
    return _launch_after_envelope(backend, target, workspace, common._launch_token(backend, target, agent), emit_json)


def _launch_after_envelope(backend: str, name: str, workspace: str | None, token: str | None, emit_json: bool) -> int:
    """Launch for ``run`` once its success envelope may already be on stdout.

    Under ``--json`` stdout must carry exactly one document, and ``run`` has
    already printed it before the foreground launch. A launch that cannot start
    (e.g. the backend CLI vanished) is therefore reported on stderr only, with
    exit 1, instead of reaching the command boundary, which would print a second
    document.
    """
    try:
        return common._adapter(backend).launch(name, workspace, token, json_mode=emit_json)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("run", exc.code, exc.message, exc.remediation, False)


def _ls_data(backend: str) -> dict:
    adapter = common._adapter(backend)
    names = adapter.list_names() or []
    running = set(adapter.running_names() or [])
    records = {record["name"]: record for record in state.list_records(backend)}
    sandboxes: list[dict] = []
    for name in names:
        entry: dict = {"name": name, "backend": backend, "state": "running" if name in running else "stopped"}
        record = records.get(name)
        if record:
            if record.get("agent"):
                entry["agent"] = record["agent"]
            if record.get("workspace"):
                entry["workspace"] = record["workspace"]
        sandboxes.append(entry)
    # A host record whose sandbox is gone (removed out-of-band) reads as unknown.
    for record in records.values():
        if record["name"] not in names:
            entry = {"name": record["name"], "backend": backend, "state": "unknown"}
            if record.get("agent"):
                entry["agent"] = record["agent"]
            if record.get("workspace"):
                entry["workspace"] = record["workspace"]
            sandboxes.append(entry)
    sandboxes.sort(key=lambda entry: entry["name"])
    return {"sandboxes": sandboxes}


def _print_ls_human(data: dict) -> None:
    sandboxes = data["sandboxes"]
    if not sandboxes:
        print("no sandboxes")
        return
    for entry in sandboxes:
        extra = f"  ({entry['agent']})" if entry.get("agent") else ""
        print(f"  {entry['name']}  {entry['backend']}  {entry['state']}{extra}")


def run_ls(emit_json: bool, backend: str) -> int:
    try:
        data = _ls_data(backend)
    except common._ADAPTER_ERRORS as exc:
        # e.g. the backend CLI was removed after detection, or detection was
        # forced: report backend_not_found through the envelope, not a traceback.
        return common._operational_failure("ls", exc.code, exc.message, exc.remediation, emit_json)
    if emit_json:
        print(json.dumps(envelope.success("ls", data)))
    else:
        _print_ls_human(data)
    return errors.EXIT_SUCCESS


def run_stop(parsed, emit_json: bool, backend: str) -> int:
    adapter = common._adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return common._operational_failure(
            "stop",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            "list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    try:
        adapter.stop(name)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("stop", exc.code, exc.message, exc.remediation, emit_json)
    data = {"name": name, "backend": backend, "state": "stopped"}
    if emit_json:
        print(json.dumps(envelope.success("stop", data)))
    else:
        print(f"stopped sandbox '{name}'")
    return errors.EXIT_SUCCESS


def run_rm(parsed, emit_json: bool, backend: str) -> int:
    """``acq rm NAME``: remove a sandbox and every host record acq keeps for it.

    Holds the sandbox's lifecycle lock so a concurrent create cannot write
    records for a guest this removal is tearing down.
    """
    name = parsed.name
    try:
        with lock.sandbox_lock(backend, name):
            return _rm_locked(name, emit_json, backend)
    except lock.SandboxLockTimeout as exc:
        return _lock_failure("rm", name, exc, emit_json)


def _confirmed_absent(adapter, name: str) -> bool | None:
    """Whether a successful listing shows the sandbox gone.

    ``True`` only on positive proof: the backend listed its sandboxes and the
    name is not among them. ``False`` when it is listed. ``None`` when the
    listing failed, which proves nothing either way.
    """
    try:
        names = adapter.list_names()
    except common._ADAPTER_ERRORS:
        return None
    if names is None:
        return None
    return name not in names


def _rm_locked(name: str, emit_json: bool, backend: str) -> int:
    """The body of ``rm`` once the lifecycle lock is held.

    Mirrors Bash's ``_acq_backend_terminate_unlocked``: the backend remove is
    always attempted first. Host records are cleared only once the guest is known
    to be gone, either because the remove succeeded or because, after a failed
    remove, a successful listing no longer shows it. A sandbox removed outside acq
    is reported with ``backend_absent: true``. When the listing itself fails the
    outcome is unknown, so ``rm`` fails and leaves every record in place. Only
    when the guest is confirmed absent and there is no host record either is the
    name unknown (``sandbox_not_found``).
    """
    adapter = common._adapter(backend)
    backend_absent = False
    try:
        adapter.remove(name)
    except common._ADAPTER_ERRORS as exc:
        absent = _confirmed_absent(adapter, name)
        if absent is None:
            return common._operational_failure(
                "rm",
                exc.code,
                f"could not remove sandbox '{name}', and could not confirm it is gone "
                f"because listing {backend} sandboxes failed; its host records were kept",
                f"check that the {backend} backend is working, then retry 'acq rm {name}'",
                emit_json,
            )
        if not absent:
            return common._operational_failure("rm", exc.code, exc.message, exc.remediation, emit_json)
        if not _has_host_records(backend, name):
            return common._operational_failure(
                "rm",
                errors.SANDBOX_NOT_FOUND,
                f"sandbox '{name}' not found",
                "list sandboxes with 'acq ls'",
                emit_json,
            )
        backend_absent = True
    _clear_host_records(backend, name)
    data: dict = {"name": name, "backend": backend, "removed": True}
    if backend_absent:
        data["backend_absent"] = True
    if emit_json:
        print(json.dumps(envelope.success("rm", data)))
    elif backend_absent:
        print(f"removed the host records for sandbox '{name}' (the sandbox itself was already gone)")
    else:
        print(f"removed sandbox '{name}'")
    return errors.EXIT_SUCCESS
