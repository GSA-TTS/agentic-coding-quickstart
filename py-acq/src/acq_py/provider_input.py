"""Provider-role kit inputs: facts, destination pins, the read-only provider-input
generation, and the attach-time key check (ADR-0030, ADR-0035, ADR-0012).

A port of the provider path in ``acq.backends/common.sh``:

* :func:`kit_facts` reads a provider kit's ``provider-input.json`` manifest and
  its ``facts.json`` (``acq_provider_facts_json_fields``), with no-follow reads
  confined to the kit directory, and validates every field: the facts reach a
  ``--secret ENV@HOST`` binding and an in-guest probe.
* :func:`check_pin` is the trust check (``_acq_provider_credentials_gate_trust``):
  a kit may name any provider id and any host, so acq sends a stored credential
  only to a host pinned for that provider (the provider-credential registry, or
  the shipped usai trust anchor). A kit whose facts name another host, or
  another key variable, is refused.
* :func:`gate` is the pre-create credential gate
  (``acq_provider_credentials_gate``): msb binds secrets only at create, so a
  missing key is either stored now (on a terminal, after asking) or the create
  fails closed.
* :func:`prepare` / :func:`publish` / :func:`discard` stage the immutable
  provider-input generation the OpenCode kit's startup renderer reads at
  ``ACQ_PROVIDER_INPUT_ROOT`` (``acq_provider_input_prepare``,
  ``_acq_provider_input_materialize``, ``_acq_provider_input_publish``). It has
  its own host root and guest mount, never the host-config directory, which
  holds workspace, SSH and kit state.
* :func:`check_keys` is ``ensure_valid_provider_keys``: before an attach, each
  recorded provider's key is probed from inside the sandbox against its own
  models URL, and a failure fails closed with ``provider_unreachable`` or
  ``provider_auth_failed``.
* :func:`delivery_ids` is ``acq_provider_delivery_ids``: which providers a
  sandbox's create binds, honouring provider selection.

Layouts match Bash (``<provenance>/provider-input/<backend>/<key>`` and the
host-config ``provider-credentials`` record), so both implementations read the
same files. No credential value passes through this module.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import tempfile
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path

from . import errors, kitspec, lock, provider_creds, state

GUEST_DIR = "/var/lib/acq/provider-input"
ROOT_ENV = "ACQ_PROVIDER_INPUT_ROOT"
RECORD_KEY = "provider-credentials"
MANIFEST = "provider-input.json"
BUNDLE_SCHEMA = "acq-provider-input-bundle/v2"
FACTS_SCHEMA = "acq-provider-facts/v1"
# Ids a backend binds from compiled-in tables: never resolved from kit facts,
# probed at a kit-chosen host, or bound there (``_acq_provider_is_host_service``).
HOST_SERVICES = frozenset({"github"})

_PROTOCOL_RE = re.compile(r"[A-Za-z0-9._-]+")
# Bash ``_acq_provider_fact_strict_url_ok``: URL punctuation only, and none of
# the characters a shell (or a query string smuggling a second URL) gives meaning.
_URL_RE = re.compile(r"https://[A-Za-z0-9._~:/?%=+,@-]+")
_FACT_FIELDS = ("providerId", "keyEnv", "host", "modelsUrl", "apiProtocol")
_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
_O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
_O_NONBLOCK = getattr(os, "O_NONBLOCK", 0)
_REPARSE = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)


class ProviderInputError(Exception):
    """A provider input or credential refusal with a stable error code."""

    def __init__(self, code: str, message: str, remediation: str):
        super().__init__(message)
        self.code = code
        self.message = message
        self.remediation = remediation


def _invalid(message: str, remediation: str = "reinstall acq; it will not use provider input it cannot verify") -> ProviderInputError:
    return ProviderInputError(errors.VALIDATION_FAILED, message, remediation)


@dataclass(frozen=True)
class Facts:
    """One provider's validated facts (never a credential value)."""

    provider: str
    key_env: str
    host: str
    models_url: str
    api_protocol: str

    def record(self) -> str:
        """Bash's TAB-separated ``provider-credentials`` record line."""
        return "\t".join((self.provider, self.key_env, self.host, self.models_url, self.api_protocol))


def strict_url_ok(url: str, host: str) -> bool:
    """True when ``url`` is an https URL on exactly ``host`` (port 443 at most)."""
    if not _URL_RE.fullmatch(url):
        return False
    return url == f"https://{host}" or url.startswith((f"https://{host}/", f"https://{host}:443/"))


def facts_problem(f: Facts) -> str | None:
    """Why ``f`` must not be used, or None (Bash's re-validation of every field)."""
    if not provider_creds.provider_id_ok(f.provider):
        return f"invalid provider id {f.provider!r}"
    problem = provider_creds.validate_binding(f.provider, f.key_env, [f.host])
    if problem is not None:
        return problem
    if not strict_url_ok(f.models_url, f.host):
        return f"provider '{f.provider}' models URL does not match its declared host ({f.host})"
    if not _PROTOCOL_RE.fullmatch(f.api_protocol):
        return f"provider '{f.provider}' declares an unsafe API protocol"
    return None


# ---------------------------------------------------------------------------
# No-follow reads confined to a kit directory.
# ---------------------------------------------------------------------------


def _parts(rel: object) -> list[str]:
    if not isinstance(rel, str) or not rel or rel.startswith("/") or "\\" in rel or ":" in rel:
        raise _invalid(f"unsafe provider artifact path {rel!r}")
    parts = rel.split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise _invalid(f"unsafe provider artifact path {rel!r}")
    return parts


def _read_fd(root: Path, parts: list[str]) -> tuple[bytes, int]:
    """Descriptor-relative walk with ``O_NOFOLLOW`` at every step (POSIX)."""
    fd = os.open(root, os.O_RDONLY | _O_DIRECTORY | _O_NOFOLLOW)
    try:
        for index, part in enumerate(parts):
            # Directories must be directories; the file is opened non-blocking so
            # a FIFO planted in its place cannot hang the read before fstat refuses it.
            last = index == len(parts) - 1
            flags = os.O_RDONLY | _O_NOFOLLOW | (_O_NONBLOCK if last else _O_DIRECTORY)
            nxt = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = nxt
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise _invalid("unsafe provider artifact: not a regular file")
        with os.fdopen(fd, "rb") as fh:
            fd = -1
            return fh.read(), stat.S_IMODE(info.st_mode)
    finally:
        if fd >= 0:
            os.close(fd)


def _read_lstat(root: Path, parts: list[str]) -> tuple[bytes, int]:
    """Component-by-component ``lstat`` walk refusing links and reparse points (Windows)."""
    path = root
    for index, part in enumerate([None, *parts]):
        if part is not None:
            path = path / part
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & _REPARSE:
            raise _invalid("unsafe provider artifact: a link in its path")
        last = index == len(parts)
        if (last and not stat.S_ISREG(info.st_mode)) or (not last and not stat.S_ISDIR(info.st_mode)):
            raise _invalid("unsafe provider artifact: not a regular file")
    with open(path, "rb") as fh:
        return fh.read(), stat.S_IMODE(info.st_mode)


def read_member(root: Path, rel: str) -> bytes:
    """Read ``root/rel`` without following any link; raises :class:`ProviderInputError`."""
    parts = _parts(rel)
    try:
        if _O_NOFOLLOW and os.open in os.supports_dir_fd:
            return _read_fd(root, parts)[0]
        return _read_lstat(root, parts)[0]
    except OSError as exc:
        raise _invalid(f"cannot read provider artifact {rel!r}: {exc.strerror or exc}") from exc


def _json_member(root: Path, rel: str) -> dict:
    try:
        doc = json.loads(read_member(root, rel).decode("utf-8"))
    except (UnicodeError, ValueError) as exc:
        raise _invalid(f"invalid provider input {rel!r}: not a JSON document") from exc
    if not isinstance(doc, dict):
        raise _invalid(f"invalid provider input {rel!r}: not a JSON object")
    return doc


# ---------------------------------------------------------------------------
# Manifest and facts.
# ---------------------------------------------------------------------------


def _manifest_ok(manifest: dict) -> str:
    """The manifest's provider id, after the materialiser's layout checks."""
    provider = manifest.get("providerId")
    if not isinstance(provider, str) or not provider_creds.provider_id_ok(provider):
        raise _invalid("unsafe provider ID in provider-input.json")
    if manifest.get("schemaVersion") != BUNDLE_SCHEMA or manifest.get("providerPath") != f"models/providers/{provider}":
        raise _invalid(f"unsafe provider bundle layout for '{provider}'")
    for key in ("factsPath", "snapshotPath"):
        _parts(manifest.get(key))
    return provider


def _facts_from(doc: dict, provider: str) -> Facts:
    values = [doc.get(name) for name in _FACT_FIELDS]
    if doc.get("schemaVersion") != FACTS_SCHEMA or not all(isinstance(v, str) and v for v in values):
        raise _invalid(f"invalid provider facts for '{provider}'")
    if any(ch in str(v) for v in values for ch in "\t\r\n"):
        raise _invalid(f"invalid provider facts for '{provider}'")
    facts = Facts(*(str(v) for v in values))
    if facts.provider != provider:
        raise _invalid(f"provider facts name '{facts.provider}', but the manifest names '{provider}'")
    problem = facts_problem(facts)
    if problem is not None:
        raise _invalid(f"invalid provider facts: {problem}")
    return facts


def kit_facts(kit_root: Path) -> tuple[dict, Facts] | None:
    """``(manifest, facts)`` for a provider-role kit, None for a kit with no manifest.

    A manifest that exists but is a link, unreadable or invalid is refused, never
    read as "not a provider kit".
    """
    try:
        os.lstat(kit_root / MANIFEST)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise _invalid(f"cannot read the provider input manifest: {exc.strerror or exc}") from exc
    manifest = _json_member(kit_root, MANIFEST)
    provider = _manifest_ok(manifest)
    return manifest, _facts_from(_json_member(kit_root, manifest["factsPath"]), provider)


def selected_facts(kit_names: Iterable[str], bundle_dir: Path | None = None) -> list[tuple[str, dict, Facts]]:
    """``(kit, manifest, facts)`` for every selected kit that carries provider input.

    Two kits declaring the same provider id are refused (the materialiser's
    duplicate-target rule).
    """
    root = bundle_dir or kitspec.BUNDLE_DIR
    out: list[tuple[str, dict, Facts]] = []
    for kit in kit_names:
        found = kit_facts(root / kit)
        if found is None:
            continue
        if any(f.provider == found[1].provider for _k, _m, f in out):
            raise _invalid(f"two selected kits declare provider '{found[1].provider}'", "select one provider kit per provider")
        out.append((kit, *found))
    return out


# ---------------------------------------------------------------------------
# Destination pins (the trust check).
# ---------------------------------------------------------------------------


def _repin(provider: str, key_env: str, host: str) -> str:
    return f"if that host is legitimate, re-pin it explicitly: acq provider-credential set {provider} {key_env} --host {host}"


def check_pin(f: Facts) -> None:
    """Refuse facts whose host (or key variable) is not the provider's pin.

    The pin comes from the provider-credential registry (the per-invocation env
    layer, then the durable record), else the shipped usai trust anchor. A
    provider with no pin, or a malformed one, is refused: acq never sends a
    stored credential to a host chosen by a kit.
    """
    pinned = provider_creds.provider_env_hosts(f.provider)
    if pinned is None:
        raise _invalid(
            f"provider '{f.provider}' is not pinned to a host (its kit declares '{f.host}'); "
            "acq will not send a stored credential to a host chosen by a kit",
            f"pin it explicitly, then retry: acq provider-credential set {f.provider} {f.key_env} --host {f.host}",
        )
    key_env, hosts = pinned
    if f.host not in hosts.split(","):
        raise _invalid(
            f"provider '{f.provider}' declares host '{f.host}', which is not one of its pinned hosts "
            f"({hosts}); refusing to send the stored credential there",
            _repin(f.provider, key_env, f.host),
        )
    if f.key_env != key_env:
        raise _invalid(
            f"provider '{f.provider}' declares credential variable {f.key_env}, but its pin binds {key_env}",
            _repin(f.provider, f.key_env, f.host),
        )


# ---------------------------------------------------------------------------
# The pre-create credential gate.
# ---------------------------------------------------------------------------


# Why a key must exist before the create, per backend.
_AT_CREATE = {
    "msb": "msb binds credentials only at create",
    "sbx": "sbx snapshots its proxy table at create",
}


def _missing(f: Facts, backend: str, *, exported: bool, stored: bool) -> ProviderInputError:
    why = _AT_CREATE.get(backend, f"the {backend} backend binds credentials only at create")
    if stored:
        return ProviderInputError(
            errors.SECRET_MISSING,
            f"the '{f.provider}' key is stored, but the {backend} backend cannot inject it for '{f.host}' yet; "
            f"the sandbox would be created without it, because {why}",
            f"re-store it so the binding is created: acq secret set -g {f.provider}",
        )
    detail = (
        f"${f.key_env} is exported on the host, but acq binds only stored credentials"
        if exported else f"no key is stored for provider '{f.provider}' (${f.key_env})"
    )
    return ProviderInputError(
        errors.SECRET_MISSING,
        f"{detail}; the sandbox would be created without it, because {why}",
        f"store it with 'acq secret set -g {f.provider}', then retry",
    )


def gate(
    facts: Iterable[Facts],
    *,
    has_key: Callable[[str], bool],
    ask_store: Callable[[Facts], bool] | None,
    backend: str = "msb",
    stored: Callable[[str], bool] = lambda _provider: False,
) -> None:
    """Check every provider's pin and key before a create; raises :class:`ProviderInputError`.

    ``has_key(provider)`` says whether the backend can inject a stored key.
    ``ask_store(facts)`` asks on a terminal and stores a key, returning False
    when the user declines; it is None when there is no terminal, and the gate
    then fails closed instead of prompting. ``stored(provider)`` says whether
    the acq store holds a key the backend cannot inject (the message then asks
    for it to be re-stored).
    """
    for f in facts:
        if f.provider in HOST_SERVICES:
            continue
        check_pin(f)
        if has_key(f.provider):
            continue
        if ask_store is None:
            raise _missing(f, backend, exported=bool(os.environ.get(f.key_env)), stored=stored(f.provider))
        if not ask_store(f):
            raise ProviderInputError(
                errors.SECRET_MISSING,
                f"no key stored for provider '{f.provider}'; the create was abandoned",
                f"store it with 'acq secret set -g {f.provider}', then retry",
            )
        if not has_key(f.provider):
            raise ProviderInputError(
                errors.SECRET_MISSING,
                f"the '{f.provider}' key is still not injectable",
                f"store it with 'acq secret set -g {f.provider}', then retry",
            )


# ---------------------------------------------------------------------------
# Provider selection (acq_provider_delivery_ids).
# ---------------------------------------------------------------------------


def _selected_refs(env: Mapping[str, str]) -> list[str] | None:
    try:
        return kitspec.provider_kit_refs(env)
    except kitspec.KitSelectionError:
        return None


def default_selected(env: Mapping[str, str] | None = None) -> bool:
    """True when the default provider kit is among the selected provider kits."""
    env = os.environ if env is None else env
    refs = _selected_refs(env)
    try:
        return refs is not None and kitspec.provider_kit_ref(env) in refs
    except kitspec.KitSelectionError:
        return False


def registry_ids(env: Mapping[str, str] | None = None) -> list[str]:
    """Registered provider ids, plus the usai anchor when its kit is selected.

    Empty when provider selection is off (an explicitly empty ACQ_PROVIDER_KITS).
    """
    env = os.environ if env is None else env
    refs = _selected_refs(env)
    if not refs:
        return []
    out = [p for p in provider_creds.provider_ids() if p != provider_creds.USAI_PROVIDER_ID]
    if default_selected(env):
        out.append(provider_creds.USAI_PROVIDER_ID)
    return out


def delivery_ids(backend: str, name: str | None) -> list[str]:
    """Every provider a sandbox should be bound with: the selected registry ids,
    then the providers its recorded facts name. Raises on an invalid record."""
    out = registry_ids()
    if name:
        for f in recorded(backend, name):
            if f.provider not in out:
                out.append(f.provider)
    return out


# ---------------------------------------------------------------------------
# The host-config record of a sandbox's provider facts.
# ---------------------------------------------------------------------------


def _hc_dir(backend: str, name: str) -> Path:
    return lock.bash_provenance_dir() / lock._bash_safe(backend) / f"{lock.bash_sandbox_key(name)}.config"


def record_write(backend: str, name: str, facts: list[Facts]) -> None:
    """Record the facts a sandbox was created with (0600, atomic; Bash's format).

    No facts removes the record, so a stale one from an earlier guest never
    describes this one. Raises ``OSError``.
    """
    path = _hc_dir(backend, name) / RECORD_KEY
    if not facts:
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    state.atomic_write_text(path, "\n".join(f.record() for f in facts))
    path.chmod(0o600)


def recorded(backend: str, name: str) -> list[Facts]:
    """The sandbox's recorded facts, re-validated; empty when there is no record.

    A record that exists but does not validate raises: a tampered or
    half-written record is never parsed into a credential binding.
    """
    path = _hc_dir(backend, name) / RECORD_KEY
    try:
        if path.is_symlink():
            raise _record_invalid(backend, name)
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return []
    except (OSError, UnicodeError) as exc:
        raise _record_invalid(backend, name) from exc
    out = []
    for line in text.splitlines():
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 5 or facts_problem(Facts(*fields)) is not None:
            raise _record_invalid(backend, name)
        out.append(Facts(*fields))
    return out


def _record_invalid(backend: str, name: str) -> ProviderInputError:
    return ProviderInputError(
        errors.VALIDATION_FAILED,
        f"the provider-credentials record of {backend} sandbox '{name}' is invalid; refusing to use it",
        f"recreate the sandbox ('acq create --recreate {name}') to re-record its provider facts",
    )


# ---------------------------------------------------------------------------
# The provider-input generation.
# ---------------------------------------------------------------------------


def input_root(backend: str, name: str) -> Path:
    """``acq_provider_input_root``: this sandbox's provider-input host root."""
    return lock.bash_provenance_dir() / "provider-input" / lock._bash_safe(backend) / lock.bash_sandbox_key(name)


def _safe_dir(path: Path) -> None:
    """Create ``path`` (and parents); refuse when it, or what is there, is a link."""
    path.mkdir(parents=True, exist_ok=True)
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & _REPARSE or not stat.S_ISDIR(info.st_mode):
        raise _invalid(f"unsafe provider-input directory {path}", "remove the link and retry")


def _copy_out(data: bytes, destination: Path, mode: int) -> None:
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
    os.chmod(destination, mode)


def materialize(manifest: dict, kit_root: Path, target_root: Path) -> None:
    """Copy one provider's validated artifacts into ``target_root/<providerId>``.

    Port of ``_acq_provider_input_materialize``: only the declared regular files
    are read (never through a link) and written as new files (never over an
    existing path). The OpenCode renderer reads ``facts.json`` and
    ``snapshot.json``; the catalog normalizer is a host-side authoring tool the
    bundle does not ship, so it is not placed in the guest.
    """
    provider = _manifest_ok(manifest)
    facts = _json_member(kit_root, manifest["factsPath"])
    _facts_from(facts, provider)
    snapshot = _json_member(kit_root, manifest["snapshotPath"])
    if snapshot.get("providerId") != provider:
        raise _invalid(f"the model snapshot of provider '{provider}' names another provider")
    target = target_root / provider
    if os.path.lexists(target) or target.parent != target_root or target.name != provider:
        raise _invalid(f"duplicate or unsafe provider target '{provider}'")
    target.mkdir(mode=0o755)
    _copy_out(read_member(kit_root, manifest["factsPath"]), target / "facts.json", 0o444)
    _copy_out(read_member(kit_root, manifest["snapshotPath"]), target / "snapshot.json", 0o444)


def prepare(backend: str, name: str, selected: list[tuple[str, dict, Facts]], bundle_dir: Path | None = None) -> Path:
    """Stage a complete, immutable generation for ``selected``; returns its path.

    The generation is not visible through ``current`` until :func:`publish`
    (after the backend create succeeds). A present empty generation is
    authoritative. Any failure removes the half-built generation and raises.
    """
    root = input_root(backend, name)
    _safe_dir(root / "generations")
    generation = Path(tempfile.mkdtemp(prefix="generation.", dir=root / "generations"))
    try:
        os.chmod(generation, 0o755)  # nosec B103 # a directory the guest reads, through a read-only mount
        providers = generation / "models" / "providers"
        providers.mkdir(parents=True, mode=0o755)
        for kit, manifest, _facts in selected:
            materialize(manifest, (bundle_dir or kitspec.BUNDLE_DIR) / kit, providers)
    except (OSError, ProviderInputError) as exc:
        discard(generation)
        if isinstance(exc, ProviderInputError):
            raise
        raise _invalid(f"could not stage the provider input: {exc.strerror or exc}",
                       "check that the acq state directory is writable, then retry") from exc
    return generation


def _chmod_nofollow(path: str | Path, mode: int) -> None:
    """chmod ``path`` unless it is a link (a link is skipped, never followed)."""
    if os.path.islink(path):
        return
    if os.chmod in os.supports_follow_symlinks:
        os.chmod(path, mode, follow_symlinks=False)
    else:
        os.chmod(path, mode)


def _make_read_only(generation: Path) -> None:
    """Every file read-only. Directories stay owner-writable so the owner can
    remove an old generation; the guest is held off by the read-only mount."""
    for dirpath, _dirnames, filenames in os.walk(generation, followlinks=False):
        for entry in filenames:
            _chmod_nofollow(Path(dirpath) / entry, 0o444)


def publish(backend: str, name: str, generation: Path) -> None:
    """Make ``generation``'s files read-only and point ``current`` at it (atomic rename).

    Earlier generations are kept: a sandbox created by an older acq may still
    mount ``current``. Raises ``OSError``.
    """
    root = input_root(backend, name)
    if generation.parent != root / "generations" or not generation.name.startswith("generation."):
        raise OSError(f"not a generation of {root}")
    _make_read_only(generation)
    temp = root / f".current.{os.getpid()}"
    temp.unlink(missing_ok=True)
    os.symlink(f"generations/{generation.name}", temp)
    os.replace(temp, root / "current")


def discard(generation: Path) -> None:
    """Remove an unpublished generation (best-effort, never following a link)."""
    def _writable(func, path, _exc):  # a read-only entry is made writable, then retried
        try:
            _chmod_nofollow(path, 0o700)
            func(path)
        except OSError:
            pass

    if generation.is_symlink():
        generation.unlink(missing_ok=True)
        return
    # A generation published by Bash (``chmod -R a-w``) has 0555 directories, and
    # an entry cannot be unlinked from a directory that lacks write. os.walk lists
    # a link to a directory among the directories; the helper skips it.
    try:
        _chmod_nofollow(generation, 0o700)
        for dirpath, dirnames, _files in os.walk(generation, followlinks=False):
            for entry in dirnames:
                _chmod_nofollow(Path(dirpath) / entry, 0o700)
    except OSError:
        pass
    shutil.rmtree(generation, onexc=_writable)


def remove(backend: str, name: str) -> None:
    """Drop a removed sandbox's provider-input root (best-effort)."""
    root = input_root(backend, name)
    if root.is_symlink():
        root.unlink(missing_ok=True)
    elif root.is_dir():
        gens = root / "generations"
        if gens.is_dir() and not gens.is_symlink():
            for gen in gens.iterdir():
                discard(gen)
        shutil.rmtree(root, ignore_errors=True)


def guest_root(generation: Path) -> str:
    """Where the msb guest sees ``generation`` (``acq_provider_input_guest_root``)."""
    return f"{GUEST_DIR}/{generation.name}"


def msb_flags(generation: Path) -> list[str]:
    """The read-only mount and ``ACQ_PROVIDER_INPUT_ROOT`` for an msb create."""
    host = os.path.realpath(generation)
    return ["--volume", f"{host}:{guest_root(generation)}:ro", "--env", f"{ROOT_ENV}={guest_root(generation)}"]


# ---------------------------------------------------------------------------
# The attach-time key check (ensure_valid_provider_keys).
# ---------------------------------------------------------------------------

# The probe program. The models URL is positional data ($1), never spliced into
# the program text; the key is referenced by name only, so the guest's
# placeholder is what travels, swapped for the real value on the wire.
PROBE_SCRIPT = (
    "curl -sS --max-time 20 -o /dev/null -w '%{{http_code}}' "
    "-H \"Authorization: Bearer ${env}\" \"$1\"; printf '|%s' \"$?\""
)


def probe_argv(f: Facts) -> list[str]:
    return ["sh", "-c", PROBE_SCRIPT.format(env=f.key_env), "sh", f.models_url]


def classify(raw: str) -> str:
    """Bash ``_classify_key_status``: an HTTP code, ``unresolved``, ``unreachable`` or ``""``."""
    head, sep, tail = raw.rpartition("|")
    if not sep:
        return ""
    exit_code = "".join(ch for ch in tail if ch.isdigit())
    code = "".join(ch for ch in head if ch.isdigit())[-3:]
    if exit_code == "0" and code and code != "000":
        return code
    if exit_code == "6":
        return "unresolved"
    if (exit_code and exit_code != "0") or code == "000":
        return "unreachable"
    return ""


def _status_error(name: str, f: Facts, status: str) -> ProviderInputError | None:
    p = f.provider
    if status in ("200", "429") or (len(status) == 3 and status.startswith("5")):
        return None
    if status in ("unreachable", "unresolved"):
        what = "could not resolve" if status == "unresolved" else "could not reach"
        return ProviderInputError(
            errors.PROVIDER_UNREACHABLE,
            f"sandbox '{name}' {what} the '{p}' models endpoint ({f.host}); that is a network problem, not a credential one",
            "check the sandbox's network access and DNS for that host, then retry",
        )
    if status == "":
        return ProviderInputError(
            errors.PROVIDER_UNREACHABLE,
            f"could not validate the '{p}' provider key for sandbox '{name}' (the probe returned no status); "
            "refusing to attach with an unverified credential",
            "check the sandbox's network access, then retry",
        )
    if status.startswith("3"):
        return _invalid(f"the '{p}' models endpoint redirected (HTTP {status})",
                        "update the provider kit's facts.modelsUrl to the final endpoint")
    hint = "rotate it with 'acq usai-rotate-api-key', or re-store it with " if p == provider_creds.USAI_PROVIDER_ID else "update it with "
    return ProviderInputError(
        errors.PROVIDER_AUTH_FAILED,
        f"provider '{p}' rejected the stored key (HTTP {status})",
        f"{hint}'acq secret set -g {p}'",
    )


def check_keys(name: str, facts: Iterable[Facts], run_probe: Callable[[list[str]], str],
               warn: Callable[[str], None]) -> None:
    """Probe each provider's key from inside sandbox ``name``; raises on the first failure.

    429 and 5xx are transient: a warning, not a refusal. A host service is
    never probed, and facts that no longer match the provider's pin (a
    tampered record, or a pin changed since create) are refused unprobed.
    """
    for f in facts:
        if f.provider in HOST_SERVICES:
            continue
        check_pin(f)
        status = classify(run_probe(probe_argv(f)))
        problem = _status_error(name, f, status)
        if problem is not None:
            raise problem
        if status != "200":
            warn(f"provider '{f.provider}' returned HTTP {status} (transient); continuing without blocking attach")
