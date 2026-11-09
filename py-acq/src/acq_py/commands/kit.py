"""``kit`` list/validate/apply/check/update and ``kit-source`` add/ls/rm:
kit-bundle provenance and application (ADR-0016, ADR-0030).
"""

from __future__ import annotations

import json

from .. import (
    backends,
    envelope,
    errors,
    kit_msb,
    kit_sbx,
    kits,
    kitspec,
    lock,
    msb,
    sbx,
    security,
    state,
)
from . import common


def _print_kit_list_human(data: dict) -> None:
    print("Pinned acq kits (neutral hybrid/v1):")
    print(f"  control plane: {data['control_plane_ref']}")
    print()
    for name in data["built_in"]:
        print(f"  - {name}")
    for name in data["provider"]:
        print(f"  - {name} (provider)")
    if data["extra"]:
        print()
        print("Extra kits (ACQ_EXTRA_KITS):")
        for name in data["extra"]:
            print(f"  - {name}")


def run_kit_list(emit_json: bool) -> int:
    data = kits.kit_list_data()
    if emit_json:
        print(json.dumps(envelope.success("kit list", data)))
    else:
        _print_kit_list_human(data)
    return errors.EXIT_SUCCESS


def run_kit_validate(parsed, emit_json: bool) -> int:
    """``acq kit validate PATH`` — validity + coded findings (ADR-0038m §2).

    A readable kit (valid or not) is a successful query answer (exit 0): validity
    and the coded findings are the result data. A kit that cannot be read at all —
    a missing path, a directory without ``spec.yaml``, or an unreadable
    ``spec.yaml`` — is an operational failure (``validation_failed``, exit 1).
    """
    path = parsed.path
    try:
        data = kits.validate_kit(path)
    except kits.KitSpecError as exc:
        return common._operational_failure(
            "kit validate",
            errors.VALIDATION_FAILED,
            str(exc),
            "pass a kit directory (containing spec.yaml) or a path to spec.yaml",
            emit_json,
        )
    if emit_json:
        print(json.dumps(envelope.success("kit validate", data)))
    else:
        if data["valid"]:
            print("valid")
        else:
            for finding in data["findings"]:
                line = f"[{finding['code']}] {finding['message']}"
                print(line)
                if finding.get("remediation"):
                    print(f"           {finding['remediation']}")
    return errors.EXIT_SUCCESS


def run_kit_apply(parsed, emit_json: bool, backend_override: str | None) -> int:
    """``acq kit apply NAME KITREF`` — apply a built-in agent kit to a sandbox.

    The ``kit-apply`` capability maps through the adapter seam (ADR-0040m): a
    backend that declares it ``unsupported`` fails closed with
    ``unsupported_capability``. On sbx the kit is added with ``sbx kit add``,
    which sbx 0.38 and later refuse for a kit with startup commands
    (``unsupported_capability``: recreate the sandbox). Only built-in agent kits are
    applicable by name here; team/personal kit application is deferred. The
    install runs in-guest and is idempotent: a re-apply of the same kit is a no-op
    (no duplicate install), tracked by the host-authoritative applied-kit record
    (ADR-0041m).
    """
    backend, exit_code = common._resolve_backend_for_mutation(
        backend_override, emit_json, "kit apply", domain="kit"
    )
    if exit_code is not None:
        return exit_code
    assert backend is not None  # nosec B101 # resolver contract; narrows the type for mypy
    if not common._supports(backend, "kit-apply"):
        return common._operational_failure(
            "kit apply",
            errors.UNSUPPORTED,
            f"kit apply is not supported on the {backend} backend",
            "use a backend that supports kit-apply (ADR-0040m)",
            emit_json,
        )
    name = parsed.name
    try:
        with lock.sandbox_lock(backend, name):
            return _kit_apply_locked(name, parsed.kitref, emit_json, backend)
    except lock.SandboxLockTimeout as exc:
        return common._operational_failure(
            "kit apply",
            errors.TIMEOUT,
            str(exc),
            exc.remediation or f"wait for the other acq command on sandbox '{name}' to finish, then retry",
            emit_json,
        )


def _kit_apply_locked(name: str, kitref: str, emit_json: bool, backend: str) -> int:
    """The body of ``kit apply`` once the sandbox's lifecycle lock is held.

    Holding the lock keeps a concurrent ``rm`` from removing the guest between
    the install and the applied-kit record write.
    """
    if not common._adapter(backend).exists(name):
        return common._operational_failure(
            "kit apply",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            "list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    if not kits.is_agent_kit(kitref):
        return common._operational_failure(
            "kit apply",
            errors.VALIDATION_FAILED,
            f"kit ref {kitref!r} is not a built-in agent kit (expected one of: {', '.join(kits.AGENT_KIT_NAMES)})",
            "this slice applies built-in agent kits by name; team/personal kit application is deferred",
            emit_json,
        )
    kit_name = kitref
    entrypoint = kits.agent_kit_entrypoint(kit_name)
    existing = kits.kit_applied_read(backend, name)
    applied = not (existing and existing.get("kit") == kit_name)
    if applied:
        exit_code = _kit_apply_install(name, kit_name, backend, emit_json)
        if exit_code is not None:
            return exit_code
        kits.kit_applied_write(backend, name, kit_name, entrypoint)
    data = {
        "sandbox": name,
        "backend": backend,
        "kit": kit_name,
        "entrypoint": entrypoint,
        "applied": applied,
        "action": "applied" if applied else "noop",
    }
    if emit_json:
        print(json.dumps(envelope.success("kit apply", data)))
    elif applied:
        print(f"applied kit '{kit_name}' to sandbox '{name}' (entrypoint {entrypoint}).")
    else:
        print(f"kit '{kit_name}' already applied to sandbox '{name}'.")
    return errors.EXIT_SUCCESS


def _kit_apply_install(name: str, kit_name: str, backend: str, emit_json: bool) -> int | None:
    """Apply the bundled kit in-guest once the read-only-mount gate passes; an exit code on failure."""
    record, exit_code = _trusted_record(backend, name, "kit apply", emit_json)
    if exit_code is not None:
        return exit_code
    if backend == "sbx":
        try:
            kit_sbx.apply_single(name, kit_sbx.bundled_kit(kit_name, "agent"))
        except common._ADAPTER_ERRORS as exc:
            return common._operational_failure("kit apply", exc.code, exc.message, exc.remediation, emit_json)
        return None
    try:
        kit = kit_msb.bundled_kit(kit_name, "agent")
        applied = kit_msb.apply_single(name, kit, ro_required=security.requires_ro_mount(record))
    except kit_msb.KitApplyFailed as exc:
        return common._operational_failure("kit apply", errors.FAILURE, str(exc), "check msb logs and retry", emit_json)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("kit apply", exc.code, exc.message, exc.remediation, emit_json)
    if not applied:
        return common._operational_failure(
            "kit apply", errors.FAILURE, f"could not apply kit '{kit_name}' to sandbox '{name}'",
            "check network access from the sandbox and the warnings above, then retry", emit_json,
        )
    return None


def _trusted_record(backend: str, name: str, command: str, emit_json: bool) -> tuple[dict | None, int | None]:
    """The sandbox's host record, once the read-only-mount gate has passed (ADR-0035).

    Applying kits runs trusted code in the guest, so a sandbox whose recorded
    read-only mount is missing or unconfirmed is refused, as for ``run``.
    """
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return None, common._operational_failure(
            command, errors.STATE_SCHEMA_UNSUPPORTED, str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {name}'", emit_json,
        )
    return record, common._trusted_gate(record, backend, command, name, emit_json)


def _print_kit_check_human(data: dict) -> None:
    print(f"sandbox:       {data['sandbox']} (backend: {data['backend']})")
    print(f"local pinned:  {data['local']}")
    print(f"applied ref:   {data['applied'] or '<none recorded>'}")
    if data["status"] == "current":
        print("status:        current (on the pinned bundle)")
    elif data["status"] == "stale":
        print("status:        stale (does not match the pinned bundle)")
        print()
        print(f"refresh in place with: acq kit update {data['sandbox']}")
    else:
        print("status:        unknown (no provenance record; may predate tracking)")
        print()
        print(f"refresh in place with: acq kit update {data['sandbox']}")


def run_kit_check(parsed, emit_json: bool, backend_override: str | None) -> int:
    """``acq kit check SANDBOX`` — read-only currency report (ADR-0016).

    Exit 0 for current/stale/unknown; exit 1 for a missing sandbox (ADR-0038m).
    """
    backend, exit_code = common._resolve_backend_for_mutation(
        backend_override, emit_json, "kit check", domain="kit inspection"
    )
    if exit_code is not None:
        return exit_code
    assert backend is not None  # nosec B101 # resolver contract; narrows the type for mypy
    name = parsed.name
    if not common._adapter(backend).exists(name):
        return common._operational_failure(
            "kit check",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            "list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    data = kits.kit_check_data(backend, name)
    if emit_json:
        print(json.dumps(envelope.success("kit check", data)))
    else:
        _print_kit_check_human(data)
    return errors.EXIT_SUCCESS


def run_kit_update(parsed, emit_json: bool, backend_override: str | None) -> int:
    """``acq kit update SANDBOX [--yes]`` — consented in-place reapply of the kit bundle.

    Consent (ADR-0038m §46): ``--yes``, or a TTY prompt; non-interactive runs
    without ``--yes`` refuse. The reapply (Bash ``acq_bundle_reapply``) reruns
    every selected kit with installs forced, under the lifecycle lock, and
    records ``applied_ref`` only when every kit applied (ADR-0038m §3). The
    guest is never recreated.
    """
    backend, exit_code = common._resolve_backend_for_mutation(
        backend_override, emit_json, "kit update", domain="kit inspection"
    )
    if exit_code is not None:
        return exit_code
    assert backend is not None  # nosec B101 # resolver contract; narrows the type for mypy
    name = parsed.name
    if not common._adapter(backend).exists(name):
        return common._operational_failure(
            "kit update",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            "list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    status = kits.provenance_status(backend, name)
    if status == "current":
        data = {**kits.kit_check_data(backend, name), "action": "noop"}
        if emit_json:
            print(json.dumps(envelope.success("kit update", data)))
        else:
            print(f"sandbox '{name}' is already on the pinned bundle; nothing to do.")
        return errors.EXIT_SUCCESS
    if not common._supports(backend, "kit-apply"):
        return common._operational_failure(
            "kit update", errors.UNSUPPORTED, f"kit reapply is not supported on the {backend} backend",
            "use a backend that supports kit-apply (ADR-0040m)", emit_json,
        )
    if not parsed.yes:
        declined = _kit_update_consent(name, backend, emit_json)
        if declined is not None:
            return declined
    try:
        with lock.sandbox_lock(backend, name):
            return common.with_recorded_selection(
                "kit update", backend, name, emit_json, lambda: _kit_update_locked(name, emit_json, backend)
            )
    except lock.SandboxLockTimeout as exc:
        return common._operational_failure(
            "kit update", errors.TIMEOUT, str(exc),
            exc.remediation or f"wait for the other acq command on sandbox '{name}' to finish, then retry",
            emit_json,
        )


def _kit_update_consent(name: str, backend: str, emit_json: bool) -> int | None:
    """Ask for consent; ``None`` when given, else the emitted exit code (refused or cancelled)."""
    if emit_json or not common._stdin_is_terminal():
        return common._operational_failure(
            "kit update",
            errors.CONSENT_REQUIRED,
            f"refusing to refresh '{name}' non-interactively without --yes",
            f"re-run with 'acq kit update {name} --yes' to consent",
            emit_json,
        )
    answer = input(f"refresh the kit bundle in '{name}' to {kits.CONTROL_PLANE_REF}? [y/N] ")
    if answer.strip().lower() in ("y", "yes"):
        return None
    if emit_json:
        print(json.dumps(envelope.success("kit update", {"sandbox": name, "backend": backend, "action": "cancelled"})))
    else:
        print("cancelled.")
    return errors.EXIT_SUCCESS


def _kit_update_locked(name: str, emit_json: bool, backend: str) -> int:
    """Reapply the kit set to a running sandbox, then record provenance on full success."""
    record, exit_code = _trusted_record(backend, name, "kit update", emit_json)
    if exit_code is not None:
        return exit_code
    if backend == "sbx":
        return _kit_update_sbx(name, record, emit_json)
    if name not in (msb.running_names() or []):
        return common._operational_failure(
            "kit update", errors.FAILURE, f"sandbox '{name}' is not running, so its kits cannot be reapplied",
            f"start it (for example by re-attaching with 'acq run {name}'), then retry", emit_json,
        )
    agent = (record or {}).get("agent") or "shell"
    try:
        cli_kits, extras = kit_msb.cli_kits_read(name)
        image = (record or {}).get("image") or common.OPENCODE_DEVENV_IMAGE
        kit_set = kit_msb.select(agent, cli_kits, image_is_default=image == common.OPENCODE_DEVENV_IMAGE,
                                 extras=extras)
    except kitspec.KitSelectionError as exc:
        return common._operational_failure("kit update", errors.VALIDATION_FAILED, str(exc),
                                           "fix the kit selection and retry", emit_json)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("kit update", exc.code, exc.message, exc.remediation, emit_json)
    result = kit_msb.ensure_kits_applied(name, kit_set, ro_required=security.requires_ro_mount(record), force=True)
    if result.incomplete:
        return _kit_update_incomplete(name, result.incomplete, emit_json)
    return _kit_update_done(name, backend, result.applied, emit_json)


def _kit_update_incomplete(name: str, failed: list[str], emit_json: bool) -> int:
    return common._operational_failure(
        "kit update", errors.FAILURE,
        f"the kit refresh of '{name}' did not complete ({', '.join(failed)}); its provenance was left unchanged",
        f"re-run 'acq kit update {name} --yes' to retry, or recreate the sandbox for a clean rebuild",
        emit_json,
    )


def _kit_update_done(name: str, backend: str, applied: list[str], emit_json: bool) -> int:
    """Record provenance after a complete refresh and report it."""
    kits.provenance_write(backend, name)
    data = {**kits.kit_check_data(backend, name), "action": "refreshed", "kits": applied}
    if emit_json:
        print(json.dumps(envelope.success("kit update", data)))
    else:
        print(f"refreshed the kit bundle in '{name}' to {kits.CONTROL_PLANE_REF} (in place; state preserved).")
        print("Restart the agent (or re-run 'acq run') to pick up refreshed config.")
    return errors.EXIT_SUCCESS


def _kit_update_sbx(name: str, record: dict | None, emit_json: bool) -> int:
    """The sbx refresh: the heal with every built-in kit forced (Bash ``acq_bundle_reapply``).

    ``sbx kit add`` starts a stopped sandbox itself, so no running check is
    needed. sbx 0.38 and later refuse kits with startup commands mid-life, and
    the refresh then reports that the sandbox must be recreated.
    """
    agent = (record or {}).get("agent") or "shell"
    image = (record or {}).get("image") or common.OPENCODE_DEVENV_IMAGE
    try:
        cli_kits, extras = kit_msb.cli_kits_read(name, backend="sbx")
        kit_set, selection = kit_sbx.select(agent, cli_kits, image_is_default=image == common.OPENCODE_DEVENV_IMAGE,
                                            extras=extras)
    except kitspec.KitSelectionError as exc:
        return common._operational_failure("kit update", errors.VALIDATION_FAILED, str(exc),
                                           "fix the kit selection and retry", emit_json)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("kit update", exc.code, exc.message, exc.remediation, emit_json)
    result = kit_sbx.ensure_kits_applied(name, kit_set, selection, force=True)
    if not result.ok:
        return _kit_update_incomplete(name, result.failed or ["exec readiness"], emit_json)
    return _kit_update_done(name, "sbx", result.added, emit_json)


def _print_kit_source_ls_human(data: dict) -> None:
    print(f"{'SOURCE':52} {'REF':40} KITS-DIR")
    for src in data["sources"]:
        print(f"{src['repository']:52} {src['ref']:40} {src['directory']}")
    print()
    print("Provider kits published by these sources:")
    found = False
    for src in data["sources"]:
        if src["discovery_status"] != "reachable":
            continue
        for kit in src["provider_kits"]:
            found = True
            print(f"  {kit:34} {src['repository']} (@{src['ref']})")
    if not found:
        print("  (none discovered — sources are unreachable, or publish no provider kits)")


def run_kit_source_ls(emit_json: bool) -> int:
    data = kits.kit_source_ls_data()
    if emit_json:
        print(json.dumps(envelope.success("kit-source ls", data)))
    else:
        _print_kit_source_ls_human(data)
    return errors.EXIT_SUCCESS


def run_kit_source_add(parsed, emit_json: bool) -> int:
    repo = kits.normalize_repo(parsed.repo)
    if repo is None:
        return common._usage_failure(
            "kit-source add",
            f"invalid repository: {parsed.repo!r} (want host/owner/repo)",
            emit_json,
        )
    if kits.is_control_plane(repo):
        return common._operational_failure(
            "kit-source add",
            errors.VALIDATION_FAILED,
            "the built-in control-plane source is always trusted and cannot be re-added",
            "the control plane is the pinned trust anchor; add team/personal sources instead",
            emit_json,
        )
    ref = parsed.ref
    if not ref:
        return common._usage_failure(
            "kit-source add",
            "kit-source add requires --ref <full-sha>",
            emit_json,
        )
    if not kits.is_full_ref(ref):
        return common._operational_failure(
            "kit-source add",
            errors.KIT_REF_NOT_PINNED,
            f"kit source '{repo}' requires a full immutable ref (40/64-char SHA), got {ref!r}",
            "re-run with --ref <full-commit-sha>",
            emit_json,
        )
    directory = kits.normalize_dir(parsed.dir)
    if directory is None:
        return common._usage_failure(
            "kit-source add",
            f"unsafe kit directory: {parsed.dir!r}",
            emit_json,
        )
    action = kits.set_source(repo, ref, directory)
    data = {"repository": repo, "ref": ref, "directory": directory, "action": action}
    if emit_json:
        print(json.dumps(envelope.success("kit-source add", data)))
    else:
        print(f"{action} kit source '{repo}' (@{ref}).")
    return errors.EXIT_SUCCESS


def run_kit_source_rm(parsed, emit_json: bool, backend_override: str | None) -> int:
    # Validate --backend up front (the same unknown-backend refusal every mutating
    # verb makes via common._resolve_backend_for_mutation): `acq --backend bogus kit-source
    # rm` must reject the flag rather than silently dropping the registry entry.
    # Unlike the lifecycle verbs, kit-source rm is a host-side registry operation
    # that must still work with no backend installed, so only the flag is
    # validated here — the version floor and no-backend refusal do not apply.
    if backend_override is not None and backend_override not in backends.BACKENDS:
        return common._usage_failure(
            "kit-source rm",
            f"unknown backend: {backend_override!r} (expected sbx or msb)",
            emit_json,
        )
    repo = kits.normalize_repo(parsed.repo)
    if repo is None:
        return common._usage_failure(
            "kit-source rm",
            f"invalid repository: {parsed.repo!r} (want host/owner/repo)",
            emit_json,
        )
    if kits.is_control_plane(repo):
        return common._operational_failure(
            "kit-source rm",
            errors.VALIDATION_FAILED,
            "the built-in control-plane source cannot be removed",
            "team/personal sources can be removed; the control plane is the pinned trust anchor",
            emit_json,
        )
    if kits.source_record(repo) is None:
        return common._operational_failure(
            "kit-source rm",
            errors.KIT_SOURCE_NOT_FOUND,
            f"kit source '{repo}' is not registered",
            "list trusted sources with 'acq kit-source ls'",
            emit_json,
        )
    # sbx-only: revoke the source from sbx's kit.allowedSources BEFORE the host
    # record is dropped, so a failed revocation never strands a trusted source the
    # backend still fetches from (ADR-0040m ``kit_source_revoked``). The owner
    # prefix is kept while the control plane, another registered source or an
    # ACQ_EXTRA_KIT_SOURCES grant still needs it (sbx.kit_source_revoked). Revocation
    # fires on the RESOLVED active backend (--backend flag → ACQ_BACKEND env →
    # auto-detect): whenever sbx is the backend in effect — selected explicitly OR
    # auto-detected as the sole installed backend — the owner prefix is dropped
    # from kit.allowedSources so the source is no longer fetchable. When the
    # resolved backend is msb (or there is no backend), only the host registry
    # entry is dropped, as before.
    # When both backends are installed with no flag/env, auto-detect resolves msb,
    # so sbx's owner prefix is not revoked here — correct under the resolved-active-
    # backend scope, and it becomes revocable once kit-apply (ADR-0030) lands.
    invalid = common._invalid_persisted_backend_failure(backend_override, "kit-source rm", emit_json)
    if invalid is not None:
        return invalid
    resolved = common._resolve_active_backend(backend_override)
    if resolved == "sbx":
        try:
            sbx.kit_source_revoked(repo)
        except sbx.SbxError as exc:
            return common._operational_failure("kit-source rm", exc.code, exc.message, exc.remediation, emit_json)
    kits.remove_source(repo)
    data = {"repository": repo, "removed": True}
    if emit_json:
        print(json.dumps(envelope.success("kit-source rm", data)))
    else:
        print(f"removed kit source '{repo}'.")
    return errors.EXIT_SUCCESS
