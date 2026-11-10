"""Read the Bash acq's host state, for the forward migration (ADR-0041m).

The Bash acq keeps per-sandbox state as small files under its provenance root
(:func:`state.provenance_dir`), keyed by backend and by the sandbox name's
sanitized form plus its POSIX ``cksum`` (``_acq_provenance_file`` in
``acq.backends/common.sh``):

* ``<backend>/<key>.env`` — ``key=value`` lines: ``agent``, ``workspace`` (with
  ``workspace_source=host``), ``applied_ref``, ``applied_at`` and others;
* ``<backend>/<key>.config/`` — one file per key (``acq_host_config_write``):
  ``agent``, ``workspace``, ``ro-host-config``, ``ssh-auth-sock`` and others;
* ``<backend>/<key>.kits`` — the ``--kit`` and extra kit refs
  (``acq_cli_kits_write``).

Its user configuration lives in flat ``config.yaml`` keys: ``kit_sources``,
``provider_credential_bindings``, ``provider_kit`` and ``extra_kits``.

Everything here only reads. Nothing is trusted beyond what the Bash readers
themselves accept: each field is checked against the grammar Bash validates it
with, and a value that fails is treated as absent. The one exception is the
provider selection, which Bash refuses rather than ignores when it holds a
value Bash never writes: it is carried over as is, so the Python acq refuses it
the same way. These files are written by
acq on the host, never by a guest.
"""

from __future__ import annotations

import contextlib
import re
import sys
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

from . import config, kits, lock, provider_creds, userdirs

# The suffixes of the per-sandbox files, as Bash names them.
ENV_SUFFIX = ".env"
CONFIG_SUFFIX = ".config"
KITS_SUFFIX = ".kits"

# Bash's own guards: ``acq_provenance_write`` keeps an agent only in [a-z-];
# ``_acq_host_config_key_ok`` limits key names; the msb adapter accepts a guest
# ssh-agent socket only as an absolute path in a word-safe charset.
_AGENT_RE = re.compile(r"[a-z-]+")
_CONFIG_KEY_RE = re.compile(r"[A-Za-z0-9._-]+")
_GUEST_SOCK_RE = re.compile(r"/[A-Za-z0-9._/-]*")
_REF_RE = re.compile(r"[A-Za-z0-9_.-]*")
_APPLIED_REF_RE = re.compile(r"[A-Za-z0-9_.-]+")
# Digits are ASCII only: ``\d`` also matches other scripts' digits.
_APPLIED_AT_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
_KEY_STEM_RE = re.compile(r"(?P<safe>[A-Za-z0-9._-]+)\.(?P<sum>[0-9]+)")

_SAFE_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

# The ``kit_sources`` spelling for "no trusted sources" (``acq_kit_sources_entries``).
_NO_SOURCES = ("none", "NONE", "None")


class LegacyParseError(ValueError):
    """A Bash config value the Bash acq itself would refuse to use."""


# A credential written into a kit source as URL userinfo without a scheme
# (``bob:TOKEN@github.com/acme/kits``): a token, at the start of a word or
# after a quote, whose ``@`` is followed by a host and a ``/``.
_SCHEMELESS_USERINFO_RE = re.compile(r"(?:(?<=^)|(?<=[\s'\"(=,]))[^\s'\"/@]+@(?=[^\s'\"/@]+/)")
# A recorded kit path quoted back as it is: plain path characters only.
_PLAIN_PATH_RE = re.compile(r"[A-Za-z0-9._/-]{1,200}")
# A query string in a URL (``https://host/repo?token=...``).
_URL_QUERY_RE = re.compile(r"(://[^\s'\"?]*)\?[^\s'\"]*")


def redact(text: str) -> str:
    """``text`` with URL credentials hidden: userinfo becomes ``***@`` and a query ``?***``.

    Bash config values end up in warnings that are printed and kept in the
    migration marker (``acq doctor`` shows them again), so a token pasted into
    a kit source must never be quoted back. Applied to each value quoted in a
    message and again to every message :func:`warn` is given.
    """
    text = kits.redact_userinfo(text)
    text = _SCHEMELESS_USERINFO_RE.sub("***@", text)
    return _URL_QUERY_RE.sub(r"\1?***", text)


@dataclass(frozen=True)
class BashSandbox:
    """What the Bash acq recorded for one sandbox (fields absent when not recorded)."""

    backend: str
    name: str
    agent: str | None = None
    workspace: str | None = None
    ro_host_config: bool = False
    ssh_auth_sock: str | None = None
    applied_ref: str | None = None
    applied_at: str | None = None
    # As Bash ``acq_provenance_write`` recorded them; None when the record
    # predates them. A ``provider_selection`` Bash never writes is kept as is,
    # so the imported record is refused where Bash refuses it.
    provider_selection: str | None = None
    provider_kits: str | None = None


# ---------------------------------------------------------------------------
# Paths (``_acq_provenance_file``, ``acq_host_config_dir``, ``_acq_cli_kits_file``).
# ---------------------------------------------------------------------------

def posix_cksum(data: bytes) -> int:
    """The POSIX ``cksum`` CRC of ``data``, as Bash's name keys use it."""
    return lock.posix_cksum(data)


def sandbox_key(name: str) -> str:
    """The per-sandbox filename stem: ``tr -c 'A-Za-z0-9._-' '_'`` of the name, a dot, its cksum."""
    return lock.bash_sandbox_key(name)


def _bash_safe(token: str) -> str:
    """``tr -c 'A-Za-z0-9._-' '_'``: every other UTF-8 byte becomes ``_``."""
    return "".join(chr(b) if chr(b) in _SAFE_CHARS else "_" for b in token.encode("utf-8"))


def _backend_dir(backend: str) -> Path:
    return lock.bash_provenance_dir() / _bash_safe(backend)


def provenance_file(backend: str, name: str) -> Path:
    return _backend_dir(backend) / f"{sandbox_key(name)}{ENV_SUFFIX}"


def host_config_dir(backend: str, name: str) -> Path:
    return _backend_dir(backend) / f"{sandbox_key(name)}{CONFIG_SUFFIX}"


def cli_kits_file(backend: str, name: str) -> Path:
    return _backend_dir(backend) / f"{sandbox_key(name)}{KITS_SUFFIX}"


# ---------------------------------------------------------------------------
# Per-sandbox readers.
# ---------------------------------------------------------------------------

def parse_env(text: str) -> dict[str, str]:
    """Parse a ``.env`` record; the first line for a key wins (``acq_provenance_field``).

    Lines are split on ``\\n`` only, as awk splits records: a ``\\r`` or another
    character ``str.splitlines`` would treat as a line break stays in the value.
    """
    out: dict[str, str] = {}
    for line in text.split("\n"):
        key, sep, value = line.partition("=")
        if sep and key not in out:
            out[key] = value
    return out


def read_env(backend: str, name: str) -> dict[str, str]:
    """A sandbox's ``.env`` record as a dict (empty when absent or unreadable)."""
    try:
        return parse_env(provenance_file(backend, name).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError):
        return {}


def provenance_field(backend: str, name: str, field: str) -> str | None:
    """One ``.env`` field (``acq_provenance_field``); ``None`` when absent or empty."""
    return read_env(backend, name).get(field) or None


def workspace_record_read(backend: str, name: str) -> str | None:
    """The recorded host workspace, only when ``workspace_source=host`` (``acq_workspace_record_read``)."""
    env = read_env(backend, name)
    if env.get("workspace_source") != "host":
        return None
    return env.get("workspace") or None


def host_config_read(backend: str, name: str, key: str) -> str | None:
    """One host-config key's raw value (``acq_host_config_read``); ``None`` when absent."""
    if key in (".", "..") or not _CONFIG_KEY_RE.fullmatch(key):
        return None
    path = host_config_dir(backend, name) / key
    try:
        if not path.is_file():
            return None
        return path.read_bytes().decode("utf-8", "surrogateescape")
    except OSError:
        return None


def _is_absolute_ref(value: str) -> bool:
    return value.startswith(("git+http", "/")) or bool(re.match(r"[A-Za-z]:[/\\]", value))


def read_cli_kits(
    backend: str, name: str, warn: Callable[[str], None] | None = None
) -> tuple[list[str], list[str]] | None:
    """The recorded ``(--kit refs, extra refs)`` (``acq_cli_kits_load``); ``None`` with no record.

    A relative local ref left by an older Bash acq would resolve against the
    current directory, so it is skipped (with ``warn``), as Bash does.
    """
    try:
        text = cli_kits_file(backend, name).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    cli: list[str] = []
    extras: list[str] = []
    for line in text.splitlines():
        key, _, value = line.partition("=")
        if key not in ("kit", "extra") or not value:
            continue
        if not _is_absolute_ref(value):
            if warn is not None:
                shown = _shown(value, lambda v: bool(_PLAIN_PATH_RE.fullmatch(v)))
                warn(f"ignoring recorded relative kit path {shown} for {name}")
            continue
        if kits.remote_ref_problem(value) is not None:
            # A ref acq now refuses at input is skipped without being named.
            if warn is not None:
                warn(f"ignoring a recorded remote kit ref for {name} that acq now refuses (a query string, "
                     "or a '#' parameter other than ref= and dir=); it is no longer applied")
            continue
        (cli if key == "kit" else extras).append(value)
    return cli, extras


def _sandbox_name(stem: str) -> str | None:
    """The sandbox name a ``<safe>.<cksum>`` stem stands for, or ``None``.

    The raw name is recoverable only when sanitizing left it unchanged, which
    the cksum confirms. acq's own names (``[a-z0-9-]``) always qualify; a
    hand-made name with other characters cannot be recovered and is skipped.
    """
    match = _KEY_STEM_RE.fullmatch(stem)
    if match is None:
        return None
    safe = match.group("safe")
    if str(posix_cksum(safe.encode("utf-8"))) != match.group("sum"):
        return None
    return safe


def sandbox_names(backend: str) -> list[str]:
    """Every sandbox name with a Bash ``.env``, ``.config`` or ``.kits`` record, sorted.

    A backend directory that does not exist (or is not a directory) has no
    records. Any other error reading it (``EACCES``, say) raises ``OSError``:
    reading it as "no records" would let the import record itself complete
    with nothing imported, and never look again.
    """
    directory = _backend_dir(backend)
    try:
        entries = list(directory.iterdir())
    except (FileNotFoundError, NotADirectoryError):
        return []
    names: set[str] = set()
    for entry in entries:
        for suffix in (ENV_SUFFIX, CONFIG_SUFFIX, KITS_SUFFIX):
            if entry.name.endswith(suffix):
                name = _sandbox_name(entry.name[: -len(suffix)])
                if name is not None:
                    names.add(name)
    return sorted(names)


def _command_substitution(value: str | None) -> str | None:
    """``value`` as Bash's ``$(...)`` would yield it: trailing newlines removed."""
    return value.rstrip("\n") if value is not None else None


def _clean(value: str | None) -> str | None:
    return value.strip() if value and value.strip() else None


def _workspace(backend: str, name: str) -> str | None:
    """The host workspace, kept only if it is one line and an absolute path on this host."""
    value = workspace_record_read(backend, name)
    if value is None or any(ch in value for ch in "\n\r\t\0") or not userdirs.is_absolute(value):
        return None
    return value


def read_sandbox(backend: str, name: str) -> BashSandbox:
    """Everything the Bash acq recorded for one sandbox, each field checked as Bash checks it."""
    env = read_env(backend, name)
    agent = env.get("agent") or _clean(host_config_read(backend, name, "agent"))
    sock = _clean(host_config_read(backend, name, "ssh-auth-sock"))
    applied_ref = env.get("applied_ref")
    applied_at = env.get("applied_at")
    # A value Bash never writes is kept as it is, not dropped: Bash
    # ``acq_provider_selection_load`` refuses it, and so does the Python reader
    # of the imported record, whereas no record would apply the current selection.
    selection = env.get("provider_selection") or None
    provider_kits = env.get("provider_kits") if selection == kits.SELECTION_EXPLICIT else None
    if provider_kits is not None and "\0" in provider_kits:
        selection = provider_kits = None  # cannot be an environment value: import nothing
    return BashSandbox(
        backend=backend,
        name=name,
        agent=agent if agent and _AGENT_RE.fullmatch(agent) else None,
        workspace=_workspace(backend, name),
        ro_host_config=_command_substitution(host_config_read(backend, name, "ro-host-config")) == "1",
        ssh_auth_sock=sock if sock and _GUEST_SOCK_RE.fullmatch(sock) else None,
        applied_ref=applied_ref if applied_ref and _APPLIED_REF_RE.fullmatch(applied_ref) else None,
        applied_at=applied_at if applied_at and _APPLIED_AT_RE.fullmatch(applied_at) else None,
        provider_selection=selection,
        provider_kits=provider_kits or None,
    )


# ---------------------------------------------------------------------------
# config.yaml keys.
# ---------------------------------------------------------------------------

# What a refusal of a Bash config value quotes in place of a part that does not
# have the expected shape. These refusals become import warnings that are
# printed, kept in the migration marker and shown by ``acq doctor``, and a
# malformed part is exactly where a pasted token ends up (a key typed where the
# env var name belongs, say), so only parts with the expected shape (a provider
# id, an env var name, a host name, a normalized repository) are ever quoted.
REDACTED = "<redacted>"


def _shown(value: str, ok: Callable[[str], bool]) -> str:
    """``'value'`` when ``ok(value)``, else :data:`REDACTED`."""
    return f"'{value}'" if ok(value) else REDACTED


# Prefixes of common access tokens (GitHub, GitLab, OpenAI-style, Slack).
_TOKEN_PREFIXES = ("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "sk-", "xox")


def _plausible_ref(ref: str) -> bool:
    """True for a ref that looks like a branch, tag or short commit, not a pasted token.

    ``_REF_RE`` admits any word-ish string, a token included; a ref is quoted
    back only when it is at most 40 characters and does not start like a
    common access token. An empty ref (no ref at all) is shown as ``''``.
    """
    return len(ref) <= 40 and not ref.lower().startswith(_TOKEN_PREFIXES)


def shown_ref(ref: str) -> str:
    """A kit-source ref as a warning may quote it: ``'ref'``, or :data:`REDACTED` when it may be a token."""
    return _shown(ref, _plausible_ref)


def parse_kit_source_entry(entry: str) -> tuple[str, str, str]:
    """``_acq_kit_source_parse_entry``: ``repo[@REF][|DIR]`` to ``(repo, ref, dir)``.

    An entry for the shipped control plane without a ref follows the shipped
    pin, as in Bash. Raises :class:`LegacyParseError` where Bash refuses; its
    message quotes only the normalized repository, never the part refused.
    """
    rest, _, directory = entry.partition("|")
    rest, _, ref = rest.partition("@")
    repo = kits.normalize_repo(rest) if rest == rest.strip() else None
    if not entry or repo is None or len(repo) > 200:
        raise LegacyParseError(f"invalid kit source {REDACTED} (want host/owner/repo[@ref][|dir])")
    if not _REF_RE.fullmatch(ref):
        raise LegacyParseError(f"invalid ref {REDACTED} for '{repo}'")
    if not ref and repo == kits.CONTROL_PLANE_REPO:
        ref = kits.CONTROL_PLANE_REF
    normalized = kits.normalize_dir(directory or None)
    if normalized is None:
        raise LegacyParseError(f"unsafe kit dir {REDACTED} for '{repo}'")
    return repo, ref, normalized


def kit_sources() -> list[tuple[str, str, str]]:
    """The ``kit_sources`` entries (``acq_kit_sources_entries`` without the env override).

    An absent key reads as no entries, as does the explicit ``none``. One bad
    entry makes Bash refuse the whole list, so this raises
    :class:`LegacyParseError` rather than returning part of it, naming the
    entry by its position, since its value is not quoted.
    """
    raw = config.read_field("kit_sources")
    if raw is None or raw in _NO_SOURCES:
        return []
    out = []
    for number, token in enumerate(raw.split(), 1):
        try:
            out.append(parse_kit_source_entry(token))
        except LegacyParseError as exc:
            raise LegacyParseError(f"entry {number}: {exc}") from None
    return out


def _parse_hosts(provider: str, hosts: str) -> list[str]:
    """Split ``h1,h2``: like Bash's comma word-split, a trailing comma is ignored."""
    parts = hosts.split(",")
    if parts and parts[-1] == "":
        parts.pop()
    if any(part == "" for part in parts):
        raise LegacyParseError(f"empty host for provider {_shown(provider, provider_creds.provider_id_ok)}")
    return parts


def _binding_problem(provider: str, key_env: str, hosts: list[str]) -> str | None:
    """:func:`provider_creds.validate_binding` for an imported binding, quoting only well-formed parts.

    The checks are validate_binding's. A malformed provider id, env var name or
    host is never quoted; once the provider id and env var name have their
    shape, validate_binding's own message (which quotes only those two) is safe.
    """
    if not provider_creds.provider_id_ok(provider):
        return f"invalid provider id {REDACTED}; want ^[a-z0-9]([a-z0-9-]{{0,30}}[a-z0-9])?$"
    if not provider_creds.key_env_ok(key_env):
        return f"invalid KEY_ENV {REDACTED} for provider '{provider}'; want an upper-case env var name"
    if any(not provider_creds.host_ok(host) for host in hosts):
        owner = provider_creds.key_env_owner(key_env)
        if owner is None or owner == provider:  # validate_binding would report the host, by value
            return f"invalid host {REDACTED} for provider '{provider}'; want a bare DNS name such as models.example.gov"
    return provider_creds.validate_binding(provider, key_env, [h for h in hosts if provider_creds.host_ok(h)])


def parse_provider_credential_pairs(pairs: str) -> list[tuple[str, str, list[str]]]:
    """``_acq_provider_credential_parse_pairs``: ``id=KEY_ENV[@h1[,h2]]`` tokens.

    Raises :class:`LegacyParseError` for the first malformed token, as Bash
    fails the whole list. The message names the entry by its position and
    quotes only well-formed parts of it (see :data:`REDACTED`).
    """
    out: list[tuple[str, str, list[str]]] = []
    for number, token in enumerate(pairs.split(), 1):
        if "=" not in token:
            raise LegacyParseError(f"entry {number}: expected '<providerId>=<KEY_ENV>', got {REDACTED}")
        provider, _, rest = token.partition("=")
        key_env, at, hosts = rest.partition("@")
        if "=" in key_env:
            raise LegacyParseError(f"entry {number}: provider {_shown(provider, provider_creds.provider_id_ok)} "
                                   f"has a malformed credential name {REDACTED}")
        try:
            host_list = _parse_hosts(provider, hosts) if at else []
        except LegacyParseError as exc:
            raise LegacyParseError(f"entry {number}: {exc}") from None
        problem = _binding_problem(provider, key_env, host_list)
        if problem is not None:
            raise LegacyParseError(f"entry {number}: {problem}")
        out.append((provider, key_env, host_list))
    return out


def provider_credential_bindings() -> list[tuple[str, str, list[str]]]:
    """The ``provider_credential_bindings`` config key, parsed (empty when absent).

    A provider listed more than once keeps its LAST entry, as Bash's
    ``acq_provider_credential_lookup`` does.
    """
    pairs = parse_provider_credential_pairs(config.read_field("provider_credential_bindings") or "")
    last = {provider: (provider, key_env, hosts) for provider, key_env, hosts in pairs}
    return list(last.values())


def provider_kit() -> str | None:
    """The ``provider_kit`` config key. The Python acq reads it in place (``kitspec``)."""
    return config.read_field("provider_kit")


def extra_kits() -> list[str]:
    """The ``extra_kits`` config key, split. The Python acq reads it in place (``kitspec``)."""
    return (config.read_field("extra_kits") or "").split()


# Where :func:`warn` puts its messages while :func:`collecting_warnings` is
# active, instead of printing them.
_collected: list[str] | None = None


def warn(message: str) -> None:
    """Print ``message`` as a warning, or collect it (see :func:`collecting_warnings`), redacted either way."""
    message = redact(message)
    if _collected is not None:
        _collected.append(message)
        return
    print(f"acq: warning: {message}", file=sys.stderr)


@contextlib.contextmanager
def collecting_warnings() -> Iterator[list[str]]:
    """Collect the messages :func:`warn` is given in the block, unprinted, for the caller to print."""
    global _collected
    previous, _collected = _collected, []
    try:
        yield _collected
    finally:
        _collected = previous
