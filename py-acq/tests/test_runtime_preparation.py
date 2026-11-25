"""Offline protocol evidence; these tests do not claim backend execution."""

import ast
import json
from dataclasses import FrozenInstanceError, fields, replace
from pathlib import Path

import pytest

from acq_py import runtime_preparation as preparation


@pytest.fixture
def identity():
    return preparation.InvocationIdentity(
        attempt_nonce="attempt-1", sandbox_instance="sandbox-instance-1",
        exact_generation="generation.immutable-1", routing_digest="1" * 64,
        artifact_sha256="2" * 64, base_config_sha256="3" * 64,
    )


def success(metadata="not-requested"):
    return json.dumps({"sourceOutcome": "live", "metadataOutcome": metadata}).encode()


def failure(stage="membership", reason="connection", failure_class="transient", **extra):
    return json.dumps({
        "schemaVersion": "acq-runtime-model-outcome/v1", "outcome": "failure",
        "stage": stage, "reason": reason, "failureClass": failure_class, **extra,
    }).encode()


@pytest.mark.parametrize("metadata", ["not-requested", "unavailable", "available-unverified"])
def test_live_success_is_bound_to_host_identity(identity, metadata):
    result = preparation.parse_result(identity, returncode=0, stdout=success(metadata) + b"\n")
    assert result.identity is identity
    assert result.source_outcome == "live"
    assert result.metadata_outcome == metadata
    assert preparation.require_current(result, replace(identity)) is result


@pytest.mark.parametrize("payload", [
    b"", b"\xff", b"\xef\xbb\xbf{}", b"{} {}", b"[]", b"null", b"true", b"1", b'"text"',
    b"{}", b'{"sourceOutcome":"live"}',
    b'{"sourceOutcome":"live","metadataOutcome":"not-requested","extra":"field"}',
    b'{"sourceOutcome":"live","sourceOutcome":"live","metadataOutcome":"not-requested"}',
    b'{"sourceOutcome":"live","metadataOutcome":NaN}',
    b'{"sourceOutcome":"live","metadataOutcome":Infinity}',
    b'{"sourceOutcome":"live","metadataOutcome":-Infinity}',
    b'{"sourceOutcome":"live","metadataOutcome":1e999}',
    b'{"sourceOutcome":"live","metadataOutcome":true}',
    b'{"sourceOutcome":"live","metadataOutcome":null}',
    b'{"sourceOutcome":"live","metadataOutcome":[]}',
    b'{"sourceOutcome":{},"metadataOutcome":"not-requested"}',
    b'{"sourceOutcome":"snapshot-nonlive","metadataOutcome":"not-requested"}',
    b'{"sourceOutcome":"live","metadataOutcome":"verified"}',
    b'{"sourceOutcome":"live","metadataOutcome":"\\ud800"}',
    b"[" * 500 + b"]" * 500,
    failure(),
])
def test_invalid_success_refuses_without_raw_diagnostics(identity, payload):
    with pytest.raises(preparation.PreparationError) as error:
        preparation.parse_result(identity, returncode=0, stdout=payload)
    assert "sourceOutcome" not in str(error.value)
    assert error.value.__cause__ is None


@pytest.mark.parametrize("payload", [None, "{}", bytearray(b"{}"), memoryview(b"{}"), 1, True])
def test_output_must_be_bytes(identity, payload):
    with pytest.raises(preparation.PreparationError):
        preparation.parse_result(identity, returncode=0, stdout=payload)


def test_byte_limit_includes_whitespace(identity):
    payload = success()
    at_limit = payload + b" " * (preparation.MAX_OUTPUT_BYTES - len(payload))
    preparation.parse_result(identity, returncode=0, stdout=at_limit)
    with pytest.raises(preparation.PreparationError):
        preparation.parse_result(identity, returncode=0, stdout=at_limit + b" ")
    with pytest.raises(preparation.PreparationError):
        preparation.parse_result(identity, returncode=1, stdout=failure() + b" " * 1024)


@pytest.mark.parametrize("returncode", [1, 2, 127, -9, -15])
@pytest.mark.parametrize("payload", [success(), failure(), b"diagnostic-canary"])
def test_nonzero_never_yields_a_result(identity, returncode, payload):
    with pytest.raises(preparation.PreparationError) as error:
        preparation.parse_result(identity, returncode=returncode, stdout=payload)
    assert "diagnostic-canary" not in str(error.value)


@pytest.mark.parametrize("returncode", [False, True, 0.0, "0", None])
def test_invalid_exit_status(identity, returncode):
    with pytest.raises(preparation.PreparationError):
        preparation.parse_result(identity, returncode=returncode, stdout=success())


@pytest.mark.parametrize("stage,reason,failure_class", [
    ("input", "invalid-input", "hard"), ("trust", "invalid-trust", "hard"),
    ("membership", "authentication", "hard"), ("membership", "response-identity", "hard"),
    ("membership", "tls", "hard"), ("membership", "http-refused", "hard"),
    ("membership", "invalid-response", "hard"), ("membership", "unknown", "hard"),
    ("membership", "provider-throttled", "transient"),
    ("membership", "provider-unavailable", "transient"),
    ("membership", "connection", "transient"), ("membership", "request-abort", "transient"),
    ("child", "child-protocol", "hard"), ("child", "child-crash", "hard"),
    ("preparation", "parent-deadline", "hard"), ("preparation", "lock", "hard"),
    ("preparation", "render", "hard"), ("preparation", "unknown", "hard"),
])
def test_closed_failure_classification_is_diagnostic_only(identity, stage, reason, failure_class):
    with pytest.raises(preparation.PreparationError) as error:
        preparation.parse_result(identity, returncode=1,
                                 stdout=failure(stage, reason, failure_class))
    assert str(error.value) == f"runtime preparation failed: {stage}/{reason}/{failure_class}"


@pytest.mark.parametrize("payload", [
    failure("child", "connection", "transient"),
    failure("membership", "connection", "hard"),
    failure("membership", "tls", "transient"),
    failure("preparation", "parent-deadline", "transient"),
    failure("diagnostic-canary", "unknown", "hard"),
    failure(reason="diagnostic-canary"), failure(extra="diagnostic-canary"),
    failure(schemaVersion="acq-runtime-model-outcome/v2"), failure(outcome="success"),
    failure(failure_class=False),
    failure().replace(b'"stage": "membership",', b""),
    failure().replace(b'"outcome": "failure",', b'"outcome":"failure","outcome":"failure",'),
])
def test_failure_envelope_is_closed(identity, payload):
    with pytest.raises(preparation.PreparationError) as error:
        preparation.parse_result(identity, returncode=1, stdout=payload)
    assert "protocol" in str(error.value)
    assert "diagnostic-canary" not in str(error.value)


@pytest.mark.parametrize("field", [field.name for field in fields(preparation.InvocationIdentity)])
def test_every_identity_field_is_checked_before_consumption(identity, field):
    result = preparation.parse_result(identity, returncode=0, stdout=success())
    changed = "4" * 64 if field.endswith(("digest", "sha256")) else "other-identity"
    with pytest.raises(preparation.PreparationError, match="identity changed"):
        preparation.require_current(result, replace(identity, **{field: changed}))


def test_failure_does_not_make_earlier_attempt_reusable(identity):
    earlier = preparation.parse_result(identity, returncode=0, stdout=success())
    current = replace(identity, attempt_nonce="attempt-2")
    with pytest.raises(preparation.PreparationError):
        preparation.parse_result(current, returncode=1, stdout=failure())
    with pytest.raises(preparation.PreparationError):
        preparation.require_current(earlier, current)


@pytest.mark.parametrize("field", [field.name for field in fields(preparation.InvocationIdentity)])
@pytest.mark.parametrize("value", [None, True, 1, [], {}, "", "\n", "x" * 257])
def test_identity_rejects_invalid_field_types_and_shapes(identity, field, value):
    with pytest.raises(preparation.PreparationError):
        replace(identity, **{field: value})


@pytest.mark.parametrize("value", ["A" * 64, "a" * 63, "g" * 64, "a" * 64 + "\n"])
def test_digest_is_exact_lowercase_sha256(identity, value):
    with pytest.raises(preparation.PreparationError):
        replace(identity, routing_digest=value)


def test_immutable_result_and_nested_identity(identity):
    result = preparation.parse_result(identity, returncode=0, stdout=success())
    for target, field, value in [(identity, "attempt_nonce", "new"),
                                 (result, "metadata_outcome", "verified"),
                                 (result, "identity", None)]:
        with pytest.raises(FrozenInstanceError):
            setattr(target, field, value)
        assert not hasattr(target, "__dict__")


def test_runtime_result_and_identity_type_checks(identity):
    result = preparation.parse_result(identity, returncode=0, stdout=success())
    for bad in [None, {}, "identity", True]:
        with pytest.raises(preparation.PreparationError):
            preparation.parse_result(bad, returncode=0, stdout=success())
        with pytest.raises(preparation.PreparationError):
            preparation.require_current(result, bad)
        with pytest.raises(preparation.PreparationError):
            preparation.require_current(bad, identity)
    for updates in [{"source_outcome": "snapshot-nonlive"}, {"source_outcome": False},
                    {"metadata_outcome": []}, {"metadata_outcome": "verified"}, {"identity": {}}]:
        with pytest.raises(preparation.PreparationError):
            replace(result, **updates)


PATHS = dict(node="/usr/bin/node", artifact="/opt/acq/runtime-preparation.mjs",
             provider_root="/opt/providers/generation.1", global_dir="/home/agent/.config/opencode",
             base_config="/opt/acq/base config.jsonc")


def test_fixed_argv_has_no_ambient_defaults_or_shell():
    assert preparation.build_argv(**PATHS) == (
        "/usr/bin/node", "/opt/acq/runtime-preparation.mjs",
        "--provider-root", "/opt/providers/generation.1",
        "--global-dir", "/home/agent/.config/opencode",
        "--base-config", "/opt/acq/base config.jsonc", "--mode", "live-required",
    )
    shell_like_path = "/opt/acq/$(not-a-command);file"
    assert preparation.build_argv(**{**PATHS, "base_config": shell_like_path})[-3] == shell_like_path


@pytest.mark.parametrize("field", list(PATHS))
@pytest.mark.parametrize("value", [None, True, 1, Path("/valid"), "", "/", "relative",
                                   "--mode", "//absolute", "/a//b", "/a/./b", "/a/../b",
                                   "/a/", "/a\x00b", "/a\nb", "/a\tb", "/a\\b",
                                   "/a\ud800b", "/" + "x" * 4096])
def test_guest_paths_are_lexically_validated(field, value):
    with pytest.raises(preparation.PreparationError, match="invalid guest path"):
        preparation.build_argv(**{**PATHS, field: value})


def test_import_has_only_stdlib_definitions_and_constant_construction():
    # Static inspection avoids subprocess/import-hook tricks. No module-scope
    # executable statement may read files, environment, network or run a child.
    tree = ast.parse(Path(preparation.__file__).read_text())
    allowed_imports = {"__future__", "json", "re", "dataclasses", "pathlib", "typing"}
    allowed_calls = {"re.compile", "frozenset", "dataclass"}
    for node in tree.body:
        if isinstance(node, ast.Import):
            assert all(alias.name in allowed_imports for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            assert node.module in allowed_imports
        elif isinstance(node, ast.FunctionDef):
            assert not node.decorator_list
            assert not node.args.defaults
            assert not any(node.args.kw_defaults)
        elif isinstance(node, ast.ClassDef):
            nodes = list(node.decorator_list) + [child for child in node.body
                                                if not isinstance(child, ast.FunctionDef)]
            for child in nodes:
                for call in ast.walk(child):
                    if isinstance(call, ast.Call):
                        assert ast.unparse(call.func) in allowed_calls
        else:
            assert isinstance(node, (ast.Assign, ast.AnnAssign, ast.Expr))
            for call in ast.walk(node):
                if isinstance(call, ast.Call):
                    assert ast.unparse(call.func) in allowed_calls
