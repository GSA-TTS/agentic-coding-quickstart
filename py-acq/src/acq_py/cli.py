"""CLI entrypoint for acq v1: the argparse surface and the command dispatch.

The highest seam is the subprocess boundary (ADR-0038m section 1): exit codes
0/1/2 and the structured-output envelope (``--json``) are the contract. This
module owns that surface — ``build_parser`` and ``main`` — plus the two verbs
whose handlers are small enough to live beside it (``backend list``/``check``
and ``doctor``). Every other handler lives in :mod:`acq_py.commands`:

    commands/common.py     the adapter seam, failure envelopes, backend and
                           workspace resolution, secret-scope parsing
    commands/lifecycle.py  create, run, create --recreate, ls, stop, rm
    commands/session.py    exec, attach, shell, cp, ports, verbatim passthrough
    commands/secret.py     secret set/rm/ls/has
    commands/creds.py      provider-credential, github-scope, usai-rotate-api-key
    commands/kit.py        kit list/validate/apply/check/update, kit source

The names those modules own are re-exported below, so ``cli.<name>`` keeps
resolving for callers and for the Tier-2 tests that patch them.

Output contract:
    * human output -> stdout, diagnostics -> stderr (no ``--json``)
    * JSON envelope -> stdout, diagnostics -> stderr (``--json``)
    * exit 0 success, 2 usage error, 1 operational failure
"""

from __future__ import annotations

import argparse
import json
import sys

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
from . import backends, envelope, errors, migration, msb
from .commands import common, creds, kit, lifecycle, secret, session

# Both adapters raise an error carrying the same (code, message, remediation)
# contract; catch this tuple uniformly at the seam.


# Agent tokens accepted by acq dispatch (mirrors acq.backends/agents.sh). Kept in
# the CLI because it owns the create-vs-reattach decision for ``run``.

# Every subcommand acq owns. An argv token that is not one of these (and is not a
# flag) is treated as an unknown verb and forwarded verbatim to the active
# backend (announced passthrough, spec user story #9 / ADR-0038m §1).
KNOWN_COMMANDS = frozenset(
    "version doctor help backend create run ls stop rm exec attach shell cp ports "
    "secret kit kit-source provider-credential github-scope usai-rotate-api-key".split()
)

# Guest-side workspace a session starts in when no host record supplies one
# (mirrors the legacy ``_acq_msb_workspace_for`` default, ADR-0011).

# The default base image (ADR-0030): a generic, agent-less devenv-enabled base for
# EVERY agent. Agent harness installation is deferred to kits (starting with
# opencode), so the base image no longer differs per agent; an explicit
# ``--image``/``ACQ_IMAGE``/``ACQ_MSB_IMAGE`` override is the only way to change it
# (ADR-0022 precedence). The devenv base is agent-less: the agent binary is
# installed by the pinned opencode kit at create time (see ``lifecycle._apply_agent_kit``).
#
# TODO(quarterly): the digest below is a real, reproducible pin — re-reviewed on
# the quarterly cadence (ADR-0030). It is sourced from the devenv image VERSION /
# Dockerfile pins in ``integrations/isolation/images/devenv/`` (devenv-shell:2.1.0)
# and the upstream ``acq.backends/agents.sh`` default.


# The command handlers live in ``acq_py.commands`` (see that package); this module
# owns the argparse surface and the dispatch below. These re-exports keep the
# historical ``cli.<name>`` addresses working for the Tier-2 tests, which patch and
# call them directly, so the split stays invisible to every existing caller. The
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
    def error(self, message: str) -> None:
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
        "backend", help="detect and inspect the sandbox backends (sbx, msb)"
    )
    backend_sub = backend_parser.add_subparsers(dest="backend_command", metavar="SUBCOMMAND")
    backend_sub.add_parser("list", help="list detected backends")
    check_parser = backend_sub.add_parser("check", help="fail closed on an unsupported backend version")
    check_parser.add_argument("name", help="backend name (sbx | msb)")

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
    secret_set = secret_sub.add_parser("set", help="store a secret (value read from stdin)")
    common._secret_scope_args(secret_set, remainder_help="[-g | SANDBOX] SERVICE")

    secret_rm = secret_sub.add_parser("rm", help="remove a secret")
    common._secret_scope_args(secret_rm, remainder_help="[-g | SANDBOX] SERVICE")

    secret_ls = secret_sub.add_parser("ls", help="list secrets (scope/service/value-state, never values)")
    common._secret_scope_args(secret_ls, remainder_help="[-g | SANDBOX]")

    secret_has = secret_sub.add_parser("has", help="silent predicate: exit 0 if the secret is present")
    common._secret_scope_args(secret_has, remainder_help="[-g | SANDBOX] SERVICE")

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


def run_backend_list(emit_json: bool, active_backend: str | None) -> int:
    data = _backend_list_data(active_backend)
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
# MSB lifecycle verbs (create / run / stop / rm / ls).
# ---------------------------------------------------------------------------


# Substrate-contract gap tokens (ADR-0030 "bring-your-own image contract"). A kit
# installs into single-user Nix + devenv + direnv at the pinned /nix store, run by
# the agent user. Addressable gaps are provisioned in-guest; unaddressable gaps
# fail closed.

# Substrate-contract seam (internal test seam, never a secret, never written to
# output). ``ACQ_SUBSTRATE_STATE`` is a JSON object mapping an image to its
# substrate state: ``"ok"`` or a list of gap tokens. A ``"*"`` key applies to any
# overridden image not otherwise named. Absent means unknown -> a kit cannot be
# applied to an unverified image (fail closed). The default devenv base is ``"ok"``
# by construction and never consults the seam.


# ---------------------------------------------------------------------------
# exec / attach / shell / cp / ports (ADR-0040m capabilities; ADR-0038m §1
# child/backend status preservation).
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# secret set / rm / ls / has (ADR-0040m `secret-write/rm`, `secret-list`;
# ADR-0038m §secret ls/has required data). The paramount rule is that no secret
# VALUE ever appears in argv, logs, fixtures, or output: scope/service are
# non-secret identifiers on argv, while the value flows on stdin only.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# provider-credential set / ls / rm (ADR-0038m §provider-credential), and the
# github-scope / usai-rotate-api-key verbs (ADR-0012, ADR-0013). The paramount
# rule is unchanged from `secret`: a credential VALUE never appears in argv,
# logs, or output — it flows on stdin only and is forwarded to the backend on the
# child's stdin. The binding / scope is host-authoritative state (ADR-0041m).
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# kit list / validate / apply / check / update, and kit-source add / ls / rm
# (ADR-0038m §kit; ADR-0016 provenance; trusted-source policy; ADR-0030
# agent-kit install). ``kit apply`` is the ADR-0030 devenv-base + agent-install
# path: it applies a built-in agent kit in-guest via the backend ``kit-apply``
# capability, idempotently.
# ---------------------------------------------------------------------------


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
        return parsed.secret_command in ("set", "rm")
    if cmd == "provider-credential":
        return parsed.provider_credential_command in ("set", "rm")
    if cmd in ("github-scope", "usai-rotate-api-key"):
        return True
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


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)

    # Split at the first bare ``--`` so the exec/attach passthrough argv stays
    # opaque: acq's global flags (--json, --backend) are recognized only before
    # it (ADR-0038m §4 "exec argv after `--` is opaque").
    head = args
    tail: list[str] = []
    for i, token in enumerate(args):
        if token == "--":
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
            return run_backend_list(emit_json, common._resolve_active_backend(backend_override))
        if parsed.backend_command == "check":
            return run_backend_check(emit_json, parsed.name)
        return common._usage_failure(
            "backend",
            "backend requires a subcommand: list | check",
            emit_json,
        )

    if parsed.command == "doctor":
        return run_doctor(emit_json, parsed.name)

    if _is_mutating(parsed):
        pre_step = _migration_pre_step(emit_json, parsed.command)
        if pre_step is not None:
            return pre_step

    if parsed.command in ("create", "run", "ls", "stop", "rm", "exec", "attach", "shell", "cp", "ports"):
        _backend, exit_code = common._resolve_backend_for_lifecycle(backend_override, emit_json, parsed.command)
        if exit_code is not None:
            return exit_code
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
            return common._usage_failure("secret", "secret requires a subcommand: set | rm | ls | has", emit_json)
        command = f"secret {subcmd}"
        # `secret has` is a silent predicate: it never emits a stdout body, so it
        # resolves the backend itself with emit_json=False (failures -> stderr).
        if subcmd == "has":
            return secret.run_secret_has(parsed, backend_override)
        # argparse already refused an unknown choice, so subcmd is set|rm|ls here.
        _backend, exit_code = common._resolve_backend_for_mutation(
            backend_override, emit_json, command, domain="secret management"
        )
        if exit_code is not None:
            return exit_code
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
        return creds.run_provider_credential_set(parsed, emit_json, _backend)

    if parsed.command == "github-scope":
        _backend, exit_code = common._resolve_backend_for_mutation(
            backend_override, emit_json, "github-scope", domain="provider credentials"
        )
        if exit_code is not None:
            return exit_code
        return creds.run_github_scope(parsed, emit_json, _backend)

    if parsed.command == "usai-rotate-api-key":
        _backend, exit_code = common._resolve_backend_for_mutation(
            backend_override, emit_json, "usai-rotate-api-key", domain="provider credentials"
        )
        if exit_code is not None:
            return exit_code
        return creds.run_usai_rotate_api_key(emit_json, _backend)

    if parsed.command == "help" or parsed.command is None:
        parser.print_help()
        return errors.EXIT_SUCCESS

    return common._usage_failure(parsed.command, f"unknown command: {parsed.command}", emit_json)
