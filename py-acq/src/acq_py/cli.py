"""CLI entrypoint for the acq v1 Python skeleton.

The highest seam is the subprocess boundary (ADR-0038m section 1): exit codes
0/1/2 and the structured-output envelope (``--json``) are the contract. The
foundation slice implements ``version`` and ``doctor`` plus the ``--json`` flag
end to end; the backend-detection slice adds ``backend list`` and
``backend check`` (the read side of the adapter seam, ADR-0040m). The MSB
lifecycle slice adds ``create``, ``run``, ``stop``, ``rm``, and ``ls`` through the
subprocess-calling MSB adapter. The exec/passthrough slice adds ``exec``,
``attach``, ``shell``, ``cp``, ``ports``, and announced verbatim passthrough. The
secret slice adds ``secret set``/``rm``/``ls``/``has`` (value on stdin only, never
a value in output). The rest of the command surface arrives with later slices.

Output contract:
    * human output -> stdout, diagnostics -> stderr (no ``--json``)
    * JSON envelope -> stdout, diagnostics -> stderr (``--json``)
    * exit 0 success, 2 usage error, 1 operational failure
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

from . import (
    backends,
    doctor,
    envelope,
    errors,
    kits,
    migration,
    msb,
    provider_creds,
    sbx,
    security,
    state,
    version_info,
)

# Both adapters raise an error carrying the same (code, message, remediation)
# contract; catch this tuple uniformly at the seam.
_ADAPTER_ERRORS = (msb.MsbError, sbx.SbxError)


def _adapter(backend: str):
    """Resolve the adapter module for a backend name (``"sbx"`` else ``msb``)."""
    return sbx if backend == "sbx" else msb


def _supports(backend: str, capability: str) -> bool:
    """Consult the adapter's declared capability record (ADR-0040m).

    A capability the adapter declares ``unsupported`` fails closed; an adapter
    without a ``capability_record`` (the pre-record msb adapter) supports whatever
    it implements. The orchestrator reads the record once per decision, so the
    fail-closed ``unsupported_capability`` behavior is derived from the record
    rather than hardcoded per verb.
    """
    record_fn = getattr(_adapter(backend), "capability_record", None)
    if record_fn is None:
        return True
    return record_fn().get("capabilities", {}).get(capability) != "unsupported"

# Agent tokens accepted by acq dispatch (mirrors acq.backends/agents.sh). Kept in
# the CLI because it owns the create-vs-reattach decision for ``run``.
KNOWN_AGENTS = frozenset(
    "claude codex copilot cursor docker-agent droid gemini kiro opencode shell".split()
)

# Every subcommand acq owns. An argv token that is not one of these (and is not a
# flag) is treated as an unknown verb and forwarded verbatim to the active
# backend (announced passthrough, spec user story #9 / ADR-0038m §1).
KNOWN_COMMANDS = frozenset(
    "version doctor help backend create run ls stop rm exec attach shell cp ports "
    "secret kit kit-source provider-credential github-scope usai-rotate-api-key".split()
)

# Guest-side workspace a session starts in when no host record supplies one
# (mirrors the legacy ``_acq_msb_workspace_for`` default, ADR-0011).
DEFAULT_GUEST_WORKSPACE = "/home/agent"

# The default base image (ADR-0030): a generic, agent-less devenv-enabled base for
# EVERY agent. Agent harness installation is deferred to kits (starting with
# opencode), so the base image no longer differs per agent; an explicit
# ``--image``/``ACQ_IMAGE``/``ACQ_MSB_IMAGE`` override is the only way to change it
# (ADR-0022 precedence). The devenv base is agent-less: the agent binary is
# installed by the pinned opencode kit at create time (see ``_apply_agent_kit``).
#
# TODO(quarterly): the digest below is a real, reproducible pin — re-reviewed on
# the quarterly cadence (ADR-0030). It is sourced from the devenv image VERSION /
# Dockerfile pins in ``integrations/isolation/images/devenv/`` (devenv-shell:2.1.0)
# and the upstream ``acq.backends/agents.sh`` default.
OPENCODE_DEVENV_IMAGE = (
    "ghcr.io/gsa-tts/agentic-coding-patterns/devenv-shell@"
    "sha256:0b5f4cc95c8fa7dd7f3ffd02b56e63d0caf9b151421ff6ea3cb34b2139e3966c"
)


def _default_image_for_agent(agent: str) -> str:
    """The default base image: the pinned devenv shell image for every agent.

    The ``agent`` argument is retained for signature compatibility with the
    per-agent mapping it replaced, but it no longer selects a different image.
    """
    return OPENCODE_DEVENV_IMAGE


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
    # by ``_parse_secret_scope_service`` / ``_parse_secret_ls_scope``.
    secret_set = secret_sub.add_parser("set", help="store a secret (value read from stdin)")
    _secret_scope_args(secret_set, remainder_help="[-g | SANDBOX] SERVICE")

    secret_rm = secret_sub.add_parser("rm", help="remove a secret")
    _secret_scope_args(secret_rm, remainder_help="[-g | SANDBOX] SERVICE")

    secret_ls = secret_sub.add_parser("ls", help="list secrets (scope/service/value-state, never values)")
    _secret_scope_args(secret_ls, remainder_help="[-g | SANDBOX]")

    secret_has = secret_sub.add_parser("has", help="silent predicate: exit 0 if the secret is present")
    _secret_scope_args(secret_has, remainder_help="[-g | SANDBOX] SERVICE")

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


def _secret_scope_args(parser: argparse.ArgumentParser, *, remainder_help: str) -> None:
    """Add the shared ``-g/--global`` flag + REMAINDER scope/service tokens."""
    parser.add_argument("-g", "--global", dest="global_scope", action="store_true", help="global scope")
    parser.add_argument("args", nargs=argparse.REMAINDER, help=remainder_help)


def _parse_secret_scope_service(global_scope: bool, tokens: list[str]) -> tuple[str | None, str | None]:
    """Parse ``[-g | --global | SANDBOX] SERVICE`` -> ``(scope, service)``.

    ``scope`` is ``"global"`` for the flag form or the sandbox name for the
    positional form. Returns ``(None, None)`` for any other shape so the caller
    emits a usage error. Scope and service are non-secret identifiers only.
    """
    if global_scope:
        if len(tokens) != 1:
            return None, None
        return "global", tokens[0]
    if len(tokens) != 2:
        return None, None
    scope, service = tokens
    if scope.startswith("-"):
        return None, None
    return scope, service


def _parse_secret_ls_scope(global_scope: bool, tokens: list[str]) -> tuple[str | None, bool]:
    """Parse the optional ``secret ls`` scope filter -> ``(scope, ok)``.

    ``ok`` is False for a malformed filter (extra tokens, or an unknown flag),
    in which case the caller emits a usage error.
    """
    if global_scope:
        return ("global", True) if not tokens else (None, False)
    if not tokens:
        return None, True
    if len(tokens) > 1:
        return None, False
    token = tokens[0]
    if token.startswith("-"):
        return None, False
    return token, True


def _usage_failure(command: str | None, message: str, emit_json: bool) -> int:
    if emit_json:
        doc = envelope.error(
            command or "acq",
            errors.USAGE,
            message,
            remediation="run 'acq --help' for usage",
        )
        print(json.dumps(doc))
    else:
        print(f"acq: {message}", file=sys.stderr)
        print("run 'acq --help' for usage", file=sys.stderr)
    return errors.EXIT_USAGE


def _operational_failure(
    command: str,
    code: str,
    message: str,
    remediation: str | None,
    emit_json: bool,
    exit_code: int = errors.EXIT_FAILURE,
) -> int:
    """Emit an operational failure (exit 1) with a stable error code.

    Distinct from a usage error (exit 2): the command was well-formed but could
    not be carried out. The JSON form puts the failure envelope on stdout; the
    human form writes diagnostics to stderr. ``exit_code`` defaults to 1 and is
    overridden only where the contract requires preserving a backend's own status
    (e.g. ``cp`` forwarding ``msb copy``'s exit, ADR-0038m §1).
    """
    if emit_json:
        doc = envelope.error(command, code, message, remediation=remediation)
        print(json.dumps(doc))
    else:
        print(f"acq: {message}", file=sys.stderr)
        if remediation:
            print(remediation, file=sys.stderr)
    return exit_code


def _resolve_active_backend(explicit: str | None) -> str | None:
    """Resolve the active backend for read-only reporting.

    Precedence: the ``--backend`` flag, then the ``ACQ_BACKEND`` environment
    variable, then (in a later slice) config persistence via ``backend set``,
    then the auto-detect default. An invalid flag value is a usage error
    (handled by the caller); an invalid environment value is dropped (ADR-0038m
    "drop invalid persisted backends").

    Auto-detect default arms:

        * exactly one backend installed -> that backend;
        * sbx and msb both installed -> msb;
        * none installed -> ``None``;
        * (future) two or more installed and none is msb -> prompt the user and
          persist the answer via ``backend set``.

    The last arm cannot arise in v1 (only sbx and msb exist), so it is
    documented but not implemented here.
    """
    if explicit is not None:
        return explicit
    env_backend = os.environ.get("ACQ_BACKEND")
    if env_backend in backends.BACKENDS:
        return env_backend
    installed = [s.name for s in backends.detect_all() if s.installed]
    if len(installed) == 1:
        return installed[0]
    if len(installed) > 1:
        return "msb"
    return None


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
        return _usage_failure(
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
        return _operational_failure(
            "doctor",
            errors.UNSUPPORTED,
            f"cannot inspect sandbox {name!r}: no backend adapter is available",
            "backend adapters ship in a later slice; sandbox inspection is unavailable in this build",
            emit_json,
        )

    data = doctor.doctor_data()
    if emit_json:
        print(json.dumps(envelope.success("doctor", data)))
        return errors.EXIT_SUCCESS
    _print_doctor_human(data)
    return errors.EXIT_SUCCESS


# ---------------------------------------------------------------------------
# MSB lifecycle verbs (create / run / stop / rm / ls).
# ---------------------------------------------------------------------------

def _slugify(token: str) -> str:
    """Normalize a token into a sandbox-name slug (mirrors acq.backends slugify).

    Only ASCII ``a-z0-9`` survive; runs of anything else collapse to one hyphen,
    matching the legacy ``tr + sed`` transform.
    """
    out: list[str] = []
    prev_dash = False
    for ch in token.lower():
        if ("a" <= ch <= "z") or ("0" <= ch <= "9"):
            out.append(ch)
            prev_dash = False
        elif not prev_dash:
            out.append("-")
            prev_dash = True
    return "".join(out).strip("-")


def _derive_name(agent: str, workspace: str) -> str:
    base = os.path.basename(workspace.rstrip("/\\")) or "workspace"
    return f"{_slugify(agent)}-{_slugify(base)}"


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
    return _default_image_for_agent(agent)


def _resolve_image_for_kit(
    image_flag: str | None, agent: str, kit_name: str | None, command: str, emit_json: bool
) -> tuple[str | None, list[list[str]], int | None]:
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


# Substrate-contract gap tokens (ADR-0030 "bring-your-own image contract"). A kit
# installs into single-user Nix + devenv + direnv at the pinned /nix store, run by
# the agent user. Addressable gaps are provisioned in-guest; unaddressable gaps
# fail closed.
_ADDRESSABLE_SUBSTRATE_GAPS = frozenset({"nix", "devenv", "direnv", "agent-user"})
_UNADDRESSABLE_SUBSTRATE_GAPS = frozenset({"non-linux", "read-only-filesystem"})

# Substrate-contract seam (internal test seam, never a secret, never written to
# output). ``ACQ_SUBSTRATE_STATE`` is a JSON object mapping an image to its
# substrate state: ``"ok"`` or a list of gap tokens. A ``"*"`` key applies to any
# overridden image not otherwise named. Absent means unknown -> a kit cannot be
# applied to an unverified image (fail closed). The default devenv base is ``"ok"``
# by construction and never consults the seam.
SUBSTRATE_STATE_ENV = "ACQ_SUBSTRATE_STATE"


def _substrate_gaps(image: str) -> list[str] | None:
    """The substrate gap list for an image (empty == satisfied), or ``None`` (unknown).

    The default devenv base satisfies the contract by construction. An overridden
    image is verified against the deterministic seam; without the seam its state is
    unknown and a kit cannot be applied (fail closed, ADR-0041m).
    """
    if image == OPENCODE_DEVENV_IMAGE:
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


def _substrate_provision_steps(gaps: list[str]) -> list[list[str]]:
    """In-guest bootstrap steps for addressable substrate gaps (ordered).

    TODO(quarterly): these argv are PLACEHOLDER bootstrap steps — the quarterly
    cadence re-sources the pinned single-user Nix / devenv install from the control
    plane. They are data, never executed here (forwarded to the backend seam), and
    carry no credential.
    """
    steps = {
        "nix": ["install-nix", "--single-user"],
        "devenv": ["nix", "profile", "install", "devenv"],
        "direnv": ["nix", "profile", "install", "direnv"],
        "agent-user": ["useradd", "-m", "agent"],
    }
    return [list(steps[gap]) for gap in gaps if gap in steps]


def _substrate_plan(
    image: str, kit_name: str | None, command: str, emit_json: bool
) -> tuple[list[list[str]], int | None]:
    """Plan the substrate contract for a kit on an image; returns ``(steps, exit_code)``.

    A ``None`` kit needs no substrate. Otherwise the image's gaps are classified:
    unknown or unaddressable gaps fail closed; addressable gaps yield bootstrap
    steps to run in-guest (the default devenv base has none).
    """
    if kit_name is None:
        return [], None
    gaps = _substrate_gaps(image)
    if gaps is None:
        return [], _operational_failure(
            command,
            errors.VALIDATION_FAILED,
            f"cannot verify the substrate contract for image {image!r}; kit '{kit_name}' needs single-user Nix + devenv + direnv",
            "use the default devenv base, or verify the image satisfies the substrate contract (ADR-0030)",
            emit_json,
        )
    unaddressable = [g for g in gaps if g in _UNADDRESSABLE_SUBSTRATE_GAPS]
    if unaddressable:
        return [], _operational_failure(
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
        return None, _usage_failure(
            command,
            f"unknown kit: {kit_flag!r} (built-in agent kits: {', '.join(kits.AGENT_KIT_NAMES)})",
            emit_json,
        )
    return kit_flag, None


def _apply_agent_kit(
    backend: str, name: str, kit_name: str, provision_steps: list[list[str]], command: str, emit_json: bool
) -> int | None:
    """Apply a built-in agent kit to a sandbox (create-time install, ADR-0030).

    Idempotent and host-authoritative: a sandbox already on ``kit_name`` is a
    no-op (no duplicate install), tracked by the applied-kit record (ADR-0041m).
    Addressable substrate gaps are provisioned in-guest (bootstrap single-user Nix
    + devenv + direnv + the agent user) before the agent install. acq never
    executes kit code on the host, and the install argv carries no credential
    (ADR-0038m §46, §7). Returns an emitted exit code on failure, else ``None``.
    """
    if not _supports(backend, "kit-apply"):
        return _operational_failure(
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
            _adapter(backend).provision_substrate(name, provision_steps)
        _adapter(backend).kit_apply(name, kit_name, kits.agent_kit_install(kit_name))
    except _ADAPTER_ERRORS as exc:
        return _operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    kits.kit_applied_write(backend, name, kit_name, kits.agent_kit_entrypoint(kit_name))
    return None


def _discard_half_created(backend: str, name: str) -> None:
    """Remove a just-created sandbox (and its record) after a failed kit apply.

    Mirrors the exec-ready timeout cleanup in ``_create_sandbox``: a sandbox
    created but left without its agent binary must not strand.
    """
    try:
        _adapter(backend).remove(name)
    except _ADAPTER_ERRORS:
        pass
    state.record_remove(backend, name)


def _launch_token(backend: str, name: str, agent: str) -> str:
    """Resolve the launch command: a recorded kit entrypoint wins over the agent name.

    A future kit may declare an entrypoint that differs from the agent token it
    installs (ADR-0030 "declares its entrypoint"); the recorded entrypoint is the
    command to run, not the raw agent name.
    """
    applied = kits.kit_applied_read(backend, name)
    if applied and applied.get("entrypoint"):
        return applied["entrypoint"]
    return agent


def _resolve_backend_for_mutation(
    explicit: str | None,
    emit_json: bool,
    command: str,
    *,
    domain: str = "lifecycle",
    capability: str | None = None,
) -> tuple[str | None, int | None]:
    """Resolve the backend for a mutating verb and enforce the version floor.

    Returns ``(backend_name, exit_code)``; ``exit_code`` is non-``None`` when a
    failure was already emitted (unknown backend -> usage, no backend /
    unsupported version -> operational, all fail-closed before mutation).
    ``domain`` names the verb family for the no-backend remediation prose.
    ``capability`` (when set) additionally enforces that capability's per-capability
    version floor (``backends.CAPABILITY_FLOORS``) above the global floor.
    """
    if explicit is not None and explicit not in backends.BACKENDS:
        return None, _usage_failure(
            command,
            f"unknown backend: {explicit!r} (expected sbx or msb)",
            emit_json,
        )
    name = _resolve_active_backend(explicit)
    if name is None:
        return None, _operational_failure(
            command,
            errors.BACKEND_NOT_FOUND,
            "no sandbox backend detected",
            f"install msb {backends.MSB_MIN_VERSION[0]}.{backends.MSB_MIN_VERSION[1]}.{backends.MSB_MIN_VERSION[2]} or newer and retry",
            emit_json,
        )
    problem = backends.check_version(backends.BACKENDS[name])
    if problem is not None:
        return None, _operational_failure(command, problem.code, problem.message, problem.remediation, emit_json)
    if capability is not None:
        cap_problem = backends.check_capability_floor(backends.BACKENDS[name], capability)
        if cap_problem is not None:
            return None, _operational_failure(
                command, cap_problem.code, cap_problem.message, cap_problem.remediation, emit_json
            )
    return name, None


def _resolve_backend_for_lifecycle(
    explicit: str | None, emit_json: bool, command: str
) -> tuple[str | None, int | None]:
    """Backend resolution for the lifecycle verbs (kept as a named alias)."""
    return _resolve_backend_for_mutation(explicit, emit_json, command, domain="lifecycle")


def _validate_workspace(command: str, path: str | None, emit_json: bool) -> tuple[str | None, int | None]:
    """Resolve the workspace to an absolute directory, or emit a validation failure."""
    if not path:
        return None, _operational_failure(
            command,
            errors.VALIDATION_FAILED,
            "missing workspace path",
            f"usage: acq {command} AGENT PATH",
            emit_json,
        )
    resolved = os.path.abspath(path)
    if not os.path.isdir(resolved):
        return None, _operational_failure(
            command,
            errors.VALIDATION_FAILED,
            f"workspace path does not exist or is not a directory: {path}",
            "create the workspace first, then re-run",
            emit_json,
        )
    return resolved, None


def _mount_workspace(backend: str, workspace: str) -> str:
    """The host path to mount and record for ``workspace``.

    msb cannot mount a symlinked host path (notably the macOS ``$TMPDIR``,
    ``/var/folders`` -> ``/private/var/folders``), so it gets the real path; the
    guest ``-w`` start directory is derived from the same value. sbx keeps the
    path as typed. Call this AFTER deriving the sandbox name, which must come
    from the path the user typed.
    """
    return os.path.realpath(workspace) if backend == "msb" else workspace


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
        return None, _operational_failure(
            "run",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    gate = _trusted_gate(record, backend, "run", name, emit_json)
    if gate is not None:
        return None, gate
    return (record or {}).get("workspace") or typed, None


def _wait_exec_ready(backend: str, name: str) -> bool:
    adapter = _adapter(backend)
    deadline = time.monotonic() + adapter.READY_TIMEOUT_S
    while True:
        if adapter.exec_ready(name):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)


def _create_sandbox(
    backend: str, agent: str, workspace: str, name: str, image: str, *, ro_host_config: bool | None = None
) -> dict:
    """Create + exec-ready gate + record write; returns the result record data."""
    adapter = _adapter(backend)
    error_cls = sbx.SbxError if backend == "sbx" else msb.MsbError
    if backend == "sbx":
        adapter.create(name, image, workspace, agent=agent)
    else:
        adapter.create(name, image, workspace, memory=msb.DEFAULT_MEMORY, cpus=msb.DEFAULT_CPUS)
    if not _wait_exec_ready(backend, name):
        # A half-created sandbox must not strand (legacy cleanup).
        try:
            adapter.remove(name)
        except _ADAPTER_ERRORS:
            pass
        raise error_cls(
            errors.TIMEOUT,
            f"sandbox '{name}' did not become exec-ready",
            f"check {backend} logs, then remove the half-created sandbox and retry",
        )
    state.record_write(backend, name, agent=agent, workspace=workspace, image=image, ro_host_config=ro_host_config)
    return {
        "name": name,
        "backend": backend,
        "agent": agent,
        "workspace": workspace,
        "state": "running",
        "image": image,
    }


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
    if not parsed.agent or parsed.agent not in KNOWN_AGENTS:
        return _usage_failure(
            "create",
            f"unknown agent: {parsed.agent!r} (expected one of: {', '.join(sorted(KNOWN_AGENTS))})",
            emit_json,
        )
    workspace, exit_code = _validate_workspace("create", parsed.path, emit_json)
    if exit_code is not None:
        return exit_code
    kit_name, exit_code = _validate_kit_flag(parsed.kit, "create", emit_json)
    if exit_code is not None:
        return exit_code
    if kit_name is None:
        kit_name = kits.agent_kit_for(parsed.agent)  # implicit inference (built-in only)
    name = parsed.name or _derive_name(parsed.agent, workspace)
    workspace = _mount_workspace(backend, workspace)
    adapter = _adapter(backend)
    if adapter.exists(name):
        return _operational_failure(
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
    if kit_name is not None and not _supports(backend, "kit-apply"):
        return _operational_failure(
            "create",
            errors.UNSUPPORTED,
            f"agent '{parsed.agent}' requires the '{kit_name}' kit, which the {backend} backend cannot apply",
            "use a backend that supports kit-apply (msb in this slice), or choose an agent without a kit",
            emit_json,
        )
    image, provision_steps, exit_code = _resolve_image_for_kit(parsed.image, parsed.agent, kit_name, "create", emit_json)
    if exit_code is not None:
        return exit_code
    try:
        data = _create_sandbox(backend, parsed.agent, workspace, name, image)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("create", exc.code, exc.message, exc.remediation, emit_json)
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
    adapter = _adapter(backend)
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return _operational_failure(
            "create",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"remove the unreadable record for '{name}', or recreate it out of band",
            emit_json,
        )
    if record is None:
        return _operational_failure(
            "create",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' has no host state record to recreate",
            f"create it with 'acq create', or list sandboxes with 'acq ls'",
            emit_json,
        )
    try:
        security.assert_trusted(record, backend, name)
    except security.SecurityException:
        pass  # in the security exception -> recreation is the sanctioned recovery
    else:
        return _operational_failure(
            "create",
            errors.VALIDATION_FAILED,
            f"sandbox '{name}' is not missing its read-only mount; recreation is "
            "only for the security exception",
            f"re-attach with 'acq run {name}' instead",
            emit_json,
        )
    if not parsed.yes:
        if emit_json or not sys.stdin.isatty():
            return _operational_failure(
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

    agent = record.get("agent") or "shell"
    workspace = record.get("workspace") or DEFAULT_GUEST_WORKSPACE
    if record.get("workspace"):
        # Records written before msb workspaces were canonicalized hold the symlink form.
        workspace = _mount_workspace(backend, workspace)
    image = record.get("image") or _default_image_for_agent(agent)
    ro_host_config = bool(record.get("ro_host_config"))
    # Fail closed BEFORE recreation when the recorded agent needs a kit the
    # backend can't apply: a legacy sbx opencode sandbox must not be recreated
    # and then discarded because kit-apply is unsupported there (ADR-0040m).
    kit_name = kits.agent_kit_for(agent)
    if kit_name is not None and not _supports(backend, "kit-apply"):
        return _operational_failure(
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
        # Preserve host records + secrets; lose only the guest filesystem. If the
        # guest is already gone (removed out of band) there is nothing to destroy:
        # recreate from host authority either way.
        if adapter.exists(name):
            adapter.remove(name)
        data = _create_sandbox(backend, agent, workspace, name, image, ro_host_config=ro_host_config)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("create", exc.code, exc.message, exc.remediation, emit_json)
    # The guest filesystem was destroyed, so a prior applied-kit record no longer
    # describes the fresh guest: clear it and re-apply the agent kit (if any) so
    # the recreated sandbox has its agent binary (ADR-0030 create-time install).
    entrypoint = None
    if kit_name is not None:
        kits.kit_applied_remove(backend, name)
        gate = _apply_agent_kit(backend, name, kit_name, provision_steps, "create", emit_json)
        if gate is not None:
            _discard_half_created(backend, name)
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


def run_run(parsed, emit_json: bool, backend: str) -> int:
    """Create (if missing) then launch, or re-attach an existing sandbox by name.

    In ``--json`` mode the create/attach result is emitted as one JSON envelope on
    stdout, and the launched child's own output is routed to stderr so stdout
    stays a single document (ADR-0038m §2). In interactive use the child inherits
    stdio. The child's exit status is ``run``'s exit status (ADR-0038m §1).
    """
    adapter = _adapter(backend)
    target = parsed.target
    if target in KNOWN_AGENTS:
        workspace, exit_code = _validate_workspace("run", parsed.path, emit_json)
        if exit_code is not None:
            return exit_code
        kit_name, exit_code = _validate_kit_flag(parsed.kit, "run", emit_json)
        if exit_code is not None:
            return exit_code
        name = parsed.name or _derive_name(target, workspace)
        workspace = _mount_workspace(backend, workspace)
        action = "reattached" if adapter.exists(name) else "created"
        if action == "reattached":
            workspace, exit_code = _reattach_workspace(backend, name, workspace, emit_json)
            if exit_code is not None:
                return exit_code
        image: str | None = None
        entrypoint: str | None = None
        if not adapter.exists(name):
            if kit_name is None:
                kit_name = kits.agent_kit_for(target)  # implicit inference (built-in only)
            if kit_name is not None and not _supports(backend, "kit-apply"):
                return _operational_failure(
                    "run",
                    errors.UNSUPPORTED,
                    f"agent '{target}' requires the '{kit_name}' kit, which the {backend} backend cannot apply",
                    "use a backend that supports kit-apply (msb in this slice), or choose an agent without a kit",
                    emit_json,
                )
            image, provision_steps, exit_code = _resolve_image_for_kit(parsed.image, target, kit_name, "run", emit_json)
            if exit_code is not None:
                return exit_code
            try:
                _create_sandbox(backend, target, workspace, name, image)
            except _ADAPTER_ERRORS as exc:
                return _operational_failure("run", exc.code, exc.message, exc.remediation, emit_json)
            if kit_name is not None:
                gate = _apply_agent_kit(backend, name, kit_name, provision_steps, "run", emit_json)
                if gate is not None:
                    _discard_half_created(backend, name)
                    return gate
                entrypoint = kits.agent_kit_entrypoint(kit_name)
        else:
            # Re-attach: the kit (if any) was applied at create time; read the
            # recorded kit/entrypoint (lenient) so the launch surfaces provenance.
            applied = kits.kit_applied_read(backend, name)
            if applied:
                kit_name = applied.get("kit")
                entrypoint = applied.get("entrypoint")
        data = {
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
        if emit_json:
            print(json.dumps(envelope.success("run", data)))
        # Launch in the foreground; the child's status is `run`'s exit status. In
        # --json mode the child's stdout is routed to stderr so stdout stays one
        # JSON document. A recorded kit entrypoint wins over the agent token.
        return adapter.launch(name, workspace, entrypoint or target, json_mode=emit_json)

    # Not a known agent: re-attach to an existing sandbox by name, else fail
    # closed as ambiguous (a token that is neither agent nor sandbox is a usage
    # error, matching the legacy dispatch).
    if not adapter.exists(target):
        return _usage_failure(
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
        return _operational_failure(
            "run",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {target}'",
            emit_json,
        )
    if record is None:
        return _operational_failure(
            "run",
            errors.VALIDATION_FAILED,
            f"sandbox '{target}' has no readable host state record; cannot determine the agent to launch",
            f"create it with 'acq create', or remove it with 'acq rm {target}'",
            emit_json,
        )
    gate = _trusted_gate(record, backend, "run", target, emit_json)
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
    return adapter.launch(target, workspace, _launch_token(backend, target, agent), json_mode=emit_json)


def _ls_data(backend: str) -> dict:
    adapter = _adapter(backend)
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
    data = _ls_data(backend)
    if emit_json:
        print(json.dumps(envelope.success("ls", data)))
    else:
        _print_ls_human(data)
    return errors.EXIT_SUCCESS


def run_stop(parsed, emit_json: bool, backend: str) -> int:
    adapter = _adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return _operational_failure(
            "stop",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    try:
        adapter.stop(name)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("stop", exc.code, exc.message, exc.remediation, emit_json)
    data = {"name": name, "backend": backend, "state": "stopped"}
    if emit_json:
        print(json.dumps(envelope.success("stop", data)))
    else:
        print(f"stopped sandbox '{name}'")
    return errors.EXIT_SUCCESS


def run_rm(parsed, emit_json: bool, backend: str) -> int:
    adapter = _adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return _operational_failure(
            "rm",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls'",
            emit_json,
        )
    try:
        adapter.remove(name)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("rm", exc.code, exc.message, exc.remediation, emit_json)
    state.record_remove(backend, name)
    data = {"name": name, "backend": backend, "removed": True}
    if emit_json:
        print(json.dumps(envelope.success("rm", data)))
    else:
        print(f"removed sandbox '{name}'")
    return errors.EXIT_SUCCESS


# ---------------------------------------------------------------------------
# exec / attach / shell / cp / ports (ADR-0040m capabilities; ADR-0038m §1
# child/backend status preservation).
# ---------------------------------------------------------------------------

def _sandbox_ref(token: str) -> tuple[str, str] | None:
    """Return ``(name, guest_path)`` when ``token`` is a ``NAME:/guest/path`` ref.

    Host and guest path types are distinct (ADR-0038m §4): only a bare ``NAME:``
    prefix followed by a POSIX-absolute path is a guest ref. A Windows drive
    (``C:/…``) is a single-letter host path, never a guest ref, so a host mount
    source is never misread as a guest path implicitly.
    """
    if ":" not in token:
        return None
    name, _sep, rest = token.partition(":")
    if not rest.startswith("/"):
        return None
    if not name or any(ch in name for ch in "/\\:"):
        return None
    if os.name == "nt" and len(name) == 1 and name.isalpha():
        return None
    return (name, rest)


def _workspace_from_record(backend: str, name: str) -> str:
    """Resolve the guest workspace for a session (``-w``), host-authoritative.

    Returns the recorded workspace, or :data:`DEFAULT_GUEST_WORKSPACE` when the
    record is absent or legacy v0 (a missing record is a starting-directory
    default, not an authority decision). A newer/unknown-schema or unparseable
    record raises :class:`state.StateSchemaError` so the caller fails closed
    rather than running in a guessed cwd (ADR-0041m).
    """
    record = state.record_read(backend, name)  # raises StateSchemaError
    if record and record.get("workspace"):
        return record["workspace"]
    return DEFAULT_GUEST_WORKSPACE


def _trusted_gate(record: dict | None, backend: str, command: str, name: str, emit_json: bool) -> int | None:
    """Refuse a trusted operation on a sandbox missing its read-only mount.

    Returns an emitted exit code when the record requires the mount and the probe
    reports it missing (ADR-0035/0041m), else ``None`` to proceed.
    """
    try:
        security.assert_trusted(record, backend, name)
    except security.SecurityException as exc:
        return _operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    return None


def run_exec(parsed, emit_json: bool, backend: str) -> int:
    """``acq exec NAME -- CMD...`` — run a command non-interactively.

    The child's exit status is acq's exit status (ADR-0038m §1). In ``--json``
    mode the child's stdout is routed to stderr and one success envelope carrying
    the exit code is emitted on stdout (ADR-0038m §2).
    """
    adapter = _adapter(backend)
    name = parsed.name
    command = list(parsed.cmd)
    if not command:
        return _usage_failure(
            "exec",
            f"exec requires a command after '--' (usage: acq exec {name} -- CMD...)",
            emit_json,
        )
    if not adapter.exists(name):
        return _operational_failure(
            "exec",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return _operational_failure(
            "exec",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    gate = _trusted_gate(record, backend, "exec", name, emit_json)
    if gate is not None:
        return gate
    workspace = (record or {}).get("workspace") or DEFAULT_GUEST_WORKSPACE
    rc = adapter.exec_command(name, command, workspace=workspace, json_mode=emit_json)
    if emit_json:
        print(json.dumps(envelope.success("exec", {"name": name, "exit_code": rc})))
    return rc


def run_attach(parsed, emit_json: bool, backend: str) -> int:
    """``acq attach NAME`` — attach to an existing sandbox, launching its agent.

    This is the interactive path; its non-interactive contract is deterministic
    (ADR-0038m §1, spec user story #10): fail closed on a missing sandbox or a
    missing/unreadable host record, then launch the recorded agent and propagate
    its status. The agent comes from host-authoritative state only — there is no
    agent-to-shell fallback (ADR-0038m §48). True PTY allocation and ssh-agent
    forwarding are Tier-3/live concerns and are not synthesized here.
    """
    adapter = _adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return _operational_failure(
            "attach",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return _operational_failure(
            "attach",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    if record is None:
        return _operational_failure(
            "attach",
            errors.VALIDATION_FAILED,
            f"sandbox '{name}' has no readable host state record; cannot determine the agent to launch",
            f"create it with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    gate = _trusted_gate(record, backend, "attach", name, emit_json)
    if gate is not None:
        return gate
    agent = record.get("agent")
    if not agent:
        return _operational_failure(
            "attach",
            errors.VALIDATION_FAILED,
            f"sandbox '{name}' records no agent; cannot determine the agent to launch",
            f"create it with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    workspace = record.get("workspace") or DEFAULT_GUEST_WORKSPACE
    rc = adapter.launch(name, workspace, _launch_token(backend, name, agent), json_mode=emit_json)
    if emit_json:
        print(json.dumps(envelope.success("attach", {"name": name, "backend": backend, "agent": agent, "exit_code": rc})))
    return rc


def run_shell(parsed, emit_json: bool, backend: str) -> int:
    """``acq shell NAME`` — open an interactive login shell in a sandbox.

    Runs ``/bin/sh -l`` as the unprivileged ``agent`` user (never root), with the
    child's status preserved. Like ``attach``, the non-interactive path is
    deterministic and PTY allocation is deferred to the live tier.
    """
    adapter = _adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return _operational_failure(
            "shell",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return _operational_failure(
            "shell",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    gate = _trusted_gate(record, backend, "shell", name, emit_json)
    if gate is not None:
        return gate
    workspace = (record or {}).get("workspace") or DEFAULT_GUEST_WORKSPACE
    rc = adapter.launch(name, workspace, "shell", json_mode=emit_json)
    if emit_json:
        print(json.dumps(envelope.success("shell", {"name": name, "backend": backend, "exit_code": rc})))
    return rc


def run_cp(parsed, emit_json: bool, backend: str) -> int:
    """``acq cp SRC DST`` — copy between a native host path and a POSIX guest path.

    Exactly one side is a ``NAME:/guest/path`` reference; the other is a host
    path. Host and guest types stay distinct (ADR-0038m §4): a host mount source
    is never treated as a guest path implicitly, and a UNC/network host path —
    which cannot round-trip losslessly across the host/guest boundary — fails
    closed rather than being mis-forwarded. The backend copy status is preserved.
    """
    adapter = _adapter(backend)
    src = parsed.src
    dst = parsed.dst
    src_ref = _sandbox_ref(src)
    dst_ref = _sandbox_ref(dst)
    if src_ref and dst_ref:
        return _usage_failure(
            "cp",
            "copying between two sandboxes is not supported; exactly one side must be a host path",
            emit_json,
        )
    if not src_ref and not dst_ref:
        return _usage_failure(
            "cp",
            "exactly one of SRC/DST must be a sandbox reference (NAME:/guest/path)",
            emit_json,
        )
    name, guest_path = src_ref if src_ref else dst_ref
    host_path = dst if src_ref else src
    direction = "out" if src_ref else "in"
    if not adapter.exists(name):
        return _operational_failure(
            "cp",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls'",
            emit_json,
        )
    # UNC/network paths require separate qualification (ADR-0038m §4): fail
    # closed rather than hand a host-side network path to the backend copy.
    if host_path.startswith("\\\\") or host_path.startswith("//"):
        return _operational_failure(
            "cp",
            errors.VALIDATION_FAILED,
            f"host path {host_path!r} is a UNC/network path and requires separate qualification",
            "copy via a mounted or local path instead",
            emit_json,
        )
    rc = adapter.copy(src, dst)
    if rc != 0:
        return _operational_failure(
            "cp",
            errors.FAILURE,
            f"copy failed between host and sandbox '{name}'",
            f"check {backend} logs and retry",
            emit_json,
            exit_code=rc,
        )
    if emit_json:
        print(json.dumps(envelope.success("cp", {"name": name, "host": host_path, "guest": guest_path, "direction": direction, "exit_code": 0})))
    else:
        if direction == "in":
            print(f"copied {host_path} -> {name}:{guest_path}")
        else:
            print(f"copied {name}:{guest_path} -> {host_path}")
    return errors.EXIT_SUCCESS


def run_ports(parsed, emit_json: bool, backend: str) -> int:
    """``acq ports NAME`` — report declared host/guest mappings, never health.

    ADR-0038m §2 fixes the required data: host/guest mappings plus origin. A
    missing sandbox fails closed with ``sandbox_not_found``; a ports read that
    fails or returns unparseable output fails closed with a stable code rather
    than being swallowed as an empty list (ADR-0038m §48 drops
    "inspection-failure-as-empty"). Post-hoc ``--publish`` (ADR-0015) is deferred.
    """
    adapter = _adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return _operational_failure(
            "ports",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    try:
        mappings = adapter.ports(name)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("ports", exc.code, exc.message, exc.remediation, emit_json)
    data = {"name": name, "ports": mappings}
    if emit_json:
        print(json.dumps(envelope.success("ports", data)))
    else:
        if not mappings:
            print(f"no declared ports for sandbox '{name}'")
        else:
            for entry in mappings:
                print(f"guest {entry['guest_port']} -> host {entry['host_port']} ({entry['origin']})")
    return errors.EXIT_SUCCESS


# ---------------------------------------------------------------------------
# secret set / rm / ls / has (ADR-0040m `secret-write/rm`, `secret-list`;
# ADR-0038m §secret ls/has required data). The paramount rule is that no secret
# VALUE ever appears in argv, logs, fixtures, or output: scope/service are
# non-secret identifiers on argv, while the value flows on stdin only.
# ---------------------------------------------------------------------------

def _read_secret_value() -> str:
    """Read the secret value from stdin, preserving trailing-newline fidelity.

    Exactly the single terminal newline that a terminal/``echo`` appends is
    stripped (plus an immediately preceding ``\\r`` for a CRLF terminator). Any
    further trailing newlines are value content and are preserved: a value that
    legitimately ends in newlines is not silently truncated. A lone trailing
    ``\\r`` with no preceding ``\\n`` is likewise preserved.

    The value is returned to the caller and must never be printed, logged, or
    placed on argv. An empty result signals "no value was piped".
    """
    data = sys.stdin.read()
    if data.endswith("\n"):
        data = data[:-1]  # strip exactly one terminal newline
        if data.endswith("\r"):  # optional preceding CR (CRLF terminator)
            data = data[:-1]
    return data


def run_secret_set(parsed, emit_json: bool, backend: str) -> int:
    """``acq secret set (-g | SANDBOX) SERVICE`` — value read from stdin only.

    The value is forwarded to the backend on its stdin (never argv) and is never
    echoed; the success envelope carries only scope/service/value_state.
    """
    adapter = _adapter(backend)
    scope, service = _parse_secret_scope_service(parsed.global_scope, parsed.args)
    if scope is None or service is None:
        return _usage_failure("secret set", "usage: acq secret set [-g | SANDBOX] SERVICE (value on stdin)", emit_json)
    value = _read_secret_value()
    if not value.strip():
        # Empty (or whitespace-only) stdin is a validation failure (exit 1), not a
        # usage error (exit 2): the invocation was well-formed but supplied no
        # storable value (ADR-0038m §1 "validation" class).
        return _operational_failure(
            "secret set",
            errors.VALIDATION_FAILED,
            "no secret value provided on stdin",
            "pipe the secret value on stdin, e.g. printf '%s' VALUE | acq secret set -g SERVICE",
            emit_json,
        )
    try:
        adapter.secret_set(scope, service, value)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("secret set", exc.code, exc.message, exc.remediation, emit_json)
    data = {"scope": scope, "service": service, "value_state": "set"}
    if emit_json:
        print(json.dumps(envelope.success("secret set", data)))
    else:
        print(f"stored secret '{service}' (scope {scope})")
    return errors.EXIT_SUCCESS


def run_secret_rm_raw(placeholder: str, emit_json: bool) -> int:
    """sbx-only raw-placeholder removal (ADR-0038m §48).

    Removes a raw placeholder from sbx's proxy table; the acq store is left
    unchanged (never rewrites host-held records). The placeholder is never a
    secret value.
    """
    try:
        sbx.secret_rm_raw(placeholder)
    except sbx.SbxError as exc:
        return _operational_failure("secret rm", exc.code, exc.message, exc.remediation, emit_json)
    data = {"placeholder": placeholder, "value_state": "unset"}
    if emit_json:
        print(json.dumps(envelope.success("secret rm", data)))
    else:
        print(f"removed raw placeholder '{placeholder}'.")
    return errors.EXIT_SUCCESS


def run_secret_rm(parsed, emit_json: bool, backend: str) -> int:
    """``acq secret rm (-g | SANDBOX) SERVICE`` — remove a secret.

    An absent secret fails closed with ``secret_missing`` (ADR-0040m); a backend
    that cannot answer fails closed with its own accurate code (``backend_not_found``
    / ``failure``) and never deletes. On sbx, a single bare token that is not a
    managed scope+service is a raw placeholder to remove from the proxy table
    (ADR-0038m §48) and leaves the acq store unchanged.
    """
    adapter = _adapter(backend)
    scope, service = _parse_secret_scope_service(parsed.global_scope, parsed.args)
    if scope is None or service is None:
        # sbx raw-placeholder removal: a single bare token (no scope, no second
        # positional) is a raw placeholder for sbx's own `secret` CLI.
        if backend == "sbx" and not parsed.global_scope and len(parsed.args) == 1 and not parsed.args[0].startswith("-"):
            return run_secret_rm_raw(parsed.args[0], emit_json)
        return _usage_failure("secret rm", "usage: acq secret rm [-g | SANDBOX] SERVICE", emit_json)
    try:
        present = adapter.key_present(scope, service) if backend == "sbx" else adapter.secret_has(scope, service)
    except _ADAPTER_ERRORS as exc:
        # A backend that cannot answer is NOT "absent": fail closed with the
        # accurate code (backend_not_found / failure), never secret_missing, and
        # never delete.
        return _operational_failure("secret rm", exc.code, exc.message, exc.remediation, emit_json)
    if not present:
        return _operational_failure(
            "secret rm",
            errors.SECRET_MISSING,
            f"no secret '{service}' for scope '{scope}'",
            f"store one with 'acq secret set -g {service}' (or scoped to a sandbox)",
            emit_json,
        )
    try:
        adapter.secret_rm(scope, service)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("secret rm", exc.code, exc.message, exc.remediation, emit_json)
    data = {"scope": scope, "service": service, "value_state": "unset"}
    if emit_json:
        print(json.dumps(envelope.success("secret rm", data)))
    else:
        print(f"removed secret '{service}' (scope {scope})")
    return errors.EXIT_SUCCESS


def _print_secret_ls_human(data: dict) -> None:
    secrets = data["secrets"]
    if not secrets:
        print("no secrets")
        return
    for entry in secrets:
        print(f"  {entry['scope']}  {entry['service']}  {entry['value_state']}")


def run_secret_ls(parsed, emit_json: bool, backend: str) -> int:
    """``acq secret ls [(-g | SANDBOX)]`` — scope/service/value_state, never a value.

    An unreadable or unparseable backend listing fails closed with
    ``secret_unreadable`` (ADR-0040m) rather than being reported as empty.
    ``secret ls`` realizes the ``secret-list`` obligation: supported on sbx
    (``sbx secret ls``), unsupported on msb (no ``secret`` subcommand), where it
    fails closed with ``unsupported_capability``.
    """
    if not _supports(backend, "secret-list"):
        return _operational_failure(
            "secret ls",
            errors.UNSUPPORTED,
            f"secret listing is not supported on the {backend} backend",
            "sbx exposes 'sbx secret ls'; msb has no standalone secret store",
            emit_json,
        )
    scope, ok = _parse_secret_ls_scope(parsed.global_scope, parsed.args)
    if not ok:
        return _usage_failure("secret ls", "usage: acq secret ls [-g | SANDBOX]", emit_json)
    try:
        secrets = _adapter(backend).secret_ls(scope)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("secret ls", exc.code, exc.message, exc.remediation, emit_json)
    data = {"secrets": secrets}
    if emit_json:
        print(json.dumps(envelope.success("secret ls", data)))
    else:
        _print_secret_ls_human(data)
    return errors.EXIT_SUCCESS


def run_secret_has(parsed, backend_override: str | None) -> int:
    """``acq secret has (-g | SANDBOX) SERVICE`` — silent predicate (ADR-0038m).

    Exit 0 (present), 1 (absent or fail-closed), 2 (usage). ``--json`` is inert:
    there is never a stdout body — the answer is the exit status alone, and
    failures are stderr diagnostics (so ``emit_json`` is deliberately not honored).
    On sbx the presence predicate is the sbx-only ``key_present`` obligation; on
    msb it is the thin ``secret has`` predicate over the secret-list capability.
    """
    scope, service = _parse_secret_scope_service(parsed.global_scope, parsed.args)
    if scope is None or service is None:
        return _usage_failure("secret has", "usage: acq secret has [-g | SANDBOX] SERVICE", False)
    backend, exit_code = _resolve_backend_for_mutation(
        backend_override, False, "secret has", domain="secret management"
    )
    if exit_code is not None:
        # The resolver already wrote a stderr diagnostic (no backend, or version
        # floor): exit 1/2 with stdout still silent, so "cannot check" is never a
        # silent false "absent".
        return exit_code
    adapter = _adapter(backend)
    try:
        if backend == "sbx":
            present = sbx.key_present(scope, service)
        else:
            present = msb.secret_has(scope, service)
    except _ADAPTER_ERRORS as exc:
        # Backend error at query time: keep stdout silent and exit 1, but announce
        # on stderr so a scripter can tell "absent" from "could not check".
        print(f"acq: {exc.message}", file=sys.stderr)
        if exc.remediation:
            print(exc.remediation, file=sys.stderr)
        return errors.EXIT_FAILURE
    return errors.EXIT_SUCCESS if present else errors.EXIT_FAILURE


# ---------------------------------------------------------------------------
# provider-credential set / ls / rm (ADR-0038m §provider-credential), and the
# github-scope / usai-rotate-api-key verbs (ADR-0012, ADR-0013). The paramount
# rule is unchanged from `secret`: a credential VALUE never appears in argv,
# logs, or output — it flows on stdin only and is forwarded to the backend on the
# child's stdin. The binding / scope is host-authoritative state (ADR-0041m).
# ---------------------------------------------------------------------------

def run_provider_credential_set(parsed, emit_json: bool, backend: str) -> int:
    """``acq provider-credential set PROVIDER KEY_ENV --host H[,H]`` (value on stdin).

    Validates the destination pin, reads the value on stdin only, forwards it to
    the backend on the child's stdin, and records the binding host-side. The
    success envelope carries only the binding fields (never a value).
    """
    adapter = _adapter(backend)
    command = "provider-credential set"
    provider = parsed.provider
    key_env = parsed.key_env
    hosts = provider_creds.parse_hosts(parsed.host)
    if not hosts:
        return _operational_failure(
            command,
            errors.VALIDATION_FAILED,
            "a --host is required",
            f"the host is the trust decision that lets acq send this credential to "
            f"a destination; usage: acq provider-credential set {provider} {key_env} --host models.example.gov",
            emit_json,
        )
    problem = provider_creds.validate_binding(provider, key_env, hosts)
    if problem is not None:
        return _operational_failure(command, errors.VALIDATION_FAILED, problem, None, emit_json)
    value = _read_secret_value()
    if not value.strip():
        return _operational_failure(
            command,
            errors.VALIDATION_FAILED,
            "no credential value provided on stdin",
            "pipe the credential value on stdin, e.g. printf '%s' VALUE | acq provider-credential set PROVIDER KEY_ENV --host H",
            emit_json,
        )
    try:
        adapter.provider_credential_set(provider, key_env, hosts, value)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    try:
        provider_creds.set_binding(provider, key_env, hosts)
    except state.StateSchemaError as exc:
        # A newer/unknown-schema or unparseable binding record fails closed with
        # the ADR-0041m stable code rather than a raw traceback.
        return _operational_failure(
            command,
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"remove or repair the unreadable provider-credential binding for '{provider}', then retry",
            emit_json,
        )
    data = {
        "provider": provider,
        "key_env": key_env,
        "hosts": hosts,
        "source_layer": provider_creds.CONFIG_LAYER,
    }
    if emit_json:
        print(json.dumps(envelope.success(command, data)))
    else:
        print(f"bound provider '{provider}' to ${key_env} for host(s) {', '.join(hosts)}.")
    return errors.EXIT_SUCCESS


def _print_provider_credential_ls_human(data: dict) -> None:
    bindings = data["bindings"]
    if not bindings:
        print("no provider-credential bindings")
        return
    for entry in bindings:
        hosts = ",".join(entry["hosts"]) if entry["hosts"] else "(none)"
        print(f"  {entry['provider']}  {entry['key_env']}  {hosts}  {entry['source_layer']}")


def run_provider_credential_ls(emit_json: bool) -> int:
    """``acq provider-credential ls`` — provider/key_env/hosts/source_layer, never a value.

    Reads host-authoritative binding records plus the per-invocation env layer. A
    malformed env-layer entry fails closed (validation_failed) rather than being
    silently dropped (ADR-0038m).
    """
    try:
        bindings = provider_creds.list_bindings()
    except ValueError as exc:
        return _operational_failure(
            "provider-credential ls",
            errors.VALIDATION_FAILED,
            str(exc),
            "fix the malformed ACQ_PROVIDER_CREDENTIAL_BINDINGS entry and retry",
            emit_json,
        )
    data = {"bindings": bindings}
    if emit_json:
        print(json.dumps(envelope.success("provider-credential ls", data)))
    else:
        _print_provider_credential_ls_human(data)
    return errors.EXIT_SUCCESS


def run_provider_credential_rm(parsed, emit_json: bool) -> int:
    """``acq provider-credential rm PROVIDER`` — drop the host-side binding.

    Removing an absent binding fails closed with ``secret_missing`` (reused: the
    credential binding is missing, ADR-0040m). The value itself is a backend
    secret and is not touched here (matching the legacy split between the binding
    and the stored value).
    """
    provider = parsed.provider
    if not provider_creds.provider_id_ok(provider):
        return _operational_failure(
            "provider-credential rm",
            errors.VALIDATION_FAILED,
            f"invalid provider id {provider!r}",
            None,
            emit_json,
        )
    try:
        removed = provider_creds.remove_binding(provider)
    except state.StateSchemaError as exc:
        # A newer/unknown-schema or unparseable binding record fails closed with
        # the ADR-0041m stable code rather than a raw traceback.
        return _operational_failure(
            "provider-credential rm",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"remove or repair the unreadable provider-credential binding for '{provider}', then retry",
            emit_json,
        )
    if not removed:
        return _operational_failure(
            "provider-credential rm",
            errors.SECRET_MISSING,
            f"no credential binding for provider '{provider}'",
            f"list bindings with 'acq provider-credential ls', or add one with 'acq provider-credential set {provider} KEY_ENV --host H'",
            emit_json,
        )
    data = {"provider": provider, "removed": True}
    if emit_json:
        print(json.dumps(envelope.success("provider-credential rm", data)))
    else:
        print(f"removed the '{provider}' binding.")
    return errors.EXIT_SUCCESS


def _github_scope_workspace(parsed, backend: str, emit_json: bool) -> tuple[str | None, int | None]:
    """Resolve the workspace for ``github-scope`` (PATH, else the recorded one)."""
    sandbox = parsed.sandbox
    if parsed.path:
        resolved = _mount_workspace(backend, os.path.abspath(parsed.path))
        if not os.path.isdir(resolved):
            return None, _operational_failure(
                "github-scope",
                errors.VALIDATION_FAILED,
                f"workspace path does not exist or is not a directory: {parsed.path}",
                "pass an existing workspace directory, or omit PATH to use the recorded sandbox workspace",
                emit_json,
            )
        return resolved, None
    try:
        record = state.record_read(backend, sandbox)
    except state.StateSchemaError as exc:
        return None, _operational_failure(
            "github-scope",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or pass a workspace path explicitly",
            emit_json,
        )
    workspace = (record or {}).get("workspace")
    if not workspace:
        return None, _operational_failure(
            "github-scope",
            errors.VALIDATION_FAILED,
            f"no workspace path was provided, and no workspace is recorded for sandbox '{sandbox}'",
            f"usage: acq github-scope {sandbox} /path/to/workspace",
            emit_json,
        )
    return workspace, None


def run_github_scope(parsed, emit_json: bool, backend: str) -> int:
    """``acq github-scope SANDBOX [PATH]`` — per-sandbox GitHub token scope.

    The token is read on stdin only and forwarded to the backend (bound to the
    sandbox, never global); the scope is recorded host-side (ADR-0013). The token
    never appears in output.
    """
    adapter = _adapter(backend)
    sandbox = parsed.sandbox
    workspace, exit_code = _github_scope_workspace(parsed, backend, emit_json)
    if exit_code is not None:
        return exit_code
    value = _read_secret_value()
    if not value.strip():
        return _operational_failure(
            "github-scope",
            errors.VALIDATION_FAILED,
            "no GitHub token provided on stdin",
            "pipe the token on stdin, e.g. printf '%s' TOKEN | acq github-scope SANDBOX PATH",
            emit_json,
        )
    try:
        adapter.github_scope(sandbox, value)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("github-scope", exc.code, exc.message, exc.remediation, emit_json)
    provider_creds.github_scope_write(backend, sandbox, workspace)
    data = {"sandbox": sandbox, "backend": backend, "scoped": True}
    if emit_json:
        print(json.dumps(envelope.success("github-scope", data)))
    else:
        print(f"scoped a GitHub token to sandbox '{sandbox}' (workspace {workspace}).")
    return errors.EXIT_SUCCESS


def run_usai_rotate_api_key(emit_json: bool, backend: str) -> int:
    """``acq usai-rotate-api-key`` — rotate the stored USAi key (ADR-0012).

    Reads the new key on stdin only and forwards it to the backend on the child's
    stdin. The backend validates the new key before replacing the old one, so a
    failed rotation (provider_unreachable / provider_auth_failed) leaves the old
    key in place. The new key never appears in output.
    """
    adapter = _adapter(backend)
    value = _read_secret_value()
    if not value.strip():
        return _operational_failure(
            "usai-rotate-api-key",
            errors.VALIDATION_FAILED,
            "no new USAi key provided on stdin",
            "pipe the new key on stdin, e.g. printf '%s' NEW_KEY | acq usai-rotate-api-key",
            emit_json,
        )
    try:
        adapter.rotate_key(value)
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("usai-rotate-api-key", exc.code, exc.message, exc.remediation, emit_json)
    data = {
        "provider": provider_creds.USAI_PROVIDER_ID,
        "key_env": provider_creds.USAI_PROVIDER_KEY_ENV,
        "rotated": True,
    }
    if emit_json:
        print(json.dumps(envelope.success("usai-rotate-api-key", data)))
    else:
        print("rotated the USAi API key.")
    return errors.EXIT_SUCCESS


# ---------------------------------------------------------------------------
# kit list / validate / apply / check / update, and kit-source add / ls / rm
# (ADR-0038m §kit; ADR-0016 provenance; trusted-source policy; ADR-0030
# agent-kit install). ``kit apply`` is the ADR-0030 devenv-base + agent-install
# path: it applies a built-in agent kit in-guest via the backend ``kit-apply``
# capability, idempotently.
# ---------------------------------------------------------------------------

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
        return _operational_failure(
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
    ``unsupported_capability`` (sbx in this slice). Only built-in agent kits are
    applicable by name here; team/personal kit application is deferred. The
    install runs in-guest and is idempotent: a re-apply of the same kit is a no-op
    (no duplicate install), tracked by the host-authoritative applied-kit record
    (ADR-0041m).
    """
    backend, exit_code = _resolve_backend_for_mutation(
        backend_override, emit_json, "kit apply", domain="kit"
    )
    if exit_code is not None:
        return exit_code
    if not _supports(backend, "kit-apply"):
        return _operational_failure(
            "kit apply",
            errors.UNSUPPORTED,
            f"kit apply is not supported on the {backend} backend",
            "kit-apply is msb-only in this slice (ADR-0040m); use msb to apply an agent kit",
            emit_json,
        )
    name = parsed.name
    kitref = parsed.kitref
    if not _adapter(backend).exists(name):
        return _operational_failure(
            "kit apply",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    if not kits.is_agent_kit(kitref):
        return _operational_failure(
            "kit apply",
            errors.VALIDATION_FAILED,
            f"kit ref {kitref!r} is not a built-in agent kit (expected one of: {', '.join(kits.AGENT_KIT_NAMES)})",
            "this slice applies built-in agent kits by name; team/personal kit application is deferred",
            emit_json,
        )
    kit_name = kitref
    entrypoint = kits.agent_kit_entrypoint(kit_name)
    existing = kits.kit_applied_read(backend, name)
    if existing and existing.get("kit") == kit_name:
        data = {
            "sandbox": name,
            "backend": backend,
            "kit": kit_name,
            "entrypoint": entrypoint,
            "applied": False,
            "action": "noop",
        }
        if emit_json:
            print(json.dumps(envelope.success("kit apply", data)))
        else:
            print(f"kit '{kit_name}' already applied to sandbox '{name}'.")
        return errors.EXIT_SUCCESS
    try:
        _adapter(backend).kit_apply(name, kit_name, kits.agent_kit_install(kit_name))
    except _ADAPTER_ERRORS as exc:
        return _operational_failure("kit apply", exc.code, exc.message, exc.remediation, emit_json)
    kits.kit_applied_write(backend, name, kit_name, entrypoint)
    data = {
        "sandbox": name,
        "backend": backend,
        "kit": kit_name,
        "entrypoint": entrypoint,
        "applied": True,
        "action": "applied",
    }
    if emit_json:
        print(json.dumps(envelope.success("kit apply", data)))
    else:
        print(f"applied kit '{kit_name}' to sandbox '{name}' (entrypoint {entrypoint}).")
    return errors.EXIT_SUCCESS


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
    backend, exit_code = _resolve_backend_for_mutation(
        backend_override, emit_json, "kit check", domain="kit inspection"
    )
    if exit_code is not None:
        return exit_code
    name = parsed.name
    if not _adapter(backend).exists(name):
        return _operational_failure(
            "kit check",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    data = kits.kit_check_data(backend, name)
    if emit_json:
        print(json.dumps(envelope.success("kit check", data)))
    else:
        _print_kit_check_human(data)
    return errors.EXIT_SUCCESS


def run_kit_update(parsed, emit_json: bool, backend_override: str | None) -> int:
    """``acq kit update SANDBOX [--yes]`` — consented bundle refresh.

    Refresh is consented (ADR-0038m §46): ``--yes`` consents explicitly, an
    interactive TTY prompts, and a non-interactive run without ``--yes`` refuses
    (never invents consent; spec user story #10). ``--json`` is always
    non-interactive.

    The reapply itself (kit-apply) is deferred, so ``kit update`` records the
    user's *consent* to the pinned ref and reports ``consent recorded, reapply
    deferred``. It does NOT write ``applied_ref`` or report ``current``/``refreshed``:
    ``kit check`` keeps reading ``stale``/``unknown`` until the kit-apply slice
    actually reapplies (ADR-0038m §3 drops false partial success).
    """
    backend, exit_code = _resolve_backend_for_mutation(
        backend_override, emit_json, "kit update", domain="kit inspection"
    )
    if exit_code is not None:
        return exit_code
    name = parsed.name
    if not _adapter(backend).exists(name):
        return _operational_failure(
            "kit update",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
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
    if not parsed.yes:
        if emit_json or not sys.stdin.isatty():
            return _operational_failure(
                "kit update",
                errors.CONSENT_REQUIRED,
                f"refusing to refresh '{name}' non-interactively without --yes",
                f"re-run with 'acq kit update {name} --yes' to consent",
                emit_json,
            )
        answer = input(f"refresh the kit bundle in '{name}' to {kits.CONTROL_PLANE_REF}? [y/N] ")
        if answer.strip().lower() not in ("y", "yes"):
            if emit_json:
                print(json.dumps(envelope.success("kit update", {"sandbox": name, "backend": backend, "action": "cancelled"})))
            else:
                print("cancelled.")
            return errors.EXIT_SUCCESS
    # Consent recorded; the idempotent in-place reapply is the deferred kit-apply
    # slice. This is deliberately NOT applied provenance: applied_ref is unchanged,
    # so kit check keeps reporting stale/unknown rather than fabricating currency.
    rec = kits.consent_write(backend, name)
    data = {
        "sandbox": name,
        "backend": backend,
        "consented_ref": rec["consented_ref"],
        "status": "deferred",
        "action": "consent_recorded",
    }
    if emit_json:
        print(json.dumps(envelope.success("kit update", data)))
    else:
        print(f"consent recorded for '{name}' to {kits.CONTROL_PLANE_REF}; reapply deferred.")
    return errors.EXIT_SUCCESS


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
        return _usage_failure(
            "kit-source add",
            f"invalid repository: {parsed.repo!r} (want host/owner/repo)",
            emit_json,
        )
    if repo == kits.CONTROL_PLANE_REPO:
        return _operational_failure(
            "kit-source add",
            errors.VALIDATION_FAILED,
            "the built-in control-plane source is always trusted and cannot be re-added",
            "the control plane is the pinned trust anchor; add team/personal sources instead",
            emit_json,
        )
    ref = parsed.ref
    if not ref:
        return _usage_failure(
            "kit-source add",
            "kit-source add requires --ref <full-sha>",
            emit_json,
        )
    if not kits.is_full_ref(ref):
        return _operational_failure(
            "kit-source add",
            errors.KIT_REF_NOT_PINNED,
            f"kit source '{repo}' requires a full immutable ref (40/64-char SHA), got {ref!r}",
            "re-run with --ref <full-commit-sha>",
            emit_json,
        )
    directory = kits.normalize_dir(parsed.dir)
    if directory is None:
        return _usage_failure(
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
    # verb makes via _resolve_backend_for_mutation): `acq --backend bogus kit-source
    # rm` must reject the flag rather than silently dropping the registry entry.
    # Unlike the lifecycle verbs, kit-source rm is a host-side registry operation
    # that must still work with no backend installed, so only the flag is
    # validated here — the version floor and no-backend refusal do not apply.
    if backend_override is not None and backend_override not in backends.BACKENDS:
        return _usage_failure(
            "kit-source rm",
            f"unknown backend: {backend_override!r} (expected sbx or msb)",
            emit_json,
        )
    repo = kits.normalize_repo(parsed.repo)
    if repo is None:
        return _usage_failure(
            "kit-source rm",
            f"invalid repository: {parsed.repo!r} (want host/owner/repo)",
            emit_json,
        )
    if repo == kits.CONTROL_PLANE_REPO:
        return _operational_failure(
            "kit-source rm",
            errors.VALIDATION_FAILED,
            "the built-in control-plane source cannot be removed",
            "team/personal sources can be removed; the control plane is the pinned trust anchor",
            emit_json,
        )
    if kits.source_record(repo) is None:
        return _operational_failure(
            "kit-source rm",
            errors.KIT_SOURCE_NOT_FOUND,
            f"kit source '{repo}' is not registered",
            "list trusted sources with 'acq kit-source ls'",
            emit_json,
        )
    # sbx-only: revoke the source from sbx's kit.allowedSources BEFORE the host
    # record is dropped, so a failed revocation never strands a trusted source the
    # backend still fetches from (ADR-0040m ``kit_source_revoked``). Revocation
    # fires on the RESOLVED active backend (--backend flag → ACQ_BACKEND env →
    # auto-detect): whenever sbx is the backend in effect — selected explicitly OR
    # auto-detected as the sole installed backend — the owner prefix is dropped
    # from kit.allowedSources so the source is no longer fetchable. When the
    # resolved backend is msb (or there is no backend), only the host registry
    # entry is dropped, as before.
    # When both backends are installed with no flag/env, auto-detect resolves msb,
    # so sbx's owner prefix is not revoked here — correct under the resolved-active-
    # backend scope, and it becomes revocable once kit-apply (ADR-0030) lands.
    resolved = _resolve_active_backend(backend_override)
    if resolved == "sbx":
        try:
            sbx.kit_source_revoked(repo)
        except sbx.SbxError as exc:
            return _operational_failure("kit-source rm", exc.code, exc.message, exc.remediation, emit_json)
    kits.remove_source(repo)
    data = {"repository": repo, "removed": True}
    if emit_json:
        print(json.dumps(envelope.success("kit-source rm", data)))
    else:
        print(f"removed kit source '{repo}'.")
    return errors.EXIT_SUCCESS


def _passthrough(argv: list[str], explicit: str | None, emit_json: bool) -> int:
    """Forward an unknown subcommand verbatim to the active backend (ADR-0038m §1).

    The handoff is announced on stderr so the user knows any output/errors below
    the notice belong to the backend, not acq. The backend binary's exit status is
    preserved. Passthrough is a verbatim escape hatch: a successful handoff never
    emits an acq JSON envelope (the backend owns stdout, so ``--json`` is inert);
    only the no-backend failure follows acq's normal error contract.
    """
    verb = argv[0]
    name = _resolve_active_backend(explicit)
    if name is None:
        return _operational_failure(
            verb,
            errors.BACKEND_NOT_FOUND,
            "no sandbox backend detected",
            f"install msb {backends.MSB_MIN_VERSION[0]}.{backends.MSB_MIN_VERSION[1]}.{backends.MSB_MIN_VERSION[2]} or newer and retry",
            emit_json,
        )
    # The msb adapter honors ACQ_MSB_BIN (its test seam); sbx forwards to the raw
    # CLI. Either way the unknown verb + args are forwarded unchanged.
    if name == "msb":
        binary = msb.msb_command()
    else:
        binary = [backends.BACKENDS[name].cli]
    print(f"acq: '{verb}' is not an acq subcommand - forwarding to '{name}'.", file=sys.stderr)
    print(f"     (output and any errors below are from '{name}', not acq)", file=sys.stderr)
    return subprocess.run([*binary, *argv]).returncode


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
        return _operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
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
        return _passthrough(args, backend_override, emit_json)

    parser = build_parser()
    try:
        parsed = parser.parse_args(args)
    except UsageError as exc:
        return _usage_failure(None, str(exc), emit_json)

    if parsed.version or parsed.command == "version":
        # The `version` command lives in version_info.py (data + output), so a
        # version-output-only change never touches this dispatch (ADR-0044m).
        return version_info.run_version(emit_json)

    if parsed.command == "backend":
        if backend_override is not None and backend_override not in backends.BACKENDS:
            return _usage_failure(
                "backend",
                f"unknown backend: {backend_override!r} (expected sbx or msb)",
                emit_json,
            )
        if parsed.backend_command == "list":
            return run_backend_list(emit_json, _resolve_active_backend(backend_override))
        if parsed.backend_command == "check":
            return run_backend_check(emit_json, parsed.name)
        return _usage_failure(
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
        _backend, exit_code = _resolve_backend_for_lifecycle(backend_override, emit_json, parsed.command)
        if exit_code is not None:
            return exit_code
        if parsed.command == "create":
            return run_create(parsed, emit_json, _backend)
        if parsed.command == "run":
            return run_run(parsed, emit_json, _backend)
        if parsed.command == "ls":
            return run_ls(emit_json, _backend)
        if parsed.command == "stop":
            return run_stop(parsed, emit_json, _backend)
        if parsed.command == "rm":
            return run_rm(parsed, emit_json, _backend)
        if parsed.command == "exec":
            return run_exec(parsed, emit_json, _backend)
        if parsed.command == "attach":
            return run_attach(parsed, emit_json, _backend)
        if parsed.command == "shell":
            return run_shell(parsed, emit_json, _backend)
        if parsed.command == "cp":
            return run_cp(parsed, emit_json, _backend)
        if parsed.command == "ports":
            return run_ports(parsed, emit_json, _backend)

    if parsed.command == "secret":
        subcmd = parsed.secret_command
        if subcmd is None:
            return _usage_failure("secret", "secret requires a subcommand: set | rm | ls | has", emit_json)
        command = f"secret {subcmd}"
        # `secret has` is a silent predicate: it never emits a stdout body, so it
        # resolves the backend itself with emit_json=False (failures -> stderr).
        if subcmd == "has":
            return run_secret_has(parsed, backend_override)
        # argparse already refused an unknown choice, so subcmd is set|rm|ls here.
        _backend, exit_code = _resolve_backend_for_mutation(
            backend_override, emit_json, command, domain="secret management"
        )
        if exit_code is not None:
            return exit_code
        if subcmd == "set":
            return run_secret_set(parsed, emit_json, _backend)
        if subcmd == "rm":
            return run_secret_rm(parsed, emit_json, _backend)
        return run_secret_ls(parsed, emit_json, _backend)

    if parsed.command == "kit":
        subcmd = parsed.kit_command
        if subcmd is None:
            return _usage_failure("kit", "kit requires a subcommand: list | validate | apply | check | update", emit_json)
        if subcmd == "list":
            return run_kit_list(emit_json)
        if subcmd == "validate":
            return run_kit_validate(parsed, emit_json)
        if subcmd == "apply":
            return run_kit_apply(parsed, emit_json, backend_override)
        if subcmd == "check":
            return run_kit_check(parsed, emit_json, backend_override)
        if subcmd == "update":
            return run_kit_update(parsed, emit_json, backend_override)
        return _usage_failure(f"kit {subcmd}", f"unknown kit subcommand: {subcmd}", emit_json)

    if parsed.command == "kit-source":
        subcmd = parsed.kit_source_command
        if subcmd is None:
            return _usage_failure("kit-source", "kit-source requires a subcommand: add | ls | rm", emit_json)
        if subcmd == "add":
            return run_kit_source_add(parsed, emit_json)
        if subcmd == "ls":
            return run_kit_source_ls(emit_json)
        if subcmd == "rm":
            return run_kit_source_rm(parsed, emit_json, backend_override)
        return _usage_failure(f"kit-source {subcmd}", f"unknown kit-source subcommand: {subcmd}", emit_json)

    if parsed.command == "provider-credential":
        subcmd = parsed.provider_credential_command
        if subcmd is None:
            return _usage_failure("provider-credential", "provider-credential requires a subcommand: set | ls | rm", emit_json)
        # ls/rm read and mutate host-side binding records only; only `set` moves a
        # value across the backend boundary and therefore needs a backend.
        if subcmd == "ls":
            return run_provider_credential_ls(emit_json)
        if subcmd == "rm":
            return run_provider_credential_rm(parsed, emit_json)
        _backend, exit_code = _resolve_backend_for_mutation(
            backend_override, emit_json, "provider-credential set", domain="provider credentials",
            capability="provider-credential-set",
        )
        if exit_code is not None:
            return exit_code
        return run_provider_credential_set(parsed, emit_json, _backend)

    if parsed.command == "github-scope":
        _backend, exit_code = _resolve_backend_for_mutation(
            backend_override, emit_json, "github-scope", domain="provider credentials"
        )
        if exit_code is not None:
            return exit_code
        return run_github_scope(parsed, emit_json, _backend)

    if parsed.command == "usai-rotate-api-key":
        _backend, exit_code = _resolve_backend_for_mutation(
            backend_override, emit_json, "usai-rotate-api-key", domain="provider credentials"
        )
        if exit_code is not None:
            return exit_code
        return run_usai_rotate_api_key(emit_json, _backend)

    if parsed.command == "help" or parsed.command is None:
        parser.print_help()
        return errors.EXIT_SUCCESS

    return _usage_failure(parsed.command, f"unknown command: {parsed.command}", emit_json)
