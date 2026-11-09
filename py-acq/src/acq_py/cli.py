"""CLI entrypoint for acq v1: the argparse surface and the command dispatch.

The highest seam is the subprocess boundary (ADR-0038m section 1): exit codes
0/1/2 and the structured-output envelope (``--json``) are the contract. This
module owns that surface — ``build_parser`` and ``main`` — plus the two verbs
whose handlers are small enough to live beside it (``backend`` list/check/set/unset
and ``doctor``). Every other handler lives in :mod:`acq_py.commands`
(see ADR-0046m for why the boundary falls here):

    commands/common.py     the adapter seam, failure envelopes, backend and
                           workspace resolution, secret-scope parsing
    commands/lifecycle.py  create, run, create --recreate, ls, stop, rm
    commands/session.py    exec, attach, shell, cp, ports, verbatim passthrough
    commands/secret.py     secret set/rm/ls/has/import
    commands/creds.py      provider-credential, github-scope, usai-rotate-api-key
    commands/kit.py        kit list/validate/apply/check/update, kit-source
    commands/configure.py  configure (show the settings, or change them at a TTY)

The names those modules own that callers address are re-exported below, so
``cli.<name>`` keeps resolving. They are aliases: substituting one in a test means
patching it on its owning module, not rebinding it here.

Output contract:
    * human output -> stdout, diagnostics -> stderr (no ``--json``)
    * JSON envelope -> stdout, diagnostics -> stderr (``--json``)
    * exit 0 success, 2 usage error, 1 operational failure
    * ``main`` is the command boundary: an adapter error or host ``OSError`` a
      handler did not map itself still leaves as a stable code and envelope,
      never a traceback
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import NoReturn

# ``doctor`` and ``version_info`` are deliberately NOT imported here: they are
# off the Tier-3 surface (ADR-0044m), and importing them at startup would make a
# break in either one kill the lifecycle/secrets verbs the live oracle drives.
# They are imported lazily inside ``run_doctor`` and the ``version`` dispatch, so
# a break there affects only ``acq doctor``/``acq version`` — never the oracle's
# contract commands. ``test_off_surface_modules_are_not_loaded_by_cli`` asserts
# this closure.
# ``msb`` is imported for its module object alone: the Tier-2 tests patch
# ``cli.msb.<fn>``, and the adapter is reached through ``commands.common`` at
# runtime. Keeping it here preserves those addresses across the command split.
from . import backends, config, envelope, errors, migration, msb, state, userdirs  # noqa: F401
from .commands import common, configure, creds, kit, lifecycle, secret, session

# Every subcommand acq owns. An argv token that is not one of these (and is not a
# flag) is treated as an unknown verb and forwarded verbatim to the active
# backend (announced passthrough, spec user story #9 / ADR-0038m §1).
KNOWN_COMMANDS = frozenset(
    "version doctor help backend configure create run ls stop rm exec attach shell cp ports "
    "secret kit kit-source provider-credential github-scope usai-rotate-api-key".split()
)


# The command handlers live in ``acq_py.commands`` (see that package); this module
# owns the argparse surface and the dispatch below. These re-exports keep the
# historical ``cli.<name>`` addresses working for callers and for the Tier-2 tests
# that call them, so the split stays invisible to every existing caller. They are
# aliases, not indirections: every handler reads the name from its owning module, so
# a test that needs to substitute one must patch it THERE (or on the shared adapter
# module, as ``cli.msb`` does) — rebinding ``cli.<name>`` would have no effect. The
# adapter modules above are imported here for the same reason (``cli.msb`` is the
# module object the tests patch), and because importing them eagerly is part of the
# Tier-3 surface closure: only ``doctor`` and ``version_info`` stay lazy.
_ADAPTER_ERRORS = common._ADAPTER_ERRORS
KNOWN_AGENTS = common.KNOWN_AGENTS
DEFAULT_GUEST_WORKSPACE = common.DEFAULT_GUEST_WORKSPACE
OPENCODE_DEVENV_IMAGE = common.OPENCODE_DEVENV_IMAGE
SUBSTRATE_STATE_ENV = lifecycle.SUBSTRATE_STATE_ENV
_adapter = common._adapter
_supports = common._supports
_default_image_for_agent = common._default_image_for_agent
_usage_failure = common._usage_failure
_operational_failure = common._operational_failure
_resolve_active_backend = common._resolve_active_backend
_read_secret_value = common._read_secret_value
_validate_workspace = common._validate_workspace
_mount_workspace = common._mount_workspace
_sandbox_ref = common._sandbox_ref
_workspace_from_record = common._workspace_from_record
_slugify = common._slugify
_derive_name = common._derive_name
_parse_secret_scope_service = common._parse_secret_scope_service
_parse_secret_ls_scope = common._parse_secret_ls_scope
_resolve_image = lifecycle._resolve_image


class UsageError(Exception):
    """Raised for usage errors; carries the human-facing message."""


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        # argparse's default prints usage + exits; we raise so main() can emit a
        # consistent failure envelope/exit code instead.
        raise UsageError(message)


def _flag_value(argv: list[str], flag: str) -> str | None:
    try:
        i = argv.index(flag)
    except ValueError:
        return None
    if i + 1 < len(argv):
        return argv[i + 1]
    return None


def _strip_flag(argv: list[str], flag: str) -> list[str]:
    out: list[str] = []
    skip_next = False
    for token in argv:
        if skip_next:
            skip_next = False
            continue
        if token == flag:
            skip_next = True
            continue
        out.append(token)
    return out


def build_parser() -> _Parser:
    parser = _Parser(
        prog="acq",
        description="acq v1 - run AI coding agents inside a federally-configured sandbox",
        add_help=True,
        epilog=(
            "Any subcommand acq does not own is forwarded verbatim to the active "
            "backend binary with a notice on stderr; the backend's output and exit "
            "status pass through unchanged (--json is inert for such passthrough)."
        ),
    )
    parser.add_argument("--version", action="store_true", help="show version and exit")
    sub = parser.add_subparsers(dest="command", metavar="COMMAND")
    sub.add_parser("version", help="show acq version + backend info")
    doctor_p = sub.add_parser("doctor", help="diagnose the acq environment")
    doctor_p.add_argument("name", nargs="?", default=None, help="sandbox to inspect (requires a backend)")
    sub.add_parser("help", help="show help")

    backend_parser = sub.add_parser(
        "backend", help="detect, inspect and select the sandbox backends (sbx, msb)"
    )
    backend_sub = backend_parser.add_subparsers(dest="backend_command", metavar="SUBCOMMAND")
    backend_sub.add_parser("list", help="list detected backends")
    check_parser = backend_sub.add_parser("check", help="fail closed on an unsupported backend version")
    check_parser.add_argument("name", help="backend name (sbx | msb)")
    set_parser = backend_sub.add_parser("set", help="persist the default backend in config.yaml")
    set_parser.add_argument("name", help="backend name (sbx | msb)")
    backend_sub.add_parser("unset", help="clear the persisted default (fall back to auto-detect)")

    sub.add_parser(
        "configure",
        help="show the configuration; at a terminal, choose extra kits, token scoping and the provider kit",
    )

    create_parser = sub.add_parser("create", help="create a sandbox (detached)")
    create_parser.add_argument("agent", nargs="?", help="agent to provision (e.g. opencode, shell)")
    create_parser.add_argument("path", nargs="?", help="workspace directory to mount")
    create_parser.add_argument("--name", help="explicit sandbox name (default: derived from agent+path)")
    create_parser.add_argument("--image", help="base image override (default: the devenv shell image)")
    create_parser.add_argument("--kit", help="built-in agent kit to apply (overrides inference; e.g. opencode)")
    create_parser.add_argument(
        "--recreate",
        metavar="NAME",
        default=None,
        help="recreate a sandbox missing its read-only mount (security exception; consent-gated)",
    )
    create_parser.add_argument("--yes", "-y", action="store_true", help="consent to recreation")

    run_parser = sub.add_parser("run", help="create+attach a sandbox, or re-attach an existing one")
    run_parser.add_argument("target", help="AGENT (create+attach) or an existing sandbox name (re-attach)")
    run_parser.add_argument("path", nargs="?", help="workspace directory to mount (AGENT form)")
    run_parser.add_argument("--name", help="explicit sandbox name (AGENT form)")
    run_parser.add_argument("--image", help="base image override (AGENT form)")
    run_parser.add_argument("--kit", help="built-in agent kit to apply (overrides inference; e.g. opencode)")

    sub.add_parser("ls", help="list sandboxes")

    stop_parser = sub.add_parser("stop", help="stop a sandbox without removing it")
    stop_parser.add_argument("name", help="sandbox name")

    rm_parser = sub.add_parser("rm", help="remove a sandbox")
    rm_parser.add_argument("name", help="sandbox name")

    exec_parser = sub.add_parser("exec", help="run a command inside a sandbox")
    exec_parser.add_argument("name", help="sandbox name")
    exec_parser.add_argument(
        "cmd", nargs=argparse.REMAINDER, help="command to run (opaque after `--`)"
    )

    attach_parser = sub.add_parser("attach", help="attach to an existing sandbox (interactive)")
    attach_parser.add_argument("name", help="sandbox name")

    shell_parser = sub.add_parser("shell", help="open an interactive shell in a sandbox")
    shell_parser.add_argument("name", help="sandbox name")

    cp_parser = sub.add_parser("cp", help="copy files in or out of a sandbox (NAME:path syntax)")
    cp_parser.add_argument("src", help="source (host path or NAME:/guest/path)")
    cp_parser.add_argument("dst", help="destination (host path or NAME:/guest/path)")

    ports_parser = sub.add_parser("ports", help="list a sandbox's declared port mappings")
    ports_parser.add_argument("name", help="sandbox name")

    secret_parser = sub.add_parser(
        "secret", help="manage sandbox secrets (values are never on argv)"
    )
    secret_sub = secret_parser.add_subparsers(dest="secret_command", metavar="SUBCOMMAND")

    # The scope/service shape is ``[-g | SANDBOX] SERVICE`` (``-g``/``--global``
    # flag + one positional, or two positionals). argparse cannot express that
    # flag-vs-two-positional alternation unambiguously, so ``-g``/``--global`` is a
    # flag and the remaining tokens are captured with REMAINDER and disambiguated
    # by ``common._parse_secret_scope_service`` / ``common._parse_secret_ls_scope``.
    # ``--host``/``--env`` bind a custom endpoint; they are also accepted after
    # the positionals, where REMAINDER captures them (``common._split_host_env``).
    secret_set = secret_sub.add_parser("set", help="store a secret (value read from stdin)")
    secret_set.add_argument("--host", dest="hosts", action="append", help="custom endpoint host (repeatable)")
    secret_set.add_argument("--env", dest="env_name", help="env var the custom endpoint binds")
    common._secret_scope_args(secret_set, remainder_help="[-g | SANDBOX] SERVICE [--host HOST --env ENV]")

    secret_rm = secret_sub.add_parser("rm", help="remove a secret")
    common._secret_scope_args(secret_rm, remainder_help="[-g | SANDBOX] SERVICE")

    secret_ls = secret_sub.add_parser("ls", help="list secrets (scope/service/value-state, never values)")
    common._secret_scope_args(secret_ls, remainder_help="[-g | SANDBOX]")

    secret_has = secret_sub.add_parser("has", help="silent predicate: exit 0 if the secret is present")
    common._secret_scope_args(secret_has, remainder_help="[-g | SANDBOX] SERVICE")

    # The flags are registered so they parse before the first positional, and
    # re-read from REMAINDER after it (``commands.secret._parse_import``).
    secret_import = secret_sub.add_parser(
        "import", help="store known service tokens from the host environment in the acq secret store"
    )
    secret_import.add_argument("--all", action="store_true", help="import without prompting; never overwrite")
    secret_import.add_argument("-f", "--force", action="store_true", help="import without prompting; overwrite")
    secret_import.add_argument("--dry-run", action="store_true", help="show what would be imported; write nothing")
    secret_import.add_argument("--service", help="import only this service")
    common._secret_scope_args(secret_import, remainder_help="[SERVICE] [-g | SANDBOX]")

    kit_parser = sub.add_parser("kit", help="inspect kits and the trusted-source registry")
    kit_sub = kit_parser.add_subparsers(dest="kit_command", metavar="SUBCOMMAND")
    kit_sub.add_parser("list", help="show the pinned kit bundle and effective sets")
    kit_validate_p = kit_sub.add_parser("validate", help="validate a neutral hybrid/v1 kit")
    kit_validate_p.add_argument("path", help="kit directory or spec.yaml")
    kit_apply_p = kit_sub.add_parser("apply", help="apply a built-in agent kit to an existing sandbox")
    kit_apply_p.add_argument("name", help="sandbox name")
    kit_apply_p.add_argument("kitref", help="built-in agent kit name (e.g. opencode)")
    kit_check_p = kit_sub.add_parser("check", help="report if a sandbox is on the pinned bundle")
    kit_check_p.add_argument("name", help="sandbox name")
    kit_update_p = kit_sub.add_parser("update", help="refresh the built-in bundle in place (consented)")
    kit_update_p.add_argument("name", help="sandbox name")
    kit_update_p.add_argument("--yes", "-y", action="store_true", help="skip the confirmation prompt")

    kit_source_parser = sub.add_parser("kit-source", help="manage trusted kit repositories")
    kit_source_sub = kit_source_parser.add_subparsers(dest="kit_source_command", metavar="SUBCOMMAND")
    kit_source_add = kit_source_sub.add_parser("add", help="trust a kit repository at a pinned commit")
    kit_source_add.add_argument("repo", help="host/owner/repo (clone URL or git+https ref is normalized)")
    kit_source_add.add_argument("--ref", dest="ref", default=None, help="full immutable commit SHA (required)")
    kit_source_add.add_argument("--dir", dest="dir", default=None, help="kits subdirectory (default: the neutral acq-kits path)")
    kit_source_sub.add_parser("ls", help="trusted sources + the provider kits they publish")
    kit_source_rm = kit_source_sub.add_parser("rm", help="stop trusting a kit repository")
    kit_source_rm.add_argument("repo", help="host/owner/repo")

    # provider-credential: destination-pinned credential bindings (ADR-0038m
    # §provider-credential). The VALUE is never on argv — it flows on stdin only;
    # the binding (provider/key_env/hosts/source_layer) is recorded host-side.
    provider_credential_parser = sub.add_parser(
        "provider-credential", help="pin a provider kit's credential env var and destination host"
    )
    pc_sub = provider_credential_parser.add_subparsers(dest="provider_credential_command", metavar="SUBCOMMAND")
    pc_set = pc_sub.add_parser("set", help="pin a provider credential (value read from stdin)")
    pc_set.add_argument("provider", help="provider id (e.g. opencode-go)")
    pc_set.add_argument("key_env", help="credential env var (e.g. OPENCODE_GO_API_KEY)")
    pc_set.add_argument(
        "--host",
        action="append",
        default=[],
        help="destination host (repeatable, or comma-separated)",
    )
    pc_sub.add_parser("ls", help="list pinned provider bindings (provider/key_env/hosts/source_layer, never values)")
    pc_rm = pc_sub.add_parser("rm", help="remove a configured provider binding")
    pc_rm.add_argument("provider", help="provider id")

    # github-scope: per-sandbox GitHub token scoping (ADR-0013). The token is on
    # stdin only and backend-bound; the scope is recorded host-side.
    github_scope_parser = sub.add_parser(
        "github-scope", help="scope a GitHub token to a workspace's sandbox (least-privilege)"
    )
    github_scope_parser.add_argument("sandbox", help="sandbox name")
    github_scope_parser.add_argument("path", nargs="?", help="workspace path (default: recorded sandbox workspace)")

    # usai-rotate-api-key: rotate the stored USAi key (ADR-0012). New key on stdin
    # only; the old key is replaced only after the new one is confirmed.
    sub.add_parser("usai-rotate-api-key", help="rotate the USAi API key (new key on stdin)")

    return parser


def _backend_list_data(active_backend: str | None) -> dict:
    statuses = backends.detect_all()
    return {
        "active_backend": active_backend,
        "backends": [
            {
                "name": s.name,
                "installed": s.installed,
                "version": s.version,
            }
            for s in statuses
        ],
    }


def run_backend_list(emit_json: bool, active_backend: str | None, warnings: list[str] | None = None) -> int:
    """List the backends. A read-only report: a problem such as an unknown
    persisted backend is a warning (stderr, and ``data.warnings`` under
    ``--json``), never a failure."""
    data = _backend_list_data(active_backend)
    if warnings:
        data["warnings"] = warnings
        for warning in warnings:
            print(f"acq: warning: {warning}", file=sys.stderr)
    if emit_json:
        print(json.dumps(envelope.success("backend list", data)))
        return errors.EXIT_SUCCESS
    print("Installed backends:")
    for record in data["backends"]:
        if record["installed"]:
            ver = record["version"]
            line = f"  {record['name']}  v{ver}" if ver != "unknown" else f"  {record['name']}  {ver}"
        else:
            line = f"  {record['name']}  (not found)"
        if record["name"] == active_backend:
            line += " (active)"
        print(line)
    return errors.EXIT_SUCCESS


def run_backend_check(emit_json: bool, name: str) -> int:
    spec = backends.BACKENDS.get(name)
    if spec is None:
        return common._usage_failure(
            "backend check",
            f"unknown backend: {name!r} (expected sbx or msb)",
            emit_json,
        )
    problem = backends.check_version(spec)
    if problem is None:
        status = backends.detect(spec)
        data = {
            "name": spec.name,
            "installed": status.installed,
            "version": status.version,
        }
        if emit_json:
            print(json.dumps(envelope.success("backend check", data)))
        else:
            print(f"backend '{spec.name}': version {status.version} (supported)")
        return errors.EXIT_SUCCESS
    if emit_json:
        print(
            json.dumps(
                envelope.error(
                    "backend check",
                    problem.code,
                    problem.message,
                    remediation=problem.remediation,
                )
            )
        )
    else:
        print(f"acq: {problem.message}", file=sys.stderr)
        if problem.remediation:
            print(f"      {problem.remediation}", file=sys.stderr)
    return errors.EXIT_FAILURE


def run_backend_set(emit_json: bool, name: str) -> int:
    """Persist ``name`` as the default backend (Bash ``acq backend set``).

    Only the ``backend:`` key changes; every other config key is kept. The name
    was validated by the dispatch, so an invalid backend is never persisted.
    """
    previous = config.read_field("backend")
    try:
        path = config.write_field("backend", name)
    except OSError as exc:
        return _config_write_failure("backend set", exc, emit_json)
    data = {"backend": name, "previous": previous, "config_path": str(path)}
    if emit_json:
        print(json.dumps(envelope.success("backend set", data)))
    else:
        print(f"default backend set to '{name}' in {path}")
    return errors.EXIT_SUCCESS


def run_backend_unset(emit_json: bool) -> int:
    """Clear the persisted default backend so acq auto-detects (Bash ``acq backend
    unset``). Idempotent; other config keys are kept, and a config left holding
    nothing else is removed, as Bash does.
    """
    path = config.config_path()
    previous = config.read_field("backend")
    if previous is not None:
        try:
            config.write_field("backend", "")
            config.remove_if_only_marker()
        except OSError as exc:
            return _config_write_failure("backend unset", exc, emit_json)
    data = {"backend": None, "previous": previous, "cleared": previous is not None, "config_path": str(path)}
    if emit_json:
        print(json.dumps(envelope.success("backend unset", data)))
    elif previous is not None:
        print(f"cleared the persisted default backend ({path}); acq will auto-detect.")
    else:
        print("no persisted default backend was set; acq already auto-detects.")
    return errors.EXIT_SUCCESS


def _config_write_failure(command: str, exc: OSError, emit_json: bool) -> int:
    where = f" ({exc.filename})" if exc.filename else ""
    return common._operational_failure(
        command,
        errors.FAILURE,
        f"could not write {config.config_path()}: {exc.strerror or exc}{where}",
        "check the permissions of the acq config directory and file, then retry",
        emit_json,
    )


def _print_doctor_human(data: dict) -> None:
    print("acq: doctor")
    for check in data["checks"]:
        print(f"  [{check['status']:4}] {check['id']}: {check['message']}")
        remediation = check.get("remediation")
        if remediation:
            print(f"           {remediation}")
    print(f"overall: {data['status']}")


def run_doctor(emit_json: bool, name: str | None) -> int:
    # `acq doctor NAME` inspects a named sandbox's image contract, a
    # backend-provided capability (ADR-0040m `doctor`). No adapter is present in
    # this slice, so the request fails closed with exit 1 rather than inventing
    # a result.
    if name is not None:
        return common._operational_failure(
            "doctor",
            errors.UNSUPPORTED,
            f"cannot inspect sandbox {name!r}: no backend adapter is available",
            "backend adapters ship in a later slice; sandbox inspection is unavailable in this build",
            emit_json,
        )

    from . import doctor  # lazy: doctor is off-surface (see module docstring)

    data = doctor.doctor_data()
    if emit_json:
        print(json.dumps(envelope.success("doctor", data)))
        return errors.EXIT_SUCCESS
    _print_doctor_human(data)
    return errors.EXIT_SUCCESS


# ---------------------------------------------------------------------------
# Synchronized forward-migration pre-step (ADR-0041m).
# ---------------------------------------------------------------------------

def _is_mutating(parsed) -> bool:
    """True for a verb that mutates acq/sandbox state and therefore needs the
    migration pre-step first. Read-only/query verbs read leniently and never
    trigger migration (ADR-0041m: read-only diagnostics may report ``unknown``).
    """
    cmd = parsed.command
    if cmd in ("create", "run", "stop", "rm", "exec", "attach", "shell", "cp", "ports"):
        return True
    if cmd == "secret":
        return parsed.secret_command in ("set", "rm", "import")
    if cmd == "provider-credential":
        return parsed.provider_credential_command in ("set", "rm")
    if cmd in ("github-scope", "usai-rotate-api-key"):
        return True
    if cmd == "backend":
        return parsed.backend_command in ("set", "unset")
    if cmd == "kit":
        return parsed.kit_command in ("apply", "update")
    if cmd == "kit-source":
        return parsed.kit_source_command in ("add", "rm")
    return False


def _migration_pre_step(emit_json: bool, command: str) -> int | None:
    """Run the forward migration before a mutating verb; return an emitted exit
    code on refusal, else ``None`` (proceed).
    """
    try:
        migration.migrate_tree()
    except migration.MigrationError as exc:
        return common._operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    return None


def _command_label(parsed) -> str:
    """The full verb a handler reports in its envelope (``secret set``, not
    ``secret``), so a pre-step refusal names the same command."""
    sub = getattr(parsed, parsed.command.replace("-", "_") + "_command", None)
    return f"{parsed.command} {sub}" if sub else parsed.command


def _user_dirs_pre_step(emit_json: bool, command: str) -> int | None:
    """Refuse up front when the state root or config path cannot be resolved to a
    trustworthy absolute path (a relative ``ACQ_STATE_DIR``, or no absolute home
    to fall back to); return the emitted exit code, else ``None`` (proceed).

    Checked once here so every state-touching verb fails closed with the same
    actionable message instead of a traceback from deep inside a handler.
    """
    try:
        state.state_dir()
        config.config_path()
    except userdirs.UserDirError as exc:
        return common._operational_failure(
            command, errors.VALIDATION_FAILED, exc.message, exc.remediation, emit_json
        )
    return None


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)

    # Split at the first bare ``--`` so the exec/attach passthrough argv stays
    # opaque: acq's global flags (--json, --backend) are recognized only before
    # it (ADR-0038m §4 "exec argv after `--` is opaque").
    head = args
    tail: list[str] = []
    for i, token in enumerate(args):
        if token == "--":  # nosec B105 # argv separator
            head = args[:i]
            tail = args[i + 1 :]
            break

    emit_json = "--json" in head
    backend_override = _flag_value(head, "--backend")
    head = [a for a in head if a != "--json"]
    head = _strip_flag(head, "--backend")
    args = head if not tail else [*head, "--", *tail]

    # Announced verbatim backend passthrough (spec user story #9): an unknown
    # subcommand is forwarded to the active backend binary with a stderr notice,
    # preserving its exit status. Detected before argparse, which would otherwise
    # treat the unknown verb as a usage error.
    if args and not args[0].startswith("-") and args[0] not in KNOWN_COMMANDS:
        return session._passthrough(args, backend_override, emit_json)

    parser = build_parser()
    try:
        parsed = parser.parse_args(args)
    except UsageError as exc:
        return common._usage_failure(None, str(exc), emit_json)

    try:
        return _dispatch(parser, parsed, emit_json, backend_override)
    except common._ADAPTER_ERRORS as exc:
        # The command boundary (ADR-0038m §2): an adapter error a handler did not
        # map itself (e.g. the backend CLI vanished after detection, or detection
        # was forced) still leaves as a stable code + envelope, never a traceback.
        return _boundary_failure(parsed, exc.code, exc.message, exc.remediation, emit_json)
    except BrokenPipeError:
        raise  # stdout is gone; there is nowhere to write an envelope
    except OSError as exc:
        # Host I/O failures (an unwritable state directory, a full disk) likewise
        # keep the contract. The message carries the OS reason and path only.
        where = f" ({exc.filename})" if exc.filename else ""
        return _boundary_failure(
            parsed,
            errors.FAILURE,
            f"could not complete '{_boundary_label(parsed)}': {exc.strerror or exc}{where}",
            "check permissions and free space for the acq state and config directories, then retry",
            emit_json,
        )


def _boundary_failure(parsed, code: str, message: str, remediation: str | None, emit_json: bool) -> int:
    """Emit a failure caught at the command boundary for ``parsed``'s verb.

    ``secret has`` is a silent predicate whose stdout stays empty even under
    ``--json``, so its failure goes to stderr only (exit 1, never "absent").
    """
    label = _boundary_label(parsed)
    if label == "secret has":
        emit_json = False
    return common._operational_failure(label, code, message, remediation, emit_json)


def _boundary_label(parsed) -> str:
    return _command_label(parsed) if parsed.command else "acq"


def _dispatch(parser: _Parser, parsed, emit_json: bool, backend_override: str | None) -> int:
    """Route a parsed command line to its handler; ``main`` owns the error boundary."""
    if parsed.version or parsed.command == "version":
        # The `version` command lives in version_info.py (data + output), imported
        # lazily so a break there affects only `acq version`, never the oracle's
        # contract commands (ADR-0044m).
        from . import version_info

        return version_info.run_version(emit_json)

    if parsed.command == "backend":
        if backend_override is not None and backend_override not in backends.BACKENDS:
            return common._usage_failure(
                "backend",
                f"unknown backend: {backend_override!r} (expected sbx or msb)",
                emit_json,
            )
        if parsed.backend_command == "list":
            invalid = common._invalid_persisted_backend(backend_override)
            warnings = [common._invalid_persisted_backend_message(invalid)] if invalid is not None else None
            return run_backend_list(emit_json, common._resolve_active_backend(backend_override), warnings)
        if parsed.backend_command == "check":
            return run_backend_check(emit_json, parsed.name)
        if parsed.backend_command == "set" and parsed.name not in backends.BACKENDS:
            # Refused before anything is written: an invalid backend is never
            # persisted (ADR-0038m).
            return common._usage_failure(
                "backend set",
                f"unknown backend: {parsed.name!r} (expected sbx or msb)",
                emit_json,
            )
        if parsed.backend_command not in ("set", "unset"):
            return common._usage_failure(
                "backend",
                "backend requires a subcommand: list | check | set | unset",
                emit_json,
            )
        # set/unset write config.yaml, so they take the user-dirs and migration
        # pre-steps below like every other mutating verb.

    if parsed.command == "doctor":
        return run_doctor(emit_json, parsed.name)

    if parsed.command not in ("help", None):
        label = _command_label(parsed)
        # `secret has` is a silent predicate: its refusal goes to stderr only.
        dirs_check = _user_dirs_pre_step(emit_json and label != "secret has", label)
        if dirs_check is not None:
            return dirs_check

    if _is_mutating(parsed):
        pre_step = _migration_pre_step(emit_json, _command_label(parsed))
        if pre_step is not None:
            return pre_step

    if parsed.command == "backend":
        if parsed.backend_command == "set":
            return run_backend_set(emit_json, parsed.name)
        return run_backend_unset(emit_json)

    if parsed.command == "configure":
        if backend_override is not None and backend_override not in backends.BACKENDS:
            return common._usage_failure(
                "configure", f"unknown backend: {backend_override!r} (expected sbx or msb)", emit_json
            )
        # Only the interactive form writes config.yaml, and it takes the
        # migration pre-step just before its first write, so a cancelled run
        # leaves a legacy config untouched.
        return configure.run_configure(
            emit_json, backend_override, lambda: _migration_pre_step(emit_json, "configure")
        )

    if parsed.command in ("create", "run", "ls", "stop", "rm", "exec", "attach", "shell", "cp", "ports"):
        _backend, exit_code = common._resolve_backend_for_lifecycle(backend_override, emit_json, parsed.command)
        if exit_code is not None:
            return exit_code
        assert _backend is not None  # nosec B101 # resolver contract; narrows the type for mypy
        if parsed.command == "create":
            return lifecycle.run_create(parsed, emit_json, _backend)
        if parsed.command == "run":
            return lifecycle.run_run(parsed, emit_json, _backend)
        if parsed.command == "ls":
            return lifecycle.run_ls(emit_json, _backend)
        if parsed.command == "stop":
            return lifecycle.run_stop(parsed, emit_json, _backend)
        if parsed.command == "rm":
            return lifecycle.run_rm(parsed, emit_json, _backend)
        if parsed.command == "exec":
            return session.run_exec(parsed, emit_json, _backend)
        if parsed.command == "attach":
            return session.run_attach(parsed, emit_json, _backend)
        if parsed.command == "shell":
            return session.run_shell(parsed, emit_json, _backend)
        if parsed.command == "cp":
            return session.run_cp(parsed, emit_json, _backend)
        if parsed.command == "ports":
            return session.run_ports(parsed, emit_json, _backend)

    if parsed.command == "secret":
        subcmd = parsed.secret_command
        if subcmd is None:
            return common._usage_failure("secret", "secret requires a subcommand: set | rm | ls | has | import", emit_json)
        command = f"secret {subcmd}"
        # `secret has` is a silent predicate: it never emits a stdout body, so it
        # resolves the backend itself with emit_json=False (failures -> stderr).
        if subcmd == "has":
            return secret.run_secret_has(parsed, backend_override)
        # `secret import` writes only the acq store, so it needs no backend.
        if subcmd == "import":
            return secret.run_secret_import(parsed, emit_json)
        # argparse already refused an unknown choice, so subcmd is set|rm|ls here.
        _backend, exit_code = common._resolve_backend_for_mutation(
            backend_override, emit_json, command, domain="secret management"
        )
        if exit_code is not None:
            return exit_code
        assert _backend is not None  # nosec B101 # resolver contract; narrows the type for mypy
        if subcmd == "set":
            return secret.run_secret_set(parsed, emit_json, _backend)
        if subcmd == "rm":
            return secret.run_secret_rm(parsed, emit_json, _backend)
        return secret.run_secret_ls(parsed, emit_json, _backend)

    if parsed.command == "kit":
        subcmd = parsed.kit_command
        if subcmd is None:
            return common._usage_failure("kit", "kit requires a subcommand: list | validate | apply | check | update", emit_json)
        if subcmd == "list":
            return kit.run_kit_list(emit_json)
        if subcmd == "validate":
            return kit.run_kit_validate(parsed, emit_json)
        if subcmd == "apply":
            return kit.run_kit_apply(parsed, emit_json, backend_override)
        if subcmd == "check":
            return kit.run_kit_check(parsed, emit_json, backend_override)
        if subcmd == "update":
            return kit.run_kit_update(parsed, emit_json, backend_override)
        return common._usage_failure(f"kit {subcmd}", f"unknown kit subcommand: {subcmd}", emit_json)

    if parsed.command == "kit-source":
        subcmd = parsed.kit_source_command
        if subcmd is None:
            return common._usage_failure("kit-source", "kit-source requires a subcommand: add | ls | rm", emit_json)
        if subcmd == "add":
            return kit.run_kit_source_add(parsed, emit_json)
        if subcmd == "ls":
            return kit.run_kit_source_ls(emit_json)
        if subcmd == "rm":
            return kit.run_kit_source_rm(parsed, emit_json, backend_override)
        return common._usage_failure(f"kit-source {subcmd}", f"unknown kit-source subcommand: {subcmd}", emit_json)

    if parsed.command == "provider-credential":
        subcmd = parsed.provider_credential_command
        if subcmd is None:
            return common._usage_failure("provider-credential", "provider-credential requires a subcommand: set | ls | rm", emit_json)
        # ls/rm read and mutate host-side binding records only; only `set` moves a
        # value across the backend boundary and therefore needs a backend.
        if subcmd == "ls":
            return creds.run_provider_credential_ls(emit_json)
        if subcmd == "rm":
            return creds.run_provider_credential_rm(parsed, emit_json)
        _backend, exit_code = common._resolve_backend_for_mutation(
            backend_override, emit_json, "provider-credential set", domain="provider credentials",
            capability="provider-credential-set",
        )
        if exit_code is not None:
            return exit_code
        assert _backend is not None  # nosec B101 # resolver contract; narrows the type for mypy
        return creds.run_provider_credential_set(parsed, emit_json, _backend)

    if parsed.command == "github-scope":
        _backend, exit_code = common._resolve_backend_for_mutation(
            backend_override, emit_json, "github-scope", domain="provider credentials"
        )
        if exit_code is not None:
            return exit_code
        assert _backend is not None  # nosec B101 # resolver contract; narrows the type for mypy
        return creds.run_github_scope(parsed, emit_json, _backend)

    if parsed.command == "usai-rotate-api-key":
        _backend, exit_code = common._resolve_backend_for_mutation(
            backend_override, emit_json, "usai-rotate-api-key", domain="provider credentials"
        )
        if exit_code is not None:
            return exit_code
        assert _backend is not None  # nosec B101 # resolver contract; narrows the type for mypy
        return creds.run_usai_rotate_api_key(emit_json, _backend)

    if parsed.command == "help" or parsed.command is None:
        parser.print_help()
        return errors.EXIT_SUCCESS

    return common._usage_failure(parsed.command, f"unknown command: {parsed.command}", emit_json)
