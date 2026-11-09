"""Kit-source registry, kit provenance, and kit inspection (ADR-0038m §kit).

This is the kit-source registry + kit-inspection layer only. It owns:

* the pinned **control plane** — the shipped Patterns release that carries the
  neutral ``hybrid/v1`` kit bundle, the provider-input/facts schemas, and the
  validator that are acq's trust anchor (ADR-0016, ADR-0030);
* the host-side **trusted kit-source registry** — orchestrator-owned records,
  one per repository, each carrying its own state-schema marker and pinned to a
  full SHA (ADR-0041m host-authoritative state rules);
* the host-side per-sandbox **bundle provenance** record that powers
  ``kit check``/``kit update`` (ADR-0016: host-side, exact-ref currency);
* the offline **provider-kit discovery seam** so ``kit-source ls`` can report a
  deterministic ``discovery_status`` without network (ADR-0038m §48 explicit
  best-effort discovery status);
* minimal structural **kit validation** (ADR-0038m §kit validate);
* the **built-in agent-kit registry** (ADR-0030) — the pinned-by-content install
  argv and declared entrypoint for each built-in agent kit, plus the
  host-authoritative per-sandbox applied-kit record that makes ``kit apply``
  idempotent and re-runnable.

This module still never executes kit code (on the host or in the guest): the
install argv is data forwarded through the backend seam, which runs it in-guest
via the ``kit-apply`` capability (ADR-0040m).

Trusted-source policy (ADR-0030 §"Agent kit inference", ADR-0038m §46 "durable
trust is repository-granular"): only the built-in bundle participates in implicit
agent-kit selection; team/personal kit sources are never matched by agent name.
Nothing here resolves an agent to a kit, so that policy is satisfied by
construction — the built-in neutral/provider sets are the only sets this module
emits, and the extra set is reported verbatim, never inferred.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from . import state


class KitSpecError(Exception):
    """A kit path or ``spec.yaml`` cannot be read (missing or unreadable).

    Distinct from an invalid-but-readable kit: this is a validation *failure*
    (exit 1, ``validation_failed``), whereas an invalid kit is a successful query
    answer (exit 0, ``valid=false`` plus coded findings).
    """


# ---------------------------------------------------------------------------
# Pinned control plane (the trust anchor; ADR-0016, ADR-0030).
# ---------------------------------------------------------------------------
# The ref is a full 40-char SHA, never a mutable branch or tag (ADR-0038m §46).
# TODO(quarterly): a real, reproducible pin re-reviewed on the quarterly cadence
# (ADR-0030), sourced from the pinned patterns release.
CONTROL_PLANE_REPO = "github.com/GSA-TTS/agentic-coding-patterns"
CONTROL_PLANE_REF = "941a286f912b99475429c3c00db49a99af5b241e"
CONTROL_PLANE_DIR = "integrations/isolation/acq-kits"

# The built-in neutral kit bundle, in apply order (ADR-0011, ADR-0016). The
# provider-role kit (usai-provider) is reported separately because ADR-0030's kit
# model gives provider facts their own role within the bundle.
BUILTIN_KIT_NAMES = (
    "zscaler-ca-certificate",
    "usai-provider",
    "agentic-coding-playbook",
    "git-ssh-sign",
)
PROVIDER_KIT_NAMES = ("usai-provider",)
# The non-provider built-in neutral kits (CA trust, playbook, git signing).
BUILTIN_NEUTRAL_NAMES = tuple(n for n in BUILTIN_KIT_NAMES if n not in PROVIDER_KIT_NAMES)


# ---------------------------------------------------------------------------
# Built-in agent kits (ADR-0030). An agent kit installs or exposes an agent
# harness, declares its entrypoint, and renders that harness's configuration
# from provider facts. The install step is pinned by content: a
# ``nix profile install github:NixOS/nixpkgs/<rev>#<agent>`` at the substrate's
# declared rev (content-hashed, cached, and identical across arches) — never a
# mutable ``npm install -g …@latest`` fallback (ADR-0030 "Agent install
# contract"). Only ``opencode`` is a built-in agent kit today; the other known
# agents select no agent kit but still land on the devenv base (spec
# implementation decision #4).
# ---------------------------------------------------------------------------

# The nixpkgs rev an agent kit installs its binary at (ADR-0030 "substrate
# contract"): the install is content-hashed, cached, and identical across arches
# because it pins a full rev, never a mutable branch/tag. TODO(quarterly): this is
# a real, reproducible pin — re-reviewed on the quarterly cadence (ADR-0030). It
# is sourced from the substrate's declared NIXPKGS_REV (nixos-26.05) in
# ``integrations/isolation/images/devenv/`` and upstream ``acq.backends/agents.sh``;
# the offline path treats it as opaque data (the install argv is never executed
# here).
OPENCODE_NIXPKGS_REV = "0d9e9b832d03ac387417e16ce1febf73b2e631e1"

# Built-in agent kits: kit name -> (pinned install argv, entrypoint).
AGENT_KITS: dict[str, tuple[list[str], str]] = {
    "opencode": (
        [
            "nix",
            "profile",
            "install",
            f"github:NixOS/nixpkgs/{OPENCODE_NIXPKGS_REV}#opencode",
        ],
        "opencode",
    ),
}

AGENT_KIT_NAMES = tuple(AGENT_KITS)


# ---------------------------------------------------------------------------
# Kit network egress (ADR-0018, ADR-0030 "Egress and kit conflicts"). Each
# built-in kit's ``caps.network.allow`` list, copied verbatim from its pinned
# ``spec.yaml`` at ``KIT_NETWORK_ALLOW_REF``. acq never fetches a kit source
# during ordinary operation (ADR-0042m offline), so the create-time egress
# allowlist is data held here rather than read from a fetched kit. The msb
# adapter translates these entries exactly as the Bash adapter's
# ``_acq_msb_net_rules_into`` does.
#
# The ref is recorded separately from ``CONTROL_PLANE_REF`` on purpose: bumping
# the control-plane pin without re-deriving this table makes the two differ, and
# the msb adapter then refuses to create a sandbox instead of applying a stale
# allowlist (fail closed).
#
# ``opencode`` here is the Python agent kit (the pinned ``nix profile install``
# argv in ``AGENT_KITS``), which declares no egress of its own.
# ---------------------------------------------------------------------------
KIT_NETWORK_ALLOW_REF = "941a286f912b99475429c3c00db49a99af5b241e"
KIT_NETWORK_ALLOW: dict[str, tuple[str, ...]] = {
    "zscaler-ca-certificate": (),
    "usai-provider": ("api.gsa.usai.gov",),
    "agentic-coding-playbook": (
        "api.github.com:443",
        "codeload.github.com:443",
        "github.com:443",
    ),
    "git-ssh-sign": (),
    "opencode": (),
}


def egress_kit_names(agent_kit: str | None) -> list[str]:
    """The kits whose network allowances make up a new sandbox's egress policy.

    Mirrors the Bash kit list (``_acq_selected_support_kit_refs`` then the
    agent kit), in the same order: CA trust, the provider kit(s), the playbook,
    git signing, then the agent kit when one is selected. The built-in kits are
    part of the policy even though this create path does not apply them yet:
    egress is fixed when the sandbox is created, and both implementations should
    produce the same policy for the same selection. Extra (team/personal) kits
    are left out because this path does not apply them and cannot resolve them
    without a network fetch. Leaving them out allows less, never more.
    """
    names = ["zscaler-ca-certificate", *provider_kits(), "agentic-coding-playbook", "git-ssh-sign"]
    if agent_kit is not None:
        names.append(agent_kit)
    return names


def agent_kit_for(agent: str) -> str | None:
    """Return the built-in agent-kit name for an agent, or ``None`` (no kit).

    Implicit agent-kit selection matches the **built-in bundle only** (ADR-0030
    "Agent kit inference"): a team/personal kit named after an agent is never
    consulted, and ``shell`` selects no agent kit. This function is the single
    inference point — it never reads :func:`extra_kits` or the trusted-source
    registry.
    """
    return agent if agent in AGENT_KITS else None


def is_agent_kit(name: str) -> bool:
    """True when ``name`` is a built-in agent kit.

    This is the only kit set ``kit apply`` and implicit agent-kit selection
    resolve by name in this slice; team/personal kit application is deferred.
    """
    return name in AGENT_KITS


def agent_kit_install(name: str) -> list[str]:
    """The pinned-by-content install argv for a built-in agent kit (ADR-0030)."""
    return list(AGENT_KITS[name][0])


def agent_kit_entrypoint(name: str) -> str:
    """The entrypoint a built-in agent kit declares (the installed binary)."""
    return AGENT_KITS[name][1]


# State-schema version of the records this module writes (ADR-0041m). Distinct
# from the sandbox-record schema in ``state.py`` and from the structured-output
# ``schema_version`` in ``envelope.py``: each record TYPE carries its own marker.
KIT_SCHEMA = 1

# The grammars below are applied with re.fullmatch: an anchored re.match() would
# also accept a trailing newline, because `$` matches just before one.

# A full immutable git ref is a 40-char SHA-1 or 64-char SHA-256, case-insensitive.
_FULL_SHA1_RE = re.compile(r"[0-9a-fA-F]{40}")
_FULL_SHA256_RE = re.compile(r"[0-9a-fA-F]{64}")

# A normalized repository is host/owner/repo: lower-case host, two more path
# segments, no scheme, no trailing slash (ADR-0016 `_acq_kit_source_repo_ok`).
_REPO_RE = re.compile(r"[a-z0-9][a-z0-9.-]*/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")

# A kit directory is a relative path of the neutral acq-kits tree (no leading
# slash, no ``..`` traversal, ASCII path chars only).
_DIR_RE = re.compile(r"[A-Za-z0-9._/-]+")

# Offline discovery seam (internal test seam, never a secret, never written to
# output). Maps a repository to a deterministic list of provider kits; a repo key
# present means "reachable" with those kits, absent means "unreachable". A ``"*"``
# key applies to any repository not otherwise named. Without the seam, only the
# control plane is "reachable" (its provider kits are statically known); every
# other source is "unreachable" because ordinary operation never fetches a kit
# source (ADR-0042m offline).
DISCOVERY_ENV = "ACQ_KIT_SOURCE_DISCOVERY"

# Registry seed seam (internal test seam, never a secret, never written to
# output). ``ACQ_KIT_SOURCE_SEED`` is a JSON array of ``{repository, ref,
# directory}`` objects that, when set, replaces the on-disk registry for this
# invocation's *read* paths (``ls`` and ``rm``). It exists so a single-command
# contract vector can exercise ``ls``/``rm`` against pre-existing sources without
# a prior ``add`` (the same reason ``ACQ_MSB_STUB_CATALOG`` seeds the stub msb).
SEED_ENV = "ACQ_KIT_SOURCE_SEED"

# Provenance seed seam (internal test seam, never a secret, never written to
# output). ``ACQ_KIT_PROVENANCE_SEED`` is a JSON object ``{"<sandbox>":
# "<applied_ref>"}`` that, when set, supplies the provenance read for a named
# sandbox, so a single-command contract vector can drive ``kit check`` to
# ``current``/``stale`` without a prior ``kit update``.
PROVENANCE_SEED_ENV = "ACQ_KIT_PROVENANCE_SEED"


def is_full_ref(ref: str) -> bool:
    """True when ``ref`` is a full immutable SHA (40 or 64 hex chars).

    A branch, tag, abbreviated SHA, or anything else is a mutable ref and is
    refused (ADR-0038m §46 "kits use immutable full refs").
    """
    return bool(_FULL_SHA1_RE.fullmatch(ref) or _FULL_SHA256_RE.fullmatch(ref))


def normalize_repo(arg: str) -> str | None:
    """Normalize a human-pasted repo into ``host/owner/repo``, or ``None``.

    Accepts a bare ``host/owner/repo``, a clone URL, or a ``git+https`` kit ref;
    refuses credential-bearing URLs and anything that is not exactly three path
    segments (so a typo cannot silently trust a different repository, ADR-0016).
    """
    repo = (arg or "").strip()
    if not repo:
        return None
    repo = repo.removeprefix("git+")
    if "://" in repo:
        repo = repo.split("://", 1)[1]
    if "@" in repo:
        return None  # credential-bearing URLs are never a kit source
    repo = repo.split("#", 1)[0].split("?", 1)[0]
    if repo.endswith(".git"):
        repo = repo[: -len(".git")]
    repo = repo.rstrip("/")
    if not _REPO_RE.fullmatch(repo):
        return None
    return repo


def normalize_dir(value: str | None) -> str | None:
    """Validate (or default) a kit directory; ``None`` for an unsafe path."""
    d = (value or CONTROL_PLANE_DIR)
    if not d or d.startswith("/") or ".." in d or not _DIR_RE.fullmatch(d):
        return None
    return d


def control_plane_ref() -> str:
    """The fetchable pinned control-plane kit ref (ADR-0038m §kit list)."""
    return f"git+https://{CONTROL_PLANE_REPO}.git#ref={CONTROL_PLANE_REF}&dir={CONTROL_PLANE_DIR}"


def provider_kits() -> list[str]:
    """The effective provider-role kit set (ADR-0030).

    Defaults to the shipped ``usai-provider``; ``ACQ_PROVIDER_KITS`` overrides it
    for one invocation (an explicitly-empty value selects none), mirroring the
    legacy provider selection.
    """
    if "ACQ_PROVIDER_KITS" in os.environ:
        return [t for t in os.environ["ACQ_PROVIDER_KITS"].split() if t]
    return list(PROVIDER_KIT_NAMES)


def extra_kits() -> list[str]:
    """The effective extra (team/personal) kit set, verbatim from the environment."""
    return [t for t in os.environ.get("ACQ_EXTRA_KITS", "").split() if t]


def kit_list_data() -> dict:
    """Assemble the ``kit list`` required result data (ADR-0038m §2).

    Reports the control-plane ref and the effective ``built_in``/``provider``/
    ``extra`` sets. Only the built-in bundle participates in implicit agent-kit
    selection; extras are reported verbatim, never matched by agent name.
    """
    return {
        "control_plane_ref": control_plane_ref(),
        "built_in": list(BUILTIN_NEUTRAL_NAMES),
        "provider": provider_kits(),
        "extra": extra_kits(),
    }


# ---------------------------------------------------------------------------
# Host-side record storage (ADR-0041m: orchestrator-owned, schema-versioned).
# ---------------------------------------------------------------------------

_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]")


def _safe(token: str) -> str:
    return _SAFE_RE.sub("_", token)


def _checksum(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


def _kit_source_dir() -> Path:
    return state.state_dir() / "kit-sources"


def _provenance_dir() -> Path:
    return state.state_dir() / "provenance"


def _source_path(repo: str) -> Path:
    return _kit_source_dir() / f"{_safe(repo)}.{_checksum(repo)}.json"


def _provenance_path(backend: str, sandbox: str) -> Path:
    return _provenance_dir() / _safe(backend) / f"{_safe(sandbox)}.{_checksum(sandbox)}.json"


def _read_record(path: Path, *, strict: bool, label: str) -> dict | None:
    """Read one schema-versioned record (mirrors ``state._record_from_path``).

    Returns the record when its ``schema`` is exactly :data:`KIT_SCHEMA`. With
    ``strict=True`` a newer/unknown schema or unparseable content raises
    :class:`state.StateSchemaError` (fail closed, ADR-0041m); with ``strict=False``
    it returns ``None`` so a read-only diagnostic skips rather than misreads.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        if strict:
            raise state.StateSchemaError(f"kit record for {label!r} is not valid JSON") from exc
        return None
    if not isinstance(doc, dict):
        if strict:
            raise state.StateSchemaError(f"kit record for {label!r} is not a JSON object")
        return None
    schema = doc.get("schema")
    if schema is None:
        return None  # legacy v0 (no marker)
    if not isinstance(schema, int) or schema != KIT_SCHEMA:
        if strict:
            raise state.StateSchemaError(
                f"kit record for {label!r} carries schema {schema!r}; "
                f"this reader understands schema {KIT_SCHEMA}"
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
# Trusted kit-source registry.
# ---------------------------------------------------------------------------

def _seeded_records() -> list[dict] | None:
    """Return seeded registry records, or ``None`` when ``ACQ_KIT_SOURCE_SEED`` is unset.

    A JSON array of ``{repository, ref, directory}`` objects; malformed input is an
    empty list. This is an internal test seam for the read paths (``ls``/``rm``),
    never a secret and never written to output.
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
        if isinstance(entry, dict) and entry.get("repository"):
            out.append(
                {
                    "repository": entry["repository"],
                    "ref": entry.get("ref") or "",
                    "directory": entry.get("directory") or CONTROL_PLANE_DIR,
                }
            )
    return out


def source_record(repo: str) -> dict | None:
    """Read one registered source (strict). Raises on newer/unparseable."""
    seeded = _seeded_records()
    if seeded is not None:
        for rec in seeded:
            if rec.get("repository") == repo:
                return rec
        return None
    return _read_record(_source_path(repo), strict=True, label=repo)


def list_source_records() -> list[dict]:
    """List every readable registered source, sorted by repository (lenient)."""
    seeded = _seeded_records()
    if seeded is not None:
        return sorted(seeded, key=lambda r: r.get("repository", ""))
    root = _kit_source_dir()
    out: list[dict] = []
    if not root.is_dir():
        return out
    for path in sorted(root.glob("*.json")):
        doc = _read_record(path, strict=False, label=path.stem)
        if doc is not None:
            out.append(doc)
    return out


def set_source(repo: str, ref: str, directory: str) -> str:
    """Persist (add or update) one trusted source; returns ``added``/``updated``."""
    existed = source_record(repo) is not None
    _atomic_write(
        _source_path(repo),
        {"schema": KIT_SCHEMA, "repository": repo, "ref": ref, "directory": directory},
    )
    return "updated" if existed else "added"


def remove_source(repo: str) -> bool:
    """Remove one registered source; returns ``True`` when it was present."""
    if source_record(repo) is None:
        return False
    # When seeded (test seam) there is no on-disk record to unlink: the removal is
    # reported as successful against the seeded registry.
    if _seeded_records() is None:
        try:
            _source_path(repo).unlink()
        except OSError:
            pass
    return True


def all_sources() -> list[dict]:
    """The trusted sources: the pinned control plane first, then registered sources.

    The control plane is the trust anchor and is always present; a registered
    record for the control-plane repo is ignored in favor of the shipped pin
    (durable trust is repository-granular and the anchor is not re-pinnable
    through the registry).
    """
    sources = [
        {
            "repository": CONTROL_PLANE_REPO,
            "ref": CONTROL_PLANE_REF,
            "directory": CONTROL_PLANE_DIR,
        }
    ]
    for rec in list_source_records():
        if rec.get("repository") == CONTROL_PLANE_REPO:
            continue
        sources.append(
            {
                "repository": rec.get("repository"),
                "ref": rec.get("ref") or "",
                "directory": rec.get("directory") or CONTROL_PLANE_DIR,
            }
        )
    return sources


def discover_provider_kits(repository: str) -> tuple[str, list[str]]:
    """Return ``(discovery_status, provider_kits)`` for one source, offline.

    The control plane's provider kits are statically known (``usai-provider`` is
    part of the shipped bundle, ADR-0030), so it is always ``reachable`` without a
    network call. Every other source is ``unreachable`` by default (ordinary
    operation never fetches a kit source, ADR-0042m); the ``ACQ_KIT_SOURCE_DISCOVERY``
    seam maps a repository to a deterministic kit list so contract vectors can
    force ``reachable`` without network.
    """
    if repository == CONTROL_PLANE_REPO:
        return "reachable", list(PROVIDER_KIT_NAMES)
    raw = os.environ.get(DISCOVERY_ENV)
    mapping: dict = {}
    if raw:
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            mapping = parsed
    for key in (repository, "*"):
        if key in mapping and isinstance(mapping[key], list):
            return "reachable", [k for k in mapping[key] if isinstance(k, str)]
    return "unreachable", []


def kit_source_ls_data() -> dict:
    """Assemble the ``kit-source ls`` required result data (ADR-0038m §2).

    Each source reports ``repository``/``ref``/``directory``/``provider_kits`` and
    an explicit ``discovery_status``. Discovery is best-effort: an unreachable
    source is reported (status ``unreachable``), never an operational failure.
    """
    sources = []
    for src in all_sources():
        status, pkits = discover_provider_kits(src["repository"])
        sources.append(
            {
                "repository": src["repository"],
                "ref": src["ref"],
                "directory": src["directory"],
                "provider_kits": pkits,
                "discovery_status": status,
            }
        )
    return {"sources": sources}


# ---------------------------------------------------------------------------
# Per-sandbox bundle provenance (ADR-0016).
# ---------------------------------------------------------------------------

def provenance_read(backend: str, sandbox: str) -> dict | None:
    """Read a sandbox's provenance record (lenient; a lost record reads unknown)."""
    raw = os.environ.get(PROVENANCE_SEED_ENV)
    if raw is not None:
        try:
            seed = json.loads(raw)
        except json.JSONDecodeError:
            seed = None
        if isinstance(seed, dict) and sandbox in seed:
            return {
                "schema": KIT_SCHEMA,
                "backend": backend,
                "sandbox": sandbox,
                "applied_ref": seed[sandbox],
            }
        return None
    return _read_record(_provenance_path(backend, sandbox), strict=False, label=sandbox)


def provenance_status(backend: str, sandbox: str) -> str:
    """Classify a sandbox's bundle currency: ``current``/``stale``/``unknown``.

    Exact-ref mismatch against the local pin; no network, no git ancestry
    (ADR-0016). A missing/unreadable record reads ``unknown`` (fail-open: it is
    reported and offered a refresh, never a destructive default).
    """
    rec = provenance_read(backend, sandbox)
    if rec is None:
        return "unknown"
    return "current" if rec.get("applied_ref") == CONTROL_PLANE_REF else "stale"


def provenance_write(backend: str, sandbox: str) -> dict:
    """Record a successful bundle reapply (ADR-0016: only after success).

    This writes ``applied_ref``, the only currency signal ``kit check`` reads. It
    is reserved for the kit-apply slice (deferred): ``kit update`` must NOT call
    it — ``kit update`` records *consent* via :func:`consent_write` and never
    claims currency (ADR-0038m §3 drops false partial success).
    """
    doc = {
        "schema": KIT_SCHEMA,
        "backend": backend,
        "sandbox": sandbox,
        "applied_ref": CONTROL_PLANE_REF,
        "recorded_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    _atomic_write(_provenance_path(backend, sandbox), doc)
    return doc


def _consent_dir() -> Path:
    return state.state_dir() / "kit-consent"


def _consent_path(backend: str, sandbox: str) -> Path:
    return _consent_dir() / _safe(backend) / f"{_safe(sandbox)}.{_checksum(sandbox)}.json"


def consent_read(backend: str, sandbox: str) -> dict | None:
    """Read a sandbox's recorded refresh consent (lenient)."""
    return _read_record(_consent_path(backend, sandbox), strict=False, label=sandbox)


def consent_write(backend: str, sandbox: str) -> dict:
    """Record the user's consent to refresh the bundle to the pinned ref.

    Consent is durable and DISTINCT from applied provenance (ADR-0016): this
    record says "the user wants to be on :data:`CONTROL_PLANE_REF`"; it does NOT
    claim the bundle was actually applied. Only the kit-apply slice writes
    ``applied_ref``, so a consent record never changes ``kit check``'s currency.
    """
    doc = {
        "schema": KIT_SCHEMA,
        "backend": backend,
        "sandbox": sandbox,
        "consented_ref": CONTROL_PLANE_REF,
        "recorded_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    _atomic_write(_consent_path(backend, sandbox), doc)
    return doc


# ---------------------------------------------------------------------------
# Per-sandbox agent-kit application record (ADR-0030 create-time install).
# ---------------------------------------------------------------------------

def _kit_applied_dir() -> Path:
    return state.state_dir() / "kit-applied"


def _kit_applied_path(backend: str, sandbox: str) -> Path:
    return _kit_applied_dir() / _safe(backend) / f"{_safe(sandbox)}.{_checksum(sandbox)}.json"


# Applied-kit seed seam (internal test seam, never a secret, never written to
# output). ``ACQ_KIT_APPLIED_SEED`` is a JSON object ``{"<sandbox>": "<kit>"}``
# that, when set, supplies the applied-kit read for a named sandbox, so a
# single-command contract vector can drive ``kit apply`` to an idempotent no-op
# without a prior apply (the same reason ``ACQ_KIT_PROVENANCE_SEED`` seeds
# provenance).
KIT_APPLIED_SEED_ENV = "ACQ_KIT_APPLIED_SEED"


def kit_applied_read(backend: str, sandbox: str) -> dict | None:
    """Read a sandbox's applied agent kit (lenient; absent reads ``None``).

    The record is host-authoritative (ADR-0041m): acq never trusts guest-writable
    state to decide whether an install already happened. A missing/unreadable
    record reads ``None`` (so a re-apply re-runs the idempotent install).
    """
    raw = os.environ.get(KIT_APPLIED_SEED_ENV)
    if raw is not None:
        try:
            seed = json.loads(raw)
        except json.JSONDecodeError:
            seed = None
        if isinstance(seed, dict) and isinstance(seed.get(sandbox), str):
            kit = seed[sandbox]
            return {
                "schema": KIT_SCHEMA,
                "backend": backend,
                "sandbox": sandbox,
                "kit": kit,
                "entrypoint": agent_kit_entrypoint(kit),
            }
        return None
    return _read_record(_kit_applied_path(backend, sandbox), strict=False, label=sandbox)


def kit_applied_write(backend: str, sandbox: str, kit: str, entrypoint: str) -> dict:
    """Record a successful agent-kit apply (host-authoritative, ADR-0041m).

    Written only after the backend reports the in-guest install succeeded
    (ADR-0038m §3 drops false partial success). The kit name and entrypoint are
    non-secret; the install argv carries no credential and is never stored here.
    """
    doc = {
        "schema": KIT_SCHEMA,
        "backend": backend,
        "sandbox": sandbox,
        "kit": kit,
        "entrypoint": entrypoint,
        "recorded_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    _atomic_write(_kit_applied_path(backend, sandbox), doc)
    return doc


def kit_applied_remove(backend: str, sandbox: str) -> None:
    """Drop a sandbox's applied-kit record (best-effort; absent is a no-op).

    Used when the guest filesystem is destroyed out of band — the security-exception
    recreation (ADR-0035) — because the host record that said "agent installed" is
    no longer true, so the next ``kit apply`` re-runs the idempotent install.
    """
    try:
        _kit_applied_path(backend, sandbox).unlink()
    except OSError:
        pass


def kit_check_data(backend: str, sandbox: str) -> dict:
    """Assemble the ``kit check`` required result data (ADR-0038m §2)."""
    rec = provenance_read(backend, sandbox)
    return {
        "sandbox": sandbox,
        "backend": backend,
        "local": CONTROL_PLANE_REF,
        "applied": rec.get("applied_ref") if rec else None,
        "status": provenance_status(backend, sandbox),
    }


# ---------------------------------------------------------------------------
# Minimal structural kit validation (ADR-0038m §kit validate).
# ---------------------------------------------------------------------------

def _finding(code: str, message: str, remediation: str | None = None) -> dict:
    body = {"code": code, "message": message}
    if remediation is not None:
        body["remediation"] = remediation
    return body


# Upper bound on a spec.yaml read by validate_kit.
_MAX_SPEC_BYTES = 1024 * 1024
_SOURCE_LINE = re.compile(r"^\s*(?:-\s*)?source:\s*(.*?)\s*(?:#.*)?$", re.MULTILINE)
_SAFE_SOURCE = re.compile(r"[A-Za-z0-9._/-]+")


def _inside(target: Path, root: Path) -> bool:
    return target == root or root in target.parents


def _spec_file_sources(text: str) -> list[str]:
    """``source:`` values from the spec's top-level ``files:`` block."""
    sources: list[str] = []
    in_files = False
    for line in text.splitlines():
        if line[:1].isalpha():
            in_files = line.startswith("files:")
            continue
        if in_files:
            m = _SOURCE_LINE.match(line)
            if m:
                sources.append(m.group(1).strip("'\" "))
    return sources


def _source_inside_kit(kit_root: Path, source: str) -> bool:
    """Mirror the Bash kit_source_within rule for one files[] source."""
    if not _SAFE_SOURCE.fullmatch(source) or source.startswith("/"):
        return False
    if ".." in source.split("/"):
        return False
    target = (kit_root / source).resolve()
    return _inside(target, kit_root) and target != kit_root and target.is_file()


def validate_kit(path: str) -> dict:
    """Validate a neutral ``hybrid/v1`` kit (a directory or a ``spec.yaml`` path).

    Returns ``{"valid": bool, "findings": [{code, message, remediation?}]}``. This
    is a minimal OFFLINE structural check: the authoritative JSON schema lives in
    the pinned Patterns release and is not bundled here, so this slice checks the
    shape acq itself consumes — a ``spec.yaml`` declaring ``schemaVersion:
    "hybrid/v1"`` and a safe kit name — and reports coded findings. It never
    fetches, sources, or executes anything.

    A kit that cannot be read at all — a missing path, a directory without a
    ``spec.yaml``, or an unreadable ``spec.yaml`` — raises :class:`KitSpecError`
    (an operational failure, exit 1), rather than being reported as an invalid
    kit (which is a successful query answer, exit 0).
    """
    p = Path(path)
    if not p.exists():
        raise KitSpecError(f"kit path does not exist: {path}")
    spec: Path | None = None
    kit_root: Path | None = None
    if p.is_dir():
        kit_root = p.resolve()
        candidate = p / "spec.yaml"
        if not candidate.is_file():
            raise KitSpecError(
                f"no spec.yaml found in {path!r} (a kit is a directory containing spec.yaml)"
            )
        # A kit's own spec.yaml may be a symlink only within the kit directory.
        if not _inside(candidate.resolve(), kit_root):
            raise KitSpecError(f"spec.yaml in {path!r} resolves outside the kit directory")
        spec = candidate
    else:
        spec = p
        kit_root = p.parent.resolve()
    # Only regular files are read (a FIFO or device would block or stream), and
    # only up to a size no real spec approaches.
    if not spec.is_file():
        raise KitSpecError(f"{str(spec)!r} is not a regular file")

    try:
        with open(spec, "rb") as fh:
            raw = fh.read(_MAX_SPEC_BYTES + 1)
    except OSError as exc:
        raise KitSpecError(f"could not read {str(spec)!r}") from exc
    if len(raw) > _MAX_SPEC_BYTES:
        raise KitSpecError(f"{str(spec)!r} is larger than {_MAX_SPEC_BYTES} bytes")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise KitSpecError(f"{str(spec)!r} is not valid UTF-8") from exc

    findings: list[dict] = []
    if not re.search(r"schemaVersion:\s*['\"]?hybrid/v1['\"]?", text):
        findings.append(
            _finding(
                "kit_schema_version",
                'spec.yaml must declare schemaVersion: "hybrid/v1"',
                "author the kit against the neutral hybrid/v1 vocabulary (ADR-0011)",
            )
        )
    name_match = re.search(r"^name:\s*(.*)$", text, re.MULTILINE)
    if not name_match or not name_match.group(1).strip():
        findings.append(_finding("kit_name_missing", "spec.yaml must declare a name"))
    else:
        name = name_match.group(1).strip().strip("'\"")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
            findings.append(
                _finding("kit_name_unsafe", f"unsafe kit name {name!r}")
            )
    for source in _spec_file_sources(text):
        if not _source_inside_kit(kit_root, source):
            findings.append(
                _finding(
                    "kit_file_source_unsafe",
                    f"file source must be a regular file inside the kit directory: {source!r}",
                    "keep files[] sources relative to the kit and inside it (no '..', no absolute paths, no links out)",
                )
            )
    return {"valid": not findings, "findings": findings}
