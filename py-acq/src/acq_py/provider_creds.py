"""Provider-credential bindings, GitHub per-sandbox scoping, and rotation data
(ADR-0038m §provider-credential, ADR-0012, ADR-0013, ADR-0041m).

This module owns the **host-authoritative** records for two credential concerns:

* **Provider-credential bindings** — a destination-pinned mapping from a
  provider id to its credential environment variable (``key_env``) and the
  host(s) that credential may be sent to (``hosts``), plus the precedence layer
  it came from (``source_layer``). The *binding* is durable, user-owned, and
  recorded host-side as a ``schema=N`` record; the credential *value* is a
  backend secret and is never stored or surfaced here (ADR-0038m §user story #7
  "no secret exposure").
* **GitHub per-sandbox scope** — a per-sandbox (never global) marker recording
  that a sandbox holds a least-privilege GitHub token scoped to its workspace
  (ADR-0013). The token is backend-bound and never appears in these records or
  in any output.

Both record families carry their own ``schema`` marker (distinct from the
sandbox-record schema in ``state.py`` and from the structured-output
``schema_version`` in ``envelope.py``). They live in sibling directories under
the state root so sandbox-state migration never rewrites or rejects them
(ADR-0041m type-awareness).

The US Ai provider is the shipped trust anchor (``usai|USAI_API_KEY|api.gsa.usai.gov``),
mirroring the legacy ``ACQ_PROVIDER_TRUSTED_DEFAULTS``: its (key_env, host) pair
is data, not a code branch.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path

from . import state

# State-schema version of the records this module writes (ADR-0041m). Distinct
# from the sandbox-record schema and from ``envelope.SCHEMA_VERSION``.
CREDS_SCHEMA = 1

# The shipped default provider trust anchor (id, key env, host).
USAI_PROVIDER_ID = "usai"
USAI_PROVIDER_KEY_ENV = "USAI_API_KEY"
USAI_PROVIDER_HOST = "api.gsa.usai.gov"

# Process-critical variable names a provider credential must never occupy
# (mirrors the legacy ACQ_PROVIDER_FORBIDDEN_KEY_ENVS).
FORBIDDEN_KEY_ENVS = frozenset(
    "PATH IFS LD_PRELOAD LD_LIBRARY_PATH BASH_ENV ENV HOME SHELLOPTS PS4 CDPATH TMPDIR".split()
)

# Environment-variable names reserved for the built-in services; a provider may
# reuse a reserved name only when it IS that provider (e.g. `usai` + USAI_API_KEY).
_RESERVED_KEY_ENV_OWNERS = {
    "USAI_API_KEY": "usai",
    "GITHUB_TOKEN": "github",
    "GH_TOKEN": "github",
    "GITLAB_TOKEN": "gitlab",
}

# The per-invocation credential-binding environment layer (legacy
# ACQ_PROVIDER_CREDENTIAL_BINDINGS): whitespace-separated
# "<providerId>=<KEY_ENV>[@<host>[,<host>]]".
BINDINGS_ENV = "ACQ_PROVIDER_CREDENTIAL_BINDINGS"

# Config-layer seed seam (internal test seam, never a secret, never written to
# output). ``ACQ_PROVIDER_CREDENTIAL_SEED`` is a JSON array of
# ``{provider, key_env, hosts}`` objects that, when set, supplies the config-layer
# read for ``ls`` so a single-invocation contract vector can report host-record
# bindings without a prior ``set`` (mirrors ``ACQ_KIT_SOURCE_SEED``).
SEED_ENV = "ACQ_PROVIDER_CREDENTIAL_SEED"

# providerId grammar: lower-case alphanumeric + hyphens, bounded, never
# starting/ending with '-'.
_PROVIDER_ID_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$")

# KEY_ENV grammar: an upper-case environment-variable name.
_KEY_ENV_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")

# HOST grammar: one DNS name, lower-case, no scheme/port/path/wildcard.
_HOST_RE = re.compile(
    r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$"
)

_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]")


def _safe(token: str) -> str:
    return _SAFE_RE.sub("_", token)


def _checksum(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


# ---------------------------------------------------------------------------
# Validation (ADR-0038m: malformed entries fail closed).
# ---------------------------------------------------------------------------

def provider_id_ok(provider: str) -> bool:
    return bool(_PROVIDER_ID_RE.match(provider))


def key_env_ok(key_env: str) -> bool:
    return key_env not in FORBIDDEN_KEY_ENVS and bool(_KEY_ENV_RE.match(key_env))


def key_env_owner(key_env: str) -> str | None:
    return _RESERVED_KEY_ENV_OWNERS.get(key_env)


def host_ok(host: str) -> bool:
    return len(host) <= 253 and bool(_HOST_RE.match(host))


def validate_binding(provider: str, key_env: str, hosts: list[str]) -> str | None:
    """Validate a provider-credential binding; return an error message or None.

    Checks the provider id, the KEY_ENV grammar + forbidden/reserved-name rules,
    and that every host is a bare lower-case DNS name. The value is never part of
    a binding, so it never enters this validation.
    """
    if not provider_id_ok(provider):
        return (
            f"invalid provider id {provider!r}; want ^[a-z0-9]([a-z0-9-]{{0,30}}"
            f"[a-z0-9])?$ (for example: opencode-go)"
        )
    if not key_env_ok(key_env):
        return (
            f"invalid KEY_ENV {key_env!r} for provider {provider!r}; want an "
            "upper-case env var name (for example: OPENCODE_GO_API_KEY)"
        )
    owner = key_env_owner(key_env)
    if owner is not None and owner != provider:
        return (
            f"KEY_ENV {key_env!r} belongs to the {owner!r} service, so provider "
            f"{provider!r} cannot claim it; use a provider-specific name"
        )
    for host in hosts:
        if not host_ok(host):
            return (
                f"invalid host {host!r} for provider {provider!r}; want a bare "
                "DNS name such as models.example.gov (no scheme, port, or path)"
            )
    return None


def parse_hosts(values: list[str]) -> list[str]:
    """Flatten repeated/comma-separated ``--host`` values into a host list."""
    out: list[str] = []
    for value in values:
        for host in value.split(","):
            host = host.strip()
            if host:
                out.append(host)
    return out


# ---------------------------------------------------------------------------
# Host-side record storage (ADR-0041m: orchestrator-owned, schema-versioned).
# ---------------------------------------------------------------------------

def _binding_dir() -> Path:
    return state.state_dir() / "provider-credentials"


def _scope_dir() -> Path:
    return state.state_dir() / "github-scope"


def _binding_path(provider: str) -> Path:
    return _binding_dir() / f"{_safe(provider)}.{_checksum(provider)}.json"


def _scope_path(backend: str, sandbox: str) -> Path:
    return _scope_dir() / _safe(backend) / f"{_safe(sandbox)}.{_checksum(sandbox)}.json"


def _read_record(path: Path, *, strict: bool, label: str) -> dict | None:
    """Read one schema-versioned record (mirrors ``state._record_from_path``)."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        if strict:
            raise state.StateSchemaError(f"credential record for {label!r} is not valid JSON") from exc
        return None
    if not isinstance(doc, dict):
        if strict:
            raise state.StateSchemaError(f"credential record for {label!r} is not a JSON object")
        return None
    schema = doc.get("schema")
    if schema is None:
        return None  # legacy v0 (no marker)
    if not isinstance(schema, int) or schema != CREDS_SCHEMA:
        if strict:
            raise state.StateSchemaError(
                f"credential record for {label!r} carries schema {schema!r}; "
                f"this reader understands schema {CREDS_SCHEMA}"
            )
        return None
    return doc


def _atomic_write(path: Path, doc: dict) -> None:
    """Write a record atomically (temp + fsync + rename), never half-written."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    data = json.dumps(doc, indent=2, sort_keys=False)
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(data + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# Provider-credential bindings.
# ---------------------------------------------------------------------------

def set_binding(provider: str, key_env: str, hosts: list[str]) -> str:
    """Persist (add or update) one destination-pinned binding; returns action."""
    existed = get_binding(provider) is not None
    _atomic_write(
        _binding_path(provider),
        {
            "schema": CREDS_SCHEMA,
            "provider": provider,
            "key_env": key_env,
            "hosts": hosts,
            "source_layer": "config.yaml",
        },
    )
    return "updated" if existed else "added"


def get_binding(provider: str) -> dict | None:
    """Read one binding (strict). Raises on newer/unparseable.

    Honors the ``ACQ_PROVIDER_CREDENTIAL_SEED`` seam first so a single-invocation
    contract vector can exercise ``rm`` against a pre-seeded config-layer binding.
    """
    seeded = _seeded_bindings()
    if seeded is not None:
        for rec in seeded:
            if rec.get("provider") == provider:
                return rec
        return None
    return _read_record(_binding_path(provider), strict=True, label=provider)


def remove_binding(provider: str) -> bool:
    """Remove one binding; returns True when it was present.

    When seeded (test seam) there is no on-disk record to unlink: the removal is
    reported as successful against the seeded registry.
    """
    if get_binding(provider) is None:
        return False
    if _seeded_bindings() is None:
        try:
            _binding_path(provider).unlink()
        except OSError:
            pass
    return True


def _env_bindings() -> list[dict]:
    """Parse the per-invocation ``ACQ_PROVIDER_CREDENTIAL_BINDINGS`` env layer.

    A malformed entry is an error: this raises ``ValueError`` so the caller
    refuses rather than silently dropping the binding (ADR-0038m fail-closed).
    """
    raw = os.environ.get(BINDINGS_ENV)
    if raw is None:
        return []
    out: list[dict] = []
    for token in raw.split():
        if not token:
            continue
        if "=" not in token:
            raise ValueError(f"expected '<providerId>=<KEY_ENV>', got {token!r}")
        provider, _, rest = token.partition("=")
        key_env, _, hosts_s = rest.partition("@")
        hosts = [h for h in hosts_s.split(",") if h] if hosts_s else []
        problem = validate_binding(provider, key_env, hosts)
        if problem is not None:
            raise ValueError(problem)
        out.append(
            {
                "provider": provider,
                "key_env": key_env,
                "hosts": hosts,
                "source_layer": "env",
            }
        )
    return out


def _seeded_bindings() -> list[dict] | None:
    """Return seeded config-layer bindings, or ``None`` when ``ACQ_PROVIDER_CREDENTIAL_SEED``
    is unset. A JSON array of ``{provider, key_env, hosts}`` objects; malformed
    input is an empty list. This is an internal test seam for the read path
    (``ls``), never a secret and never written to output.
    """
    raw = os.environ.get(SEED_ENV)
    if raw is None:
        return None
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(parsed, list):
        return []
    out: list[dict] = []
    for entry in parsed:
        if isinstance(entry, dict) and entry.get("provider"):
            out.append(
                {
                    "provider": entry["provider"],
                    "key_env": entry.get("key_env"),
                    "hosts": entry.get("hosts") or [],
                    "source_layer": entry.get("source_layer") or "config.yaml",
                }
            )
    return out


def list_bindings() -> list[dict]:
    """List bindings (config-layer host records first, then the env layer).

    Reports ``provider``/``key_env``/``hosts``/``source_layer`` only — never a
    value. A malformed env-layer entry raises ``ValueError`` (the caller refuses
    rather than silently dropping a binding, ADR-0038m fail-closed).
    """
    seeded = _seeded_bindings()
    if seeded is not None:
        out = list(seeded)
    else:
        out = []
        root = _binding_dir()
        if root.is_dir():
            for path in sorted(root.glob("*.json")):
                doc = _read_record(path, strict=False, label=path.stem)
                if doc is not None:
                    out.append(
                        {
                            "provider": doc.get("provider"),
                            "key_env": doc.get("key_env"),
                            "hosts": doc.get("hosts") or [],
                            "source_layer": doc.get("source_layer") or "config.yaml",
                        }
                    )
    out.extend(_env_bindings())
    out.sort(key=lambda b: (b["source_layer"], b["provider"]))
    return out


# ---------------------------------------------------------------------------
# GitHub per-sandbox scope (ADR-0013).
# ---------------------------------------------------------------------------

def github_scope_write(backend: str, sandbox: str, workspace: str) -> dict:
    """Record a per-sandbox GitHub token scope (least-privilege, ADR-0013).

    The record names the sandbox, backend, and workspace the token is scoped to.
    The token itself is backend-bound and never appears here or in output.
    """
    doc = {
        "schema": CREDS_SCHEMA,
        "backend": backend,
        "sandbox": sandbox,
        "workspace": workspace,
        "scoped": True,
    }
    _atomic_write(_scope_path(backend, sandbox), doc)
    return doc


def github_scope_read(backend: str, sandbox: str) -> dict | None:
    """Read a sandbox's per-sandbox scope record (lenient; absent reads None)."""
    return _read_record(_scope_path(backend, sandbox), strict=False, label=sandbox)
