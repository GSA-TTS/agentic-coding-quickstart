"""Validate host-time provider input bundles before they are projected to guests."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

import jsonschema
import yaml

ROOT = Path(__file__).resolve().parents[1]
SCHEMAS = ROOT / "integrations" / "isolation" / "schemas"
PROJECTED_ROOT = "/var/lib/acq/host/models/providers"
PROVIDER_PATH_PREFIX = "models/providers"
SUPPORTED_BUNDLE_SCHEMAS = {
    "acq-provider-input-bundle/v1": "acq-provider-input-bundle.schema.json",
    "acq-provider-input-bundle/v2": "acq-provider-input-bundle-v2.schema.json",
    "acq-provider-input-bundle/v3": "acq-provider-input-bundle-v3.schema.json",
}
HOST_CREDENTIAL_BINDINGS = SCHEMAS / "provider-credential-bindings.json"

# Host-time validation checks normalizer artifacts before materialization; the
# validator only inspects the file and its launcher metadata and never executes
# it. Provider-shipped normalizers are staged for guest execution, never run on
# the host next to real secrets. The containment requirements for that guest
# execution are defined in
# integrations/isolation/docs/decisions/0004-neutral-model-provider-discovery.md
# and are not enforced by this validator; until an orchestrator enforces them, a
# normalizer must be treated as trusted arbitrary code.
# POSIX expresses a normalizer's executability through mode bits
# (st_mode & 0o111) and os.access(X_OK). Windows reports no mode bits and
# os.access(X_OK) is trivially true there, so those checks are a no-op and must
# be replaced by a content-based contract instead: an allowed extension paired
# with a shebang naming an allowlisted interpreter. The currently supported
# normalizer types are .mjs (Node) and .py (Python). Interpreters are matched
# exactly (after lower-casing and dropping a trailing ".exe"), never by prefix,
# so look-alike names are refused.
NORMALIZER_LAUNCHERS = {
    ".mjs": frozenset({"node"}),
    ".py": frozenset({"python", "python3", "py"}),
}
# Directories a shebang command may live in; a bare command name is also allowed.
SHEBANG_DIRECTORIES = frozenset({"/usr/bin", "/usr/local/bin", "/bin"})
MAX_SHEBANG_BYTES = 4096


class ContractError(ValueError):
    """A provider input bundle is not safe to materialize."""


def load_json(path: Path) -> dict:
    def reject_nonstandard_constant(value: str) -> None:
        raise ValueError(f"non-standard JSON constant {value}")

    try:
        return json.loads(path.read_text(), parse_constant=reject_nonstandard_constant)
    except (OSError, ValueError) as error:
        raise ContractError(f"{path}: cannot read JSON: {error}") from error


def load_credential_bindings(path: Path) -> dict[str, str]:
    document = load_json(path)
    providers = document.get("providers") if isinstance(document, dict) else None
    if not isinstance(providers, dict) or not all(
        isinstance(provider, str) and isinstance(key_env, str) for provider, key_env in providers.items()
    ):
        raise ContractError(f"{path}: providers must be an object mapping provider IDs to credential names")
    return providers


def validate_schema(instance: dict, schema_name: str, label: str, schema_dir: Path = SCHEMAS) -> None:
    schema = load_json(schema_dir / schema_name)
    validator = jsonschema.validators.validator_for(schema)(schema, format_checker=jsonschema.FormatChecker())
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.path))
    if errors:
        raise ContractError(f"{label}: {errors[0].message}")


def reject_unsafe_host(host: str, label: str) -> None:
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return
    raise ContractError(f"{label}: IP address literals are not permitted")


def reject_url_ip_literal(host: str, label: str) -> None:
    """Reject URL-parser IPv4 spellings that are not accepted by ipaddress."""

    def is_url_number(component: str) -> bool:
        lower = component.lower()
        if lower.startswith("0x"):
            return len(component) > 2 and all(character in "0123456789abcdef" for character in lower[2:])
        if len(component) > 1 and component.startswith("0"):
            return all(character in "01234567" for character in component[1:])
        return component.isdecimal()

    labels = host.rstrip(".").split(".")
    if host.endswith(".") or all(is_url_number(component) for component in labels):
        raise ContractError(f"{label}: IP address literals are not permitted")


def validate_url(value: str, host: str, label: str) -> None:
    parsed = urlparse(value)
    try:
        port = parsed.port
    except ValueError as error:
        raise ContractError(f"{label}: has an invalid port") from error
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.fragment
        or port not in (None, 443)
    ):
        raise ContractError(f"{label}: must be an HTTPS URL without credentials or a fragment")
    if parsed.hostname.lower() != host.lower():
        raise ContractError(f"{label}: hostname must equal facts.host")
    if any(character.isspace() for character in value):
        raise ContractError(f"{label}: must not contain whitespace")
    reject_unsafe_host(parsed.hostname, label)
    reject_url_ip_literal(parsed.hostname, label)


def validate_catalog(catalog: dict, provider_id: str, label: str, schema_dir: Path = SCHEMAS) -> None:
    validate_schema(catalog, "acq-neutral-model-catalog.schema.json", label, schema_dir)
    if catalog["providerId"] != provider_id:
        raise ContractError(f"{label}: providerId must equal facts.providerId")
    ids = [model["id"] for model in catalog["models"]]
    duplicates = sorted({model_id for model_id in ids if ids.count(model_id) > 1})
    if duplicates:
        raise ContractError(f"{label}: duplicate model IDs: {', '.join(duplicates)}")
    for role, model_id in catalog.get("recommendations", {}).items():
        if model_id not in ids:
            raise ContractError(f"{label}: recommendations.{role} does not reference models[].id")


def validate_relative_path(value: str, label: str) -> None:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value or value in {"", "."}:
        raise ContractError(f"{label}: must be a non-empty kit-relative path without traversal")


def reject_symlink_components(package_root: Path, relative: str, label: str) -> None:
    current = package_root
    for part in Path(relative).parts:
        current /= part
        if current.is_symlink():
            raise ContractError(f"{label}: path components must not be symlinks")


def _is_windows() -> bool:
    """Platform seam so the Windows launcher branch can be exercised on any host."""
    return os.name == "nt"


def _launcher_name(token: str, *, fold: bool = True) -> str:
    """Return the command name of a shebang token, or "" if its directory is untrusted.

    A token with a slash must name one of SHEBANG_DIRECTORIES (so "/python3" is
    refused); a token without a slash is a bare command. With ``fold`` the name
    is lower-cased and one trailing ".exe" is dropped.
    """
    directory, slash, name = token.rpartition("/")
    if (slash and not directory) or (slash and directory not in SHEBANG_DIRECTORIES):
        return ""
    return name.lower().removesuffix(".exe") if fold else name


def normalizer_shebang_interpreter(path: Path) -> str:
    """Return the normalized interpreter named by a normalizer's shebang.

    Handles ``#!/usr/bin/python3`` and ``#!/usr/bin/env python3`` and nothing
    more: the shebang must be exactly the interpreter, or ``env`` plus the
    interpreter. Trailing arguments are rejected in both forms. With ``env`` they
    would make it search for an executable literally named ``python3 -u`` (exit
    127), and in the direct form the kernel would pass them to the interpreter
    as one unchecked argument (such as ``-c``) that this contract cannot
    verify. The result is lower-cased, has any trailing ``.exe`` removed, and is
    compared against the allowlist by exact match. As with a kernel, ``#!`` must be the first two bytes and tokens
    are separated by ASCII spaces or tabs only. Returns an empty string when the
    file has no shebang, is not decodable text, cannot be read, names an
    interpreter in an untrusted directory, behind an unsupported ``env`` form
    (options, assignments), is followed by extra tokens, or has a first line
    longer than ``MAX_SHEBANG_BYTES``.

    Only a *complete* first line is ever parsed. A line that does not end inside
    the read window is refused rather than partially parsed: its unseen tail can
    hold a forbidden trailing token, so accepting the visible prefix would let an
    allowlisted interpreter at the front vouch for an unread argument at the
    back.
    """
    try:
        with path.open("rb") as handle:
            # Ask for one byte past the limit. ``readline`` stops at a newline or
            # at the byte count, so a buffer longer than the limit proves the
            # first line did not end inside it. The extra byte is what makes that
            # distinction exact: a line of exactly MAX_SHEBANG_BYTES bytes still
            # ends within the limit and is parsed, while anything longer is not.
            first_line = handle.readline(MAX_SHEBANG_BYTES + 1)
    except OSError:
        return ""
    if len(first_line) > MAX_SHEBANG_BYTES:
        return ""
    if not first_line.startswith(b"#!"):
        return ""
    try:
        shebang = first_line[2:].decode("utf-8")
    except UnicodeDecodeError:
        return ""
    tokens = [token for token in re.split(r"[ \t]+", shebang.strip(" \t\r\n")) if token]
    if not tokens:
        return ""
    if _launcher_name(tokens[0], fold=False) == "env":
        if len(tokens) != 2:
            return ""
        return _launcher_name(tokens[1])
    if len(tokens) != 1:
        return ""
    return _launcher_name(tokens[0])


def validate_normalizer_launcher(normalizer_path: Path, bundle_path: Path) -> None:
    """Enforce the Windows-verifiable normalizer launcher contract."""
    allowed = NORMALIZER_LAUNCHERS.get(normalizer_path.suffix.lower())
    if allowed is None:
        extensions = ", ".join(sorted(NORMALIZER_LAUNCHERS))
        raise ContractError(f"{bundle_path}: normalizerPath must end in a supported launcher extension ({extensions})")
    if normalizer_shebang_interpreter(normalizer_path) not in allowed:
        names = ", ".join(sorted(allowed))
        raise ContractError(f"{bundle_path}: normalizerPath must declare a shebang naming one of: {names}")


def validate_bundle(
    bundle_path: Path,
    credential_bindings: dict[str, str] | None = None,
    seen_provider_ids: set[str] | None = None,
    schema_dir: Path = SCHEMAS,
) -> None:
    if credential_bindings is None:
        credential_bindings = load_json(HOST_CREDENTIAL_BINDINGS)["providers"]
    bundle = load_json(bundle_path)
    if not isinstance(bundle, dict):
        raise ContractError(f"{bundle_path}: bundle root must be an object")
    schema_version = bundle.get("schemaVersion")
    if not isinstance(schema_version, str):
        raise ContractError(f"{bundle_path}: bundle schemaVersion must be a string")
    schema_name = SUPPORTED_BUNDLE_SCHEMAS.get(schema_version)
    if schema_name is None:
        raise ContractError(f"{bundle_path}: unsupported bundle schemaVersion")
    validate_schema(bundle, schema_name, str(bundle_path), schema_dir)
    package_root = bundle_path.parent
    resolved_package_root = package_root.resolve()
    data_only = schema_version == "acq-provider-input-bundle/v3"
    artifact_fields = ("factsPath", "snapshotPath") if data_only else ("factsPath", "snapshotPath", "normalizerPath")
    for field in artifact_fields:
        validate_relative_path(bundle[field], f"{bundle_path}: {field}")
        reject_symlink_components(package_root, bundle[field], f"{bundle_path}: {field}")
    facts_path = package_root / bundle["factsPath"]
    snapshot_path = package_root / bundle["snapshotPath"]
    for field in artifact_fields:
        path = package_root / bundle[field]
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(resolved_package_root):
            raise ContractError(f"{bundle_path}: declared artifact paths must be regular files inside the provider kit")
    if not data_only:
        normalizer_path = package_root / bundle["normalizerPath"]
        if not facts_path.is_file() or not snapshot_path.is_file() or not normalizer_path.is_file():
            raise ContractError(f"{bundle_path}: declared artifact paths must be regular files")
        # POSIX expresses executability through mode bits; Windows reports no exec
        # bits and os.access(X_OK) is trivially true there, so those checks cannot
        # prove executability on Windows. Keep the POSIX mode-bit + X_OK checks as
        # the executability contract there, and on Windows enforce the
        # extension + shebang launcher contract instead (see NORMALIZER_LAUNCHERS),
        # so a data file without a runnable association is rejected rather than
        # staged as a normalizer.
        if not _is_windows():
            if not normalizer_path.stat().st_mode & 0o111:
                raise ContractError(f"{bundle_path}: normalizerPath must be an executable file")
            if not os.access(normalizer_path, os.X_OK):
                raise ContractError(f"{bundle_path}: normalizerPath is not executable by the validator")
        else:
            validate_normalizer_launcher(normalizer_path, bundle_path)
    facts = load_json(facts_path)
    validate_schema(facts, "acq-provider-facts.schema.json", str(facts_path), schema_dir)
    provider_id = facts["providerId"]
    if bundle["providerId"] != provider_id:
        raise ContractError(f"{bundle_path}: providerId must equal facts.providerId")
    if data_only and bundle["discovery"]["adapter"] == "usai-openai-list/v1" and provider_id != "usai":
        raise ContractError(f"{bundle_path}: discovery.adapter usai-openai-list/v1 requires providerId usai")
    spec_path = package_root / "spec.yaml"
    if spec_path.is_file():
        spec = yaml.safe_load(spec_path.read_text())
        allowed_hosts = set(spec.get("caps", {}).get("network", {}).get("allow", []))
    else:
        allowed_hosts = {facts["host"]}
    if credential_bindings is not None and credential_bindings.get(provider_id) != facts["keyEnv"]:
        raise ContractError(f"{bundle_path}: facts.keyEnv must match the host credential binding")
    if facts["keyEnv"] not in bundle["credentialEnvNames"]:
        raise ContractError(
            f"{bundle_path}: facts.keyEnv '{facts['keyEnv']}' must be declared in bundle credentialEnvNames"
        )
    if seen_provider_ids is not None:
        if provider_id in seen_provider_ids:
            raise ContractError(f"{bundle_path}: duplicate providerId '{provider_id}'")
        seen_provider_ids.add(provider_id)
    reject_unsafe_host(facts["host"], str(facts_path))
    if facts["host"] not in allowed_hosts:
        raise ContractError(f"{bundle_path}: facts.host must be in the kit network allowlist")
    validate_url(facts["baseUrl"], facts["host"], f"{facts_path}: baseUrl")
    validate_url(facts["modelsUrl"], facts["host"], f"{facts_path}: modelsUrl")
    validate_catalog(load_json(snapshot_path), provider_id, str(snapshot_path), schema_dir)
    if bundle["schemaVersion"] == "acq-provider-input-bundle/v1":
        expected_projection = f"{PROJECTED_ROOT}/{provider_id}"
        if bundle["projectedPath"] != expected_projection:
            raise ContractError(f"{bundle_path}: projectedPath must be {expected_projection}")
    else:
        expected_provider_path = f"{PROVIDER_PATH_PREFIX}/{provider_id}"
        if bundle["providerPath"] != expected_provider_path:
            raise ContractError(f"{bundle_path}: providerPath must be {expected_provider_path}")


def discovered_bundles() -> list[Path]:
    """Find fixtures and canonical provider bundles, not backend-specific copies."""
    return sorted((SCHEMAS / "fixtures").glob("*/bundle.json")) + sorted(
        ROOT.glob("integrations/isolation/acq-kits/*/provider-input.json")
    )


def split_discovered_bundles(bundles: list[Path]) -> tuple[list[Path], list[Path]]:
    """Split discovered bundles into (fixture_bundles, kit_bundles).

    Classification is path-based rather than string-based so it is independent of
    the host's path separator (a naive ``"/schemas/fixtures/" in str(bundle)``
    check never matches Windows ``\\`` separators). Fixtures live under
    ``schemas/fixtures``; everything else discovered is a canonical provider kit.
    """
    fixtures_root = SCHEMAS / "fixtures"
    fixture_bundles = [bundle for bundle in bundles if fixtures_root in bundle.parents]
    kit_bundles = [bundle for bundle in bundles if bundle not in fixture_bundles]
    return fixture_bundles, kit_bundles


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", action="append", type=Path, help="explicit manifest (repeatable)")
    parser.add_argument("--credential-bindings", type=Path, default=HOST_CREDENTIAL_BINDINGS)
    parser.add_argument("--schema-dir", type=Path, default=SCHEMAS)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    bundles = args.bundle or discovered_bundles()
    if not bundles:
        print("provider input contract: no bundles discovered", file=sys.stderr)
        return 1
    try:
        credential_bindings = load_credential_bindings(args.credential_bindings)
        if args.bundle:
            seen_provider_ids: set[str] = set()
            for bundle in bundles:
                validate_bundle(bundle, credential_bindings, seen_provider_ids, args.schema_dir)
        else:
            fixture_bundles, kit_bundles = split_discovered_bundles(bundles)
            for bundle in fixture_bundles:
                validate_bundle(bundle, credential_bindings, schema_dir=args.schema_dir)
            seen_provider_ids = set()
            for bundle in kit_bundles:
                validate_bundle(bundle, credential_bindings, seen_provider_ids, args.schema_dir)
    except ContractError as error:
        print(f"provider input contract: {error}", file=sys.stderr)
        return 1
    print(f"provider input contract: validated {len(bundles)} bundle(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
