"""``create``, ``run``, ``create --recreate``, ``ls``, ``stop``, ``start``, ``restart``,
``rm``: the sandbox lifecycle, with the image, kit and substrate resolution those
verbs share (ADR-0040m, ADR-0030).

Create, recreate, rm, start, restart (and the create-or-reattach step of ``run``) each hold the
per-sandbox lifecycle lock (``lock.sandbox_lock``) for their whole transaction,
so two acq commands never interleave on one sandbox's guest and host records.
"""

from __future__ import annotations

import json
import os
import shlex
import sys
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass

from .. import (
    envelope,
    errors,
    kit_msb,
    kit_sbx,
    kits,
    kitspec,
    lock,
    msb,
    provider_input,
    sbx,
    secretstore,
    security,
    state,
)
from . import common, session

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


def _cli_kit_refs(values: list[str] | None) -> list[str]:
    """``--kit`` values as kit refs (Bash: repeatable, each an extra kit ref).

    A built-in agent kit name (``opencode``) stands for the pinned ref of that
    bundled kit, so ``--kit opencode`` still applies the agent kit. Any other
    value is a ref; one the bundle does not hold is refused before create
    (:func:`kit_msb.resolve`).
    """
    out = []
    for value in values or []:
        entry = kitspec.AGENT_BUNDLE_KITS.get(value)
        out.append(kitspec.builtin_kit_ref(entry[0]) if entry else value)
    return out


@dataclass(frozen=True)
class _KitPlan:
    """The kits a create applies, and which of them provides the agent (if any).

    ``selection`` is the kit selection they came from (the sbx heal records use it).
    """

    kits: list[kit_msb.Kit]
    agent_kit: str | None
    selection: kitspec.KitSelection | None = None

    @property
    def entrypoint(self) -> str | None:
        for kit in self.kits:
            if kit.name == self.agent_kit:
                return kit.spec.agent_field("entrypoint")
        return None


def _plan_msb_kits(
    agent: str, cli_kits: list[str], image: str, command: str, emit_json: bool, extras: list[str] | None = None
) -> tuple[_KitPlan | None, int | None]:
    """Select, verify and parse the kit set for an msb create (:func:`kit_msb.select`).

    Only a kit chosen as the agent kit or passed with ``--kit`` can provide the
    agent: an extra kit is never inferred as one (ADR-0030).
    """
    try:
        resolved = kit_msb.select(agent, cli_kits, image_is_default=image == common.OPENCODE_DEVENV_IMAGE,
                                  extras=extras)
    except kitspec.KitSelectionError as exc:
        return None, common._operational_failure(
            command, errors.VALIDATION_FAILED, str(exc),
            "fix the kit selection (config extra_kits or provider_kit, ACQ_EXTRA_KITS, ACQ_PROVIDER_KITS, --kit)",
            emit_json,
        )
    except msb.MsbError as exc:
        return None, common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    agent_kit = next(
        (k.name for k in resolved if k.role in ("agent", "cli") and k.name in kitspec.AGENT_BUNDLE_KITS), None
    )
    return _KitPlan(resolved, agent_kit), None


def _apply_msb_kits(
    name: str, plan: _KitPlan, provision_steps: list[tuple[str, list[str]]], command: str, emit_json: bool,
    *, ro_required: bool,
) -> tuple[kit_msb.ApplyResult | None, int | None]:
    """Provision substrate gaps, then apply the whole kit set to a new guest (ADR-0030).

    A kit that does not apply in full is a warning, as in Bash, unless it is the
    agent kit: without it the default image has no agent, so the create fails.
    Provenance is recorded only when every kit applied (ADR-0038m §3).
    """
    try:
        if provision_steps:
            msb.provision_substrate(name, provision_steps)
    except msb.MsbError as exc:
        return None, common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    result = kit_msb.ensure_kits_applied(name, plan.kits, ro_required=ro_required)
    if plan.agent_kit in result.incomplete:
        return None, common._operational_failure(
            command, errors.FAILURE, f"could not apply kit '{plan.agent_kit}' to sandbox '{name}'",
            "check network access from the sandbox and the warnings above, then retry", emit_json,
        )
    try:
        kit_msb.cli_kits_write(name, plan.kits)
        if plan.agent_kit is not None:
            kits.kit_applied_write("msb", name, plan.agent_kit, plan.entrypoint or plan.agent_kit)
        if not result.incomplete:
            kits.provenance_write("msb", name)
    except OSError as exc:
        return None, common._operational_failure(
            command, errors.FAILURE,
            f"could not record the applied kit for sandbox '{name}': {exc.strerror or exc}",
            "check that the acq state directory is writable and has free space, then retry", emit_json,
        )
    return result, None


def _kit_data(plan: _KitPlan, result: kit_msb.ApplyResult) -> dict:
    data: dict = {"kit": plan.agent_kit, "entrypoint": plan.entrypoint, "kits": result.applied}
    if result.incomplete:
        data["kits_incomplete"] = result.incomplete
    return data


def _new_msb_sandbox(
    command: str, emit_json: bool, *, agent: str, workspace: str, name: str, image_flag: str | None,
    cli_kits: list[str],
) -> tuple[dict | None, int | None]:
    """Plan the kits, create the guest, apply the kits; the result data or an emitted exit code."""
    image = _resolve_image(image_flag, agent)
    plan, exit_code = _plan_msb_kits(agent, cli_kits, image, command, emit_json)
    if plan is None:
        return None, exit_code
    steps, exit_code = _substrate_plan(image, plan.agent_kit, command, emit_json)
    if exit_code is not None:
        return None, exit_code
    try:
        data = _create_sandbox("msb", agent, workspace, name, image, plan.agent_kit, plan=plan)
    except common._ADAPTER_ERRORS as exc:
        return None, common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    result, exit_code = _apply_msb_kits(name, plan, steps, command, emit_json, ro_required=data["ro_host_config"])
    if result is None:
        _discard_half_created("msb", name)
        return None, exit_code
    return {**data, **_kit_data(plan, result)}, None


def _plan_sbx_kits(
    agent: str, cli_kits: list[str], image: str, command: str, emit_json: bool
) -> tuple[_KitPlan | None, int | None]:
    """Select, verify and parse the kit set for an sbx create (:func:`kit_sbx.select`)."""
    try:
        resolved, selection = kit_sbx.select(agent, cli_kits, image_is_default=image == common.OPENCODE_DEVENV_IMAGE)
    except kitspec.KitSelectionError as exc:
        return None, common._operational_failure(
            command, errors.VALIDATION_FAILED, str(exc),
            "fix the kit selection (config extra_kits or provider_kit, ACQ_EXTRA_KITS, ACQ_PROVIDER_KITS, --kit)",
            emit_json,
        )
    except sbx.SbxError as exc:
        return None, common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    agent_kit = next(
        (k.name for k in resolved if k.role in ("agent", "cli") and k.name in kitspec.AGENT_BUNDLE_KITS), None
    )
    return _KitPlan(resolved, agent_kit, selection), None


def _new_sbx_sandbox(
    command: str, emit_json: bool, *, agent: str, workspace: str, name: str, image_flag: str | None,
    cli_kits: list[str],
) -> tuple[dict | None, int | None]:
    """Translate the kits, create the sandbox with them, then wait for kit startup (Bash sbx provision).

    sbx applies the kits itself (``sbx create --kit DIR``). On the default image
    OpenCode comes from the pinned kit, so sbx is given the ``shell`` agent and
    does not add its own OpenCode kit as well.
    """
    image = _resolve_image(image_flag, agent)
    plan, exit_code = _plan_sbx_kits(agent, cli_kits, image, command, emit_json)
    if plan is None:
        return None, exit_code
    facts, exit_code = _sbx_provider_gate(command, name, plan, emit_json)
    if facts is None:
        return None, exit_code
    try:
        prepared = kit_sbx.prepare(plan.kits)
    except kit_sbx.KitTranslateError as exc:
        return None, common._operational_failure(
            command, errors.VALIDATION_FAILED, f"a kit could not be prepared, so the sandbox was not created: {exc}",
            "check that the acq state directory is acq's own and writable, or reinstall acq", emit_json,
        )
    generic = agent == "opencode" and image == common.OPENCODE_DEVENV_IMAGE
    try:
        data = _create_sandbox("sbx", agent, workspace, name, image, plan.agent_kit,
                               sbx_create=("shell" if generic else agent, prepared.flags))
    except common._ADAPTER_ERRORS as exc:
        return None, common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    finally:
        kit_sbx.discard_barrier(prepared)  # sbx create has read it
    try:
        _finish_sbx_create(name, agent, plan, prepared.barrier_token, data, generic=generic)
    except BaseException as exc:
        # Also on Ctrl-C: the record still says the kits are unconfirmed, so
        # nothing attaches to this sandbox unless its removal is confirmed.
        note, remediation = _discard_unconfirmed_sbx(name)
        if not isinstance(exc, sbx.SbxError):
            raise
        return None, common._operational_failure(command, exc.code, exc.message + note,
                                                 remediation or exc.remediation, emit_json)
    _record_sbx_facts(name, facts)
    return {**data, **_kit_data(plan, kit_msb.ApplyResult(applied=[k.name for k in plan.kits]))}, None


def _sbx_provider_gate(
    command: str, name: str, plan: _KitPlan, emit_json: bool
) -> tuple[list[provider_input.Facts] | None, int | None]:
    """The sbx side of the credential gate: sbx snapshots its proxy table at create."""
    try:
        selected = _provider_gate("sbx", name, (k.name for k in plan.kits))
    except provider_input.ProviderInputError as exc:
        return None, common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    except common._ADAPTER_ERRORS as exc:
        return None, common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    return [f for _kit, _manifest, f in selected], None


def _record_sbx_facts(name: str, facts: list[provider_input.Facts]) -> None:
    """Record the facts the attach-time key check probes (best-effort, as Bash)."""
    try:
        provider_input.record_write("sbx", name, facts)
    except OSError:
        print(f"acq: warning: could not record the provider facts of sandbox '{name}'; "
              "its provider keys will not be checked before attach", file=sys.stderr)


def _finish_sbx_create(name: str, agent: str, plan: _KitPlan, token: str, data: dict, *, generic: bool) -> None:
    """Seed the host kit records, wait for the startup barrier, record what was applied, then confirm.

    The kit records describe what the host passed to the create it saw
    succeed, so they are written before the barrier, which only the guest
    writes. The state record loses its ``kits_unconfirmed`` mark last. Raises
    :class:`sbx.SbxError`; the caller removes the sandbox.
    """
    kit_sbx.clear_instance_state(name)
    if plan.selection is not None:
        kit_sbx.seed_records(name, plan.selection)
    if not kit_sbx.wait_startup_barrier(name, token):
        raise sbx.SbxError(
            errors.TIMEOUT,
            f"the kit startup commands in sandbox '{name}' did not finish within {kit_sbx.barrier_timeout_s():g}s",
            f"check network access from the sandbox, or raise {kit_sbx.BARRIER_TIMEOUT_ENV}, then retry",
        )
    try:
        if agent == "opencode":
            kit_sbx.hc_write(name, "generic-opencode", "generic-opencode" if generic else "legacy-opencode")
        kit_msb.cli_kits_write(name, plan.kits, backend="sbx")
        if plan.agent_kit is not None:
            kits.kit_applied_write("sbx", name, plan.agent_kit, plan.entrypoint or plan.agent_kit)
        kits.provenance_write("sbx", name)
        state.record_write("sbx", name, agent=agent, workspace=data["workspace"], image=data["image"])
    except OSError as exc:
        raise sbx.SbxError(
            errors.FAILURE, f"could not record the applied kits for sandbox '{name}': {exc.strerror or exc}",
            "check that the acq state directory is writable and has free space, then retry",
        ) from exc


def _discard_unconfirmed_sbx(name: str) -> tuple[str, str | None]:
    """Remove an sbx sandbox whose kits were never confirmed; returns ``(note, remediation)``.

    Its records go only once the guest is confirmed gone. Otherwise the state
    record keeps ``kits_unconfirmed``, which every attaching verb refuses, and
    the user is told to remove it.
    """
    if _remove_confirmed(common._adapter("sbx"), name):
        _clear_host_records("sbx", name)
        return "; the sandbox was removed", None
    print(f"acq: warning: sandbox '{name}' could not be removed; run 'acq rm {name}'", file=sys.stderr)
    return ("; the sandbox could not be removed, and acq refuses to attach to it until it is",
            f"run 'acq rm {name}', then retry")


def _remove_confirmed(adapter, name: str) -> bool:
    """Remove a sandbox; True only when the remove succeeded or a listing shows it gone."""
    try:
        adapter.remove(name)
        return True
    except common._ADAPTER_ERRORS:
        return _confirmed_absent(adapter, name) is True


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
    skip the agent install, so the two always go together. On msb the record of
    the sandbox's secret bindings goes too.
    """
    state.record_remove(backend, name)
    kits.kit_applied_remove(backend, name)
    kits.provenance_remove(backend, name)
    if backend == "msb":
        msb.held_forget(name)
        kit_msb.remove_host_config(name)
        kit_msb.cli_kits_remove(name)
        provider_input.remove(backend, name)
    else:
        kit_sbx.remove_host_config(name)
        kit_msb.cli_kits_remove(name, backend="sbx")


def _has_host_records(backend: str, name: str) -> bool:
    """True when any per-sandbox host record exists, readable or not."""
    held = backend == "msb" and msb.held_path(name).exists()
    return held or state.record_path(backend, name).exists() or kits.kit_applied_present(backend, name)


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
    plan: _KitPlan | None = None,
    sbx_create: tuple[str, list[str]] | None = None,
) -> dict:
    """Create + exec-ready gate + record write; returns the result record data.

    On msb, ``plan``'s kits set the egress policy and create flags. When msb can
    enforce it the host-config directory is mounted read-only, and the record
    says ``ro_host_config`` only after :func:`_confirm_ro_mount`. Secret bindings
    are reported by name and host only. ``sbx_create`` is sbx's agent and ``--kit`` flags.
    """
    adapter = common._adapter(backend)
    error_cls = sbx.SbxError if backend == "sbx" else msb.MsbError
    secret_bindings, ro_mount = None, False
    unconfirmed = backend == "sbx"  # until the kit startup barrier is seen (_finish_sbx_create)
    if backend == "sbx":
        sbx_agent, kit_flags = sbx_create or (agent, [])
        adapter.create(name, image, workspace, agent=sbx_agent, kit_flags=kit_flags)
        # Recorded at once, so no verb attaches to the guest while its kits are unconfirmed.
        _write_record(backend, name, agent=agent, workspace=workspace, image=image, ro_host_config=False,
                      kits_unconfirmed=True)
    else:
        ro_mount = security.ro_mount_supported()
        secret_bindings = _msb_create(name, image, workspace, plan.kits if plan else [], ro_mount=ro_mount)
    if not _wait_exec_ready(backend, name):
        _not_exec_ready(backend, adapter, name, error_cls)
    _fresh_guest(backend, adapter, name, ro_mount=ro_mount)
    _write_record(backend, name, agent=agent, workspace=workspace, image=image, ro_host_config=ro_mount,
                  kits_unconfirmed=unconfirmed)
    data: dict = {
        "name": name,
        "backend": backend,
        "agent": agent,
        "workspace": workspace,
        "state": "running",
        "image": image,
    }
    if secret_bindings is not None:
        data["secret_bindings"] = secret_bindings
        data["ro_host_config"] = ro_mount
    return data


def _not_exec_ready(backend: str, adapter, name: str, error_cls) -> None:
    """Remove a sandbox that never became exec-ready, then raise; it must not strand.

    Its records go only once the guest is confirmed gone; an sbx record left
    behind still says ``kits_unconfirmed``, so nothing attaches to it.
    """
    if _remove_confirmed(adapter, name):
        if backend == "sbx":
            _clear_host_records(backend, name)
        raise error_cls(errors.TIMEOUT, f"sandbox '{name}' did not become exec-ready; it was removed",
                        f"check {backend} logs, then retry")
    raise error_cls(errors.TIMEOUT, f"sandbox '{name}' did not become exec-ready, and it could not be removed",
                    f"run 'acq rm {name}', then retry")


def _fresh_guest(backend: str, adapter, name: str, *, ro_mount: bool) -> None:
    """Forget what described an earlier guest of this name, then confirm the new one's mount.

    Records left by a sandbox removed outside acq must not describe the new
    guest (no kit is installed in it yet).
    """
    kits.kit_applied_remove(backend, name)
    kits.provenance_remove(backend, name)
    if backend == "msb":
        kit_msb.clear_instance_state(name)
        if ro_mount:
            _confirm_ro_mount(adapter, name)


def _write_record(backend: str, name: str, *, agent: str, workspace: str, image: str, ro_host_config: bool,
                  kits_unconfirmed: bool = False) -> None:
    """Write the new guest's host record, or remove the guest and raise the adapter's error.

    Without its host record the guest is unusable (run/attach refuse a sandbox
    with no readable record), so it must not strand.
    """
    try:
        state.record_write(backend, name, agent=agent, workspace=workspace, image=image,
                           ro_host_config=True if ro_host_config else None,
                           kits_unconfirmed=True if kits_unconfirmed else None)
    except OSError as exc:
        removed = _remove_confirmed(common._adapter(backend), name)
        error_cls = sbx.SbxError if backend == "sbx" else msb.MsbError
        raise error_cls(
            errors.FAILURE,
            f"could not write the host state record for sandbox '{name}': {exc.strerror or exc}"
            + ("" if removed else ", and the sandbox could not be removed"),
            "check that the acq state directory is writable and has free space, then retry"
            + ("" if removed else f" (first run 'acq rm {name}')"),
        ) from exc


def _msb_create(name: str, image: str, workspace: str, kit_set: list[kit_msb.Kit], *, ro_mount: bool) -> list[str]:
    """``msb create`` with the kit set's flags; the staged startup script is removed after.

    The provider credential gate runs first (msb binds credentials only at
    create), then the provider-input generation is staged and mounted
    read-only; it is published only once the create succeeded.
    """
    generation = _provider_prepare(name, kit_set, ro_mount=ro_mount)
    try:
        flags, staged = kit_msb.create_flags(name, kit_set, ro_mount=ro_mount)
    except OSError as exc:
        _provider_abandon(name, generation)
        raise msb.MsbError(
            errors.FAILURE,
            f"could not prepare the host-config directory for sandbox '{name}': {exc.strerror or exc}",
            "check that the acq state directory is writable and has free space, then retry",
        ) from exc
    if generation is not None:
        flags += provider_input.msb_flags(generation)
    try:
        bindings = msb.create(
            name, image, workspace, memory=msb.DEFAULT_MEMORY, cpus=msb.DEFAULT_CPUS,
            egress_kits=kit_msb.egress_names(kit_set), kit_flags=flags,
        ) or []
    except BaseException:
        _provider_abandon(name, generation)
        raise
    finally:
        kit_msb.discard_staged(staged)
    _provider_publish(name, generation)
    return bindings


def _store_provider_key(adapter, provider: str, value: str) -> None:
    """Store a provider key as ``acq secret set -g PROVIDER`` does: preflight, acq store, backend feed."""
    preflight = getattr(adapter, "secret_preflight", None)
    if preflight is not None:
        preflight(secretstore.GLOBAL, provider, "", "")
    secretstore.set_secret(provider, None, value)
    adapter.secret_feed(secretstore.GLOBAL, provider, value, "", "")


def _ask_store(adapter) -> Callable[[provider_input.Facts], bool]:
    """The gate's terminal prompt: ask, then read the key with echo off and store it globally."""
    def ask(facts: provider_input.Facts) -> bool:
        print(f"\nStore a credential for provider '{facts.provider}'?\n  env var:  ${facts.key_env}\n"
              f"  sends to: {facts.host}\nStore it now? [y/N] ", end="", file=sys.stderr, flush=True)
        if sys.stdin.readline().strip().lower() not in ("y", "yes"):
            print(f"Skipping. Aborting; re-run when the '{facts.provider}' key is set.", file=sys.stderr)
            return False
        value = common._read_secret_tty(f"Enter the {facts.provider} key: ")
        try:
            if not value.strip() or secretstore.value_problem(value) is not None:
                return False
            _store_provider_key(adapter, facts.provider, value)
        finally:
            value = ""
        return True

    return ask


def _provider_gate(backend: str, name: str, kit_names: Iterable[str]) -> list[tuple[str, dict, provider_input.Facts]]:
    """The pre-create credential gate (Bash ``acq_provider_credentials_gate``) for the selected kits.

    Checks every selected provider's pin, then that the backend can inject its
    key, prompting on a terminal and failing closed otherwise. Runs before
    anything is created or removed. Returns the selected provider inputs.
    Raises :class:`provider_input.ProviderInputError` or an adapter error.
    """
    adapter = common._adapter(backend)
    scope = secretstore.sandbox_scope(name)
    selected = provider_input.selected_facts(kit_names)
    facts = [f for _kit, _manifest, f in selected]
    if backend == "sbx":
        for f in facts:
            if f.provider in sbx.BUILTIN_SERVICES:
                raise provider_input.ProviderInputError(
                    errors.VALIDATION_FAILED,
                    f"provider id '{f.provider}' collides with an sbx built-in service, which would bind "
                    f"to sbx's own vendor endpoint instead of '{f.host}'",
                    "rename the provider in its kit (provider-input.json)",
                )
    provider_input.gate(
        facts, has_key=lambda provider: adapter.secret_has(scope, provider),
        ask_store=_ask_store(adapter) if common._stdin_is_terminal() else None,
        backend=backend, stored=lambda provider: secretstore.has(provider, name),
    )
    return selected


def _provider_prepare(name: str, kit_set: list[kit_msb.Kit], *, ro_mount: bool):
    """Gate the selected providers' pins and keys, then stage and record their input.

    Returns the unpublished generation to mount, or None when msb cannot mount
    it read-only (Windows): the facts are still recorded, but OpenCode's
    renderer then leaves its config untouched. Raises :class:`msb.MsbError`.
    """
    try:
        selected = _provider_gate("msb", name, (k.name for k in kit_set))
        facts = [f for _kit, _manifest, f in selected]
        provider_input.record_write("msb", name, facts)
        if not ro_mount:
            if facts:
                print("acq: warning: provider input is not mounted without the read-only host-config mount; "
                      "OpenCode keeps its existing provider config", file=sys.stderr)
            return None
        return provider_input.prepare("msb", name, selected)
    except provider_input.ProviderInputError as exc:
        raise msb.MsbError(exc.code, exc.message, exc.remediation) from exc
    except OSError as exc:
        raise msb.MsbError(
            errors.FAILURE, f"could not record the provider facts of sandbox '{name}': {exc.strerror or exc}",
            "check that the acq state directory is writable and has free space, then retry",
        ) from exc


def _provider_abandon(name: str, generation) -> None:
    """Undo :func:`_provider_prepare` after a failed create (best-effort)."""
    if generation is not None:
        provider_input.discard(generation)
    try:
        provider_input.record_write("msb", name, [])
    except OSError:
        pass


def _provider_publish(name: str, generation) -> None:
    if generation is None:
        return
    try:
        provider_input.publish("msb", name, generation)
    except OSError:
        # The guest mounts the exact generation, so it is unaffected; only an
        # older acq reading `current` misses it.
        print(f"acq: warning: could not publish the provider input of sandbox '{name}'", file=sys.stderr)


def _confirm_ro_mount(adapter, name: str) -> None:
    """Confirm a new guest's read-only host-config mount, or remove the guest (ADR-0035).

    acq asked msb for the mount, so a guest without a confirmed one is not the
    sandbox it meant to create: it is removed rather than recorded without the
    guarantee.
    """
    status, reason = security.probe_mount(name)
    if status != "ok":
        _remove_quietly(adapter, name)
        raise msb.MsbError(
            errors.SECURITY_EXCEPTION,
            f"sandbox '{name}' was created, but its read-only trusted-config mount could not be "
            f"confirmed ({reason}); the sandbox was removed",
            "check the msb version and 'msb inspect', then retry",
        )
    try:
        kit_msb.hc_write(name, "ro-host-config", "1")  # the record Bash's gate reads
    except OSError:
        pass


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
    cli_kits = _cli_kit_refs(parsed.kit)
    name = parsed.name or common._derive_name(parsed.agent, workspace)
    workspace = common._mount_workspace(backend, workspace)
    try:
        with lock.sandbox_lock(backend, name):
            return _create_locked(parsed, emit_json, backend, name, workspace, cli_kits)
    except lock.SandboxLockTimeout as exc:
        return _lock_failure("create", name, exc, emit_json)


def _create_locked(parsed, emit_json: bool, backend: str, name: str, workspace: str, cli_kits: list[str]) -> int:
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
    new_sandbox = _new_sbx_sandbox if backend == "sbx" else _new_msb_sandbox
    data, exit_code = new_sandbox(
        "create", emit_json, agent=parsed.agent, workspace=workspace, name=name, image_flag=parsed.image,
        cli_kits=cli_kits,
    )
    if data is None:
        return exit_code if exit_code is not None else errors.EXIT_FAILURE
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
        if emit_json or not common._stdin_is_terminal():
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


def _recreate_record(backend: str, name: str, emit_json: bool) -> tuple[dict | None, int | None]:
    """The record a recreate rebuilds from, or the emitted refusal (unreadable or absent)."""
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return None, common._operational_failure(
            "create", errors.STATE_SCHEMA_UNSUPPORTED, str(exc),
            f"remove the unreadable record for '{name}', or recreate it out of band", emit_json,
        )
    if record is None:
        return None, common._operational_failure(
            "create", errors.SANDBOX_NOT_FOUND, f"sandbox '{name}' has no host state record to recreate",
            "create it with 'acq create', or list sandboxes with 'acq ls'", emit_json,
        )
    return record, None


def _recreate_locked(name: str, emit_json: bool, backend: str) -> int:
    """The body of ``create --recreate`` once the lifecycle lock is held.

    The record is read again under the lock: another command may have removed
    the sandbox while the consent prompt was open.
    """
    record, exit_code = _recreate_record(backend, name, emit_json)
    if record is None:
        return exit_code if exit_code is not None else errors.EXIT_FAILURE
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
    if backend != "msb":
        return common._operational_failure(
            "create",
            errors.UNSUPPORTED,
            f"cannot recreate sandbox '{name}': the read-only trusted-config mount is an msb-only guarantee",
            f"remove it with 'acq rm {name}' and create it again",
            emit_json,
        )
    data, exit_code = _recreate_msb(name, record, agent, workspace, image, emit_json)
    if data is None:
        return exit_code if exit_code is not None else errors.EXIT_FAILURE
    data = {**data, "recreated": True}
    if emit_json:
        print(json.dumps(envelope.success("create", data)))
    else:
        print(f"recreated sandbox '{name}' (host records and secrets preserved).")
        if not data.get("ro_host_config"):
            print(f"note: {security.PLATFORM_PROBLEM}, so the read-only trusted-config mount was not established "
                  "(see docs/KNOWN_FAILURE_MODES.md, section 54).")
    return errors.EXIT_SUCCESS


def _recreate_msb(
    name: str, record: dict, agent: str, workspace: str, image: str, emit_json: bool
) -> tuple[dict | None, int | None]:
    """Replace the guest with what a fresh create on this host builds, then reapply its kits.

    Where the read-only mount is possible it is established and confirmed. An
    msb too old for it is refused (upgrading fixes it). On a host that can never
    have it (Windows) the guest is recreated without it and the new record does
    not claim it, exactly as a fresh create there: refusing would only force
    ``rm`` and ``create`` for the same result, and recording it would loop.
    Everything that can refuse is checked BEFORE the old guest is removed. On a
    kit failure the new guest goes but the state record stays, for a retry.
    """
    problem = security.ro_mount_version_problem()
    if problem is not None and security.ro_mount_platform_problem() is None:
        return None, common._operational_failure(
            "create", errors.VALIDATION_FAILED,
            f"cannot recreate sandbox '{name}' with a read-only trusted-config mount: {problem}",
            f"upgrade msb to {security.RO_MOUNT_MIN_VERSION.string} or newer, then retry", emit_json,
        )
    cli_kits, extras = kit_msb.cli_kits_read(name)
    plan, exit_code = _plan_msb_kits(agent, cli_kits, image, "create", emit_json, extras)
    if plan is None:
        return None, exit_code
    steps, exit_code = _substrate_plan(image, plan.agent_kit, "create", emit_json)
    if exit_code is not None:
        return None, exit_code
    try:
        msb.egress_flags(kit_msb.egress_names(plan.kits))
        # A pin mismatch or a missing provider key refuses here, old guest intact.
        _provider_gate("msb", name, (k.name for k in plan.kits))
    except provider_input.ProviderInputError as exc:
        return None, common._operational_failure("create", exc.code, exc.message, exc.remediation, emit_json)
    except common._ADAPTER_ERRORS as exc:
        return None, common._operational_failure("create", exc.code, exc.message, exc.remediation, emit_json)
    try:
        # Preserve host records + secrets; lose only the guest filesystem. A guest
        # already removed out of band has nothing to destroy.
        if msb.exists(name):
            msb.remove(name)
        data = _create_sandbox("msb", agent, workspace, name, image, plan.agent_kit, plan=plan)
    except common._ADAPTER_ERRORS as exc:
        return None, common._operational_failure("create", exc.code, exc.message, exc.remediation, emit_json)
    result, exit_code = _apply_msb_kits(name, plan, steps, "create", emit_json, ro_required=data["ro_host_config"])
    if result is None:
        _discard_recreated_guest("msb", name)
        _restore_record("msb", name, record)
        return None, exit_code
    return {**data, **_kit_data(plan, result)}, None


def _restore_record(backend: str, name: str, record: dict) -> None:
    """Put back the record a failed recreate started from, so the recreate can be retried.

    The new guest's record may say less (on Windows it never claims the
    read-only mount), and a retry is only eligible while the record still
    says what the sandbox is missing.
    """
    try:
        state.atomic_write_text(state.record_path(backend, name), json.dumps(record, indent=2) + "\n")
    except OSError:
        print(f"acq: warning: could not restore the host record of '{name}'", file=sys.stderr)


def _run_prepare_locked(
    parsed, emit_json: bool, backend: str, target: str, name: str, workspace: str, cli_kits: list[str]
) -> tuple[dict | None, int | None]:
    """Create-or-reattach for ``run AGENT PATH`` with the lifecycle lock held.

    Returns ``(data, None)`` with the result data (whose ``workspace`` and
    ``entrypoint`` drive the launch), or ``(None, exit_code)`` once a failure has
    been reported. The launch itself happens after the lock is released: an
    interactive session must not block other commands on the sandbox.
    """
    adapter = common._adapter(backend)
    if not adapter.exists(name):
        new_sandbox = _new_sbx_sandbox if backend == "sbx" else _new_msb_sandbox
        data, exit_code = new_sandbox(
            "run", emit_json, agent=target, workspace=workspace, name=name, image_flag=parsed.image,
            cli_kits=cli_kits,
        )
        if data is None:
            return None, exit_code
        return {**data, "action": "created"}, None
    recorded, exit_code = _reattach_workspace(backend, name, workspace, emit_json)
    if exit_code is not None:
        return None, exit_code
    # Re-attach: the kits were applied at create time; read the recorded
    # kit/entrypoint (lenient) so the launch surfaces provenance.
    applied = kits.kit_applied_read(backend, name) or {}
    return {
        "name": name,
        "backend": backend,
        "agent": target,
        "workspace": recorded or workspace,
        "state": "running",
        "action": "reattached",
        "kit": applied.get("kit"),
        "entrypoint": applied.get("entrypoint"),
    }, None


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
        cli_kits = _cli_kit_refs(parsed.kit)
        name = parsed.name or common._derive_name(target, workspace)
        workspace = common._mount_workspace(backend, workspace)
        try:
            with lock.sandbox_lock(backend, name):
                data, exit_code = _run_prepare_locked(parsed, emit_json, backend, target, name, workspace, cli_kits)
        except lock.SandboxLockTimeout as exc:
            return _lock_failure("run", name, exc, emit_json)
        if data is None:
            return exit_code if exit_code is not None else errors.EXIT_FAILURE
        exit_code = _attach_key_check(backend, name, emit_json)
        if exit_code is not None:
            return exit_code
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
    return _run_by_name(backend, target, emit_json)


def _run_by_name(backend: str, target: str, emit_json: bool) -> int:
    """``run NAME``: re-attach an existing sandbox from its host record."""
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
    exit_code = _attach_key_check(backend, target, emit_json)
    if exit_code is not None:
        return exit_code
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


def _sbx_guest_output(name: str, argv: list[str]) -> str:
    """sbx's in-guest probe: ``sbx exec`` runs one shell string, so each argv token is quoted into it."""
    return sbx.exec_capture(name, shlex.join(argv), timeout=60) or ""


def _attach_key_check(backend: str, name: str, emit_json: bool) -> int | None:
    """Validate the sandbox's provider keys before an attach (Bash ``ensure_valid_provider_keys``).

    Each provider its recorded facts name is probed from inside the guest
    against its own models URL (msb and sbx alike). A rejected key fails with
    ``provider_auth_failed``, an unreachable endpoint (or no verdict at all)
    with ``provider_unreachable``: attaching with an unverified credential is
    how a dead key reaches the agent. A sandbox with no recorded facts (one
    created before facts were recorded) has nothing to check.
    """
    probe = msb.guest_output if backend == "msb" else _sbx_guest_output
    try:
        facts = provider_input.recorded(backend, name)
        provider_input.check_keys(name, facts, lambda argv: probe(name, argv),
                                  lambda message: print(f"acq: warning: {message}", file=sys.stderr))
    except provider_input.ProviderInputError as exc:
        return common._operational_failure("run", exc.code, exc.message, exc.remediation, emit_json)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("run", exc.code, exc.message, exc.remediation, emit_json)
    return None


def _launch_after_envelope(backend: str, name: str, workspace: str | None, token: str | None, emit_json: bool) -> int:
    """Launch for ``run`` once its success envelope may already be on stdout.

    Under ``--json`` stdout must carry exactly one document, and ``run`` has
    already printed it before the foreground launch. A launch that cannot start
    (e.g. the backend CLI vanished) is therefore reported on stderr only, with
    exit 1, instead of reaching the command boundary, which would print a second
    document.
    """
    try:
        env = session.session_env_for(backend, name)
        return common._adapter(backend).launch(name, workspace, token, json_mode=emit_json, env=env)
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


# ---------------------------------------------------------------------------
# start / restart (msb only; ADR-0017, ADR-0040m). Bash: the acq start/restart
# arms, acq_backend_start and acq_cli_kits_load.
# ---------------------------------------------------------------------------

def run_start(parsed, emit_json: bool, backend: str) -> int:
    """``acq start NAME``: resume a stopped msb sandbox, rebind its secrets, heal its kits."""
    return _start_verb("start", parsed.name, emit_json, backend)


def run_restart(parsed, emit_json: bool, backend: str) -> int:
    """``acq restart NAME``: stop (a failure only warns, as in Bash), then the same as ``start``."""
    return _start_verb("restart", parsed.name, emit_json, backend)


def _start_verb(command: str, name: str, emit_json: bool, backend: str) -> int:
    """Refuse on a backend without the verb, else run it under the sandbox's lifecycle lock.

    sbx has no detached resume: a stopped sandbox resumes on attach, so the
    remediation is ``acq run NAME`` (Bash prints the same).
    """
    if not common._supports(backend, command):
        hint = f" (optionally 'acq stop {name}' first)" if command == "restart" else ""
        return common._operational_failure(
            command, errors.UNSUPPORTED,
            f"the '{backend}' backend has no separate '{command}' verb",
            f"a stopped sandbox resumes automatically on attach: run 'acq run {name}'{hint}", emit_json,
        )
    try:
        with lock.sandbox_lock(backend, name):
            return _start_locked(command, name, emit_json)
    except lock.SandboxLockTimeout as exc:
        return _lock_failure(command, name, exc, emit_json)


def _start_record(command: str, name: str, emit_json: bool) -> tuple[dict | None, int | None]:
    """The sandbox's host record (``None`` when absent) once msb lists it, or the emitted refusal.

    Both checks come before anything changes: a missing sandbox is
    ``sandbox_not_found``, and a record that cannot be read fails closed.
    """
    try:
        if not msb.exists(name):
            return None, common._operational_failure(
                command, errors.SANDBOX_NOT_FOUND, f"sandbox '{name}' not found",
                "list sandboxes with 'acq ls', or create one with 'acq create'", emit_json,
            )
        return state.record_read("msb", name), None
    except state.StateSchemaError as exc:
        return None, common._operational_failure(
            command, errors.STATE_SCHEMA_UNSUPPORTED, str(exc),
            f"recreate the sandbox with 'acq create --recreate {name}', or remove it with 'acq rm {name}'",
            emit_json,
        )
    except common._ADAPTER_ERRORS as exc:
        return None, common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)


def _resume(command: str, name: str) -> bool:
    """Stop first for ``restart``, then ``msb start`` unless it already runs; True if it was running.

    A failed stop is a warning and the start is still attempted (Bash parity);
    if the sandbox is still running, the heal runs and ``restart`` then fails
    (:func:`_finish_start`). Raises the adapter error when the listing or the
    start fails.
    """
    if command == "restart":
        try:
            msb.stop(name)
        except msb.MsbError:
            print(f"acq: warning: restart: stop of '{name}' failed; attempting start anyway", file=sys.stderr)
    running = msb.running_names()
    if running is None:
        raise msb.MsbError(errors.FAILURE, "could not list running sandboxes", "check that msb works ('msb list'), then retry")
    if name in running:
        return True
    msb.start(name)
    return False


def _start_locked(command: str, name: str, emit_json: bool) -> int:
    """Resume, wait for exec-readiness, check the read-only mount, rebind secrets, heal the kits.

    The mount is checked before any secret is bound, so a sandbox missing its
    read-only trusted config never receives a newly added credential. Once the
    sandbox runs, every failure says so: it is not stopped again, and a heal
    that did not complete is never reported as success (ADR-0038m).
    """
    record, exit_code = _start_record(command, name, emit_json)
    if exit_code is not None:
        return exit_code
    try:
        was_running = _resume(command, name)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    if not _wait_exec_ready("msb", name):
        return common._operational_failure(
            command, errors.TIMEOUT,
            f"sandbox '{name}' was started but did not become exec-ready, so its secrets and kits were not re-applied",
            f"check msb logs, then retry 'acq {command} {name}'", emit_json,
        )
    gate = _start_trusted_gate(command, name, record, emit_json)
    if gate is not None:
        return gate
    try:
        unbound = msb.reconcile_bindings(name)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure(
            command, exc.code, f"sandbox '{name}' is running, but: {exc.message}", exc.remediation, emit_json,
        )
    applied, exit_code = _heal_after_start(command, name, record, emit_json)
    if applied is None:
        return exit_code if exit_code is not None else errors.EXIT_FAILURE
    return _finish_start(command, name, applied, unbound, was_running, emit_json)


def _start_trusted_gate(command: str, name: str, record: dict | None, emit_json: bool) -> int | None:
    """Refuse to rebind or heal a running sandbox whose recorded read-only mount is not confirmed (ADR-0035)."""
    try:
        security.assert_trusted(record, "msb", name)
    except security.SecurityException as exc:
        return common._operational_failure(
            command, exc.code, f"{exc.message}; the sandbox is running, but its secrets and kits were not re-applied",
            exc.remediation, emit_json,
        )
    return None


def _finish_start(
    command: str, name: str, applied: list[str], unbound: list[str], was_running: bool, emit_json: bool
) -> int:
    """Report the outcome after the heal: a secret left unbound, or a restart whose stop did not
    take effect (the sandbox was never stopped, so it was not restarted), is a failure."""
    if unbound:
        return common._operational_failure(
            command, errors.FAILURE,
            f"sandbox '{name}' is running and its kits were re-applied, but {', '.join(unbound)} could not be bound in it",
            f"retry 'acq {command} {name}', or recreate the sandbox to bind the stored values", emit_json,
        )
    if command == "restart" and was_running:
        return common._operational_failure(
            command, errors.FAILURE,
            f"could not restart sandbox '{name}': it could not be stopped and is still running "
            "(its secrets and kits were re-applied)",
            f"check msb logs, then retry 'acq restart {name}', or run 'acq stop {name}' and 'acq start {name}'",
            emit_json,
        )
    return _print_started(command, name, applied, was_running, emit_json)


def _heal_after_start(command: str, name: str, record: dict | None, emit_json: bool) -> tuple[list[str] | None, int | None]:
    """Re-apply the kit set (the mount was checked already); the applied kits or the emitted failure.

    The kit set is the one create chose: the recorded agent and image, plus the
    ``--kit`` and extra refs kept in the sandbox's ``.kits`` record. Re-applying
    re-runs every kit's startup phase, which ``msb start`` does not replay
    (ADR-0017). Provenance is recorded only when every kit applied, as Bash does.
    """
    agent = (record or {}).get("agent") or "shell"
    image = (record or {}).get("image") or common.OPENCODE_DEVENV_IMAGE
    cli_kits, extras = kit_msb.cli_kits_read(name)
    plan, exit_code = _plan_msb_kits(agent, cli_kits, image, command, emit_json, extras)
    if plan is None:
        return None, exit_code
    result = kit_msb.ensure_kits_applied(name, plan.kits, ro_required=security.requires_ro_mount(record))
    if result.incomplete:
        return None, common._operational_failure(
            command, errors.FAILURE,
            f"sandbox '{name}' is running, but these kits were not re-applied: {', '.join(result.incomplete)}",
            f"check the warnings above, then retry 'acq {command} {name}'", emit_json,
        )
    try:
        kits.provenance_write("msb", name)
    except OSError:
        print(f"acq: warning: could not record the kit provenance of '{name}'", file=sys.stderr)
    return result.applied, None


def _print_started(command: str, name: str, applied: list[str], was_running: bool, emit_json: bool) -> int:
    data = {
        "name": name, "backend": "msb", "state": "running", "was_running": was_running,
        "secret_bindings": msb.held_flags(name), "kits": applied,
    }
    if emit_json:
        print(json.dumps(envelope.success(command, data)))
    elif was_running:
        print(f"sandbox '{name}' was already running; re-applied its kits")
    else:
        print(f"{command}ed sandbox '{name}' and re-applied its kits")
    return errors.EXIT_SUCCESS
