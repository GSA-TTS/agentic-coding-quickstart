"""Qualification harness tests (ADR-0044m) — the transcript RESULT signature,
the BLOCKED first-class verdict, the 3-attempt reproduction rule, and the
qualified/unqualified/blocked matrix.

These are Tier-2 implementation tests (non-contract); the subprocess-boundary
evidence for the same guarantees lives in ``test/vectors/qualification/``. Each
guard is written so that mutating it (dropping a divergence check, reporting a
one-off FAIL as definitive, or treating an unqualified cell as a pass) fails the
suite.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# The harness is repo-root tooling (not part of the acq_py package); make it
# importable alongside the py-acq/src path conftest already adds.
REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from qualification import (  # noqa: E402
    BINDING_FIELDS,
    Environment,
    MatrixState,
    Outcome,
    Transcript,
    Verdict,
    cell_state,
    classify_exit,
    format_result_line,
    is_claimed,
    is_current,
    report_matrix,
    reproduce,
    run_cell,
    sha256_hex,
    touches_surface,
    transcript_document,
)


def make_env(**overrides) -> Environment:
    base = dict(
        os="Linux",
        os_build="6.1.0",
        arch="x86_64",
        hypervisor="native",
        backend="msb",
        backend_version="0.7.7",
        image="img",
        rev="a" * 40,
        artifact_sha256="b" * 64,
        transcript_dir="/tmp/qualify-test",
    )
    base.update(overrides)
    return Environment(**base)


NOW = datetime(2026, 11, 7, 12, 0, tzinfo=timezone.utc)


def make_transcript(
    verdict: Verdict, env: Environment | None = None, recorded_at: datetime | None = None
) -> Transcript:
    return Transcript(
        verdict,
        env or make_env(),
        ("cmd",),
        "c" * 64,
        "detail",
        (recorded_at or NOW - timedelta(days=1)).isoformat(),
    )


# --- verbatim RESULT signature ------------------------------------------------

def test_result_line_matches_adr_signature_msb():
    env = make_env(backend="msb", backend_version="0.7.7", os="Linux", arch="x86_64")
    line = format_result_line("PASS", env)
    assert line == (
        "RESULT PASS msb=0.7.7 image=img host=Linux x86_64 "
        f"rev={'a' * 40} dir=/tmp/qualify-test"
    )


def test_result_line_generalises_backend_token_to_sbx():
    env = make_env(backend="sbx", backend_version="0.39.0", os="Linux", arch="x86_64")
    assert format_result_line("FAIL", env).startswith("RESULT FAIL sbx=0.39.0 ")


def test_result_line_host_is_os_and_arch_with_space():
    env = make_env(os="Darwin", arch="arm64")
    assert "host=Darwin arm64" in format_result_line("PASS", env)


def test_result_line_verdict_is_restricted_to_pass_fail_blocked():
    for verdict in ("PASS", "FAIL", "BLOCKED"):
        line = format_result_line(verdict, make_env())
        assert line.startswith(f"RESULT {verdict} ")
    # The RESULT line never carries the escalation token directly.
    assert not format_result_line("FAIL", make_env()).startswith("RESULT FLAKY")


# --- BLOCKED is first-class, never a pass -------------------------------------

def test_classify_exit_maps_zero_to_pass_two_to_blocked_else_fail():
    assert classify_exit(0) is Verdict.PASS
    assert classify_exit(2) is Verdict.BLOCKED
    assert classify_exit(1) is Verdict.FAIL
    assert classify_exit(3) is Verdict.FAIL
    assert classify_exit(127) is Verdict.FAIL


def test_missing_command_records_blocked_never_pass():
    result = run_cell(
        ["definitely-not-a-real-command-xyz"], make_env(), timeout=5.0
    )
    assert result.outcome is Outcome.BLOCKED
    assert result.attempts[0].verdict is Verdict.BLOCKED
    assert result.attempts[0].verdict is not Verdict.PASS


def test_unqualified_cell_records_blocked_never_pass():
    result = run_cell(
        ["/bin/true"], make_env(), unqualified=True, timeout=5.0
    )
    assert result.outcome is Outcome.BLOCKED
    assert result.attempts[0].verdict is Verdict.BLOCKED
    assert result.attempts[0].detail == "unqualified cell: not claimed"


def test_exit_two_records_blocked_never_pass():
    result = run_cell(
        [sys.executable, "-c", "raise SystemExit(2)"], make_env(), timeout=5.0
    )
    assert result.outcome is Outcome.BLOCKED
    assert result.attempts[0].verdict is Verdict.BLOCKED


# --- 3-attempt reproduction rule ----------------------------------------------

def _always(transcript: Transcript):
    def run_once(_attempt: int) -> Transcript:
        return transcript

    return run_once


def test_fail_reproduces_within_three_attempts_is_fail():
    result = reproduce(_always(make_transcript(Verdict.FAIL)))
    assert result.outcome is Outcome.FAIL
    assert len(result.attempts) == 3
    assert all(a.verdict is Verdict.FAIL for a in result.attempts)


def test_one_off_fail_without_reproduction_evidence_is_flaky():
    # max_attempts=1 leaves no reproduction evidence: never a definitive FAIL.
    result = reproduce(_always(make_transcript(Verdict.FAIL)), max_attempts=1)
    assert result.outcome is Outcome.FLAKY


def test_diverging_verdicts_across_attempts_is_flaky():
    outcomes = [Verdict.FAIL, Verdict.PASS, Verdict.FAIL]

    def run_once(attempt: int) -> Transcript:
        return make_transcript(outcomes[attempt - 1])

    result = reproduce(run_once)
    assert result.outcome is Outcome.FLAKY
    assert len(result.attempts) == 2  # stops at the first divergence


def test_diverging_binding_identity_is_flaky():
    def run_once(attempt: int) -> Transcript:
        env = make_env(backend_version="0.7.7" if attempt == 1 else "0.8.0")
        return make_transcript(Verdict.FAIL, env)

    result = reproduce(run_once)
    assert result.outcome is Outcome.FLAKY


def test_non_binding_fields_may_differ_without_flaky():
    # transcript_dir is not a binding field (ADR-0044m): it may differ.
    def run_once(attempt: int) -> Transcript:
        env = make_env(transcript_dir=f"/tmp/qualify-{attempt}")
        return make_transcript(Verdict.FAIL, env)

    result = reproduce(run_once)
    assert result.outcome is Outcome.FAIL
    assert len(result.attempts) == 3


def test_binding_fields_exactly_match_adr_list():
    assert BINDING_FIELDS == (
        "rev",
        "artifact_sha256",
        "backend_version",
        "os_build",
        "hypervisor",
    )
    assert "transcript_dir" not in BINDING_FIELDS


def test_pass_and_blocked_on_first_attempt_are_final():
    assert reproduce(_always(make_transcript(Verdict.PASS))).outcome is Outcome.PASS
    blocked = reproduce(_always(make_transcript(Verdict.BLOCKED)))
    assert blocked.outcome is Outcome.BLOCKED
    assert len(blocked.attempts) == 1


# --- matrix states ------------------------------------------------------------

def test_matrix_reports_unqualified_cells_honestly():
    reports = report_matrix({}, now=NOW)
    by_cell = {(r.backend, r.platform): r for r in reports}

    # Windows ARM64 and musl are unqualified for every backend.
    for backend in ("msb", "sbx"):
        assert by_cell[(backend, "windows-arm64")].state is MatrixState.UNQUALIFIED
        assert by_cell[(backend, "windows-arm64")].claimed is False
        assert by_cell[(backend, "linux-musl")].state is MatrixState.UNQUALIFIED

    # sbx on macOS x86_64 and Linux aarch64 are unqualified (not claimed).
    assert by_cell[("sbx", "macos-x86_64")].state is MatrixState.UNQUALIFIED
    assert by_cell[("sbx", "linux-aarch64")].state is MatrixState.UNQUALIFIED

    # Claimed cells without a green transcript are blocked (hold the gate).
    assert by_cell[("msb", "linux-x86_64")].claimed is True
    assert by_cell[("msb", "linux-x86_64")].state is MatrixState.BLOCKED
    assert by_cell[("sbx", "windows-x64")].claimed is True
    assert by_cell[("sbx", "windows-x64")].state is MatrixState.BLOCKED


def test_claimed_cell_is_qualified_only_with_green_current_transcript():
    green = make_transcript(Verdict.PASS)
    state = cell_state("msb", "linux-x86_64", transcript=green, now=NOW)
    assert state is MatrixState.QUALIFIED


def test_commit_and_artifact_do_not_expire_a_transcript():
    # A release commit changes the SHA and artifact hash but not behaviour; the
    # transcript recorded for another rev/artifact stays current.
    green = make_transcript(Verdict.PASS, make_env(rev="a" * 40, artifact_sha256="b" * 64))
    assert is_current(green, now=NOW)
    assert cell_state("msb", "linux-x86_64", transcript=green, now=NOW) is MatrixState.QUALIFIED


def test_transcript_older_than_the_window_is_stale():
    old = make_transcript(Verdict.PASS, recorded_at=NOW - timedelta(days=91))
    assert not is_current(old, now=NOW)
    assert cell_state("msb", "linux-x86_64", transcript=old, now=NOW) is MatrixState.BLOCKED
    edge = make_transcript(Verdict.PASS, recorded_at=NOW - timedelta(days=90))
    assert is_current(edge, now=NOW)


def test_backend_minor_change_is_stale_patch_is_not():
    green = make_transcript(Verdict.PASS, make_env(backend_version="0.7.7"))
    assert is_current(green, now=NOW, backend_version="0.7.11")
    assert not is_current(green, now=NOW, backend_version="0.8.0")
    assert not is_current(green, now=NOW, backend_version="1.7.7")
    assert is_current(green, now=NOW)  # no version under acceptance -> not checked


def test_tier3_surface_change_is_stale():
    green = make_transcript(Verdict.PASS)
    assert not is_current(green, now=NOW, surface_changed=True)
    state = cell_state("msb", "linux-x86_64", transcript=green, now=NOW, surface_changed=True)
    assert state is MatrixState.BLOCKED


def test_unparseable_backend_versions_fail_closed():
    for recorded in ("unknown", "", "0.7.7-rc1", "0.7.7+build", "v0.7.7", "msb 0.7.7"):
        t = make_transcript(Verdict.PASS, make_env(backend_version=recorded))
        assert not is_current(t, now=NOW, backend_version="0.7.7"), recorded
    green = make_transcript(Verdict.PASS, make_env(backend_version="0.7.7"))
    for under_acceptance in ("unknown", "", "0.7.7-rc1", "garbage"):
        assert not is_current(green, now=NOW, backend_version=under_acceptance), under_acceptance
    both = make_transcript(Verdict.PASS, make_env(backend_version="unknown"))
    assert not is_current(both, now=NOW, backend_version="garbage")


def test_future_dated_transcript_is_never_current():
    future = make_transcript(Verdict.PASS, recorded_at=NOW + timedelta(days=1))
    assert not is_current(future, now=NOW)


def test_naive_now_is_a_programming_error():
    import pytest

    with pytest.raises(ValueError):
        is_current(make_transcript(Verdict.PASS), now=datetime(2026, 11, 7, 12, 0))


def test_report_matrix_propagates_version_and_surface_inputs():
    green = make_transcript(Verdict.PASS, make_env(backend_version="0.7.7"))
    cells = {("msb", "linux-x86_64"): green}

    def state(**kw):
        reports = report_matrix(cells, now=NOW, **kw)
        return {(r.backend, r.platform): r.state for r in reports}[("msb", "linux-x86_64")]

    assert state() is MatrixState.QUALIFIED
    assert state(backend_versions={"msb": "0.7.11"}) is MatrixState.QUALIFIED
    assert state(backend_versions={"msb": "0.8.0"}) is MatrixState.BLOCKED
    assert state(surface_changed=True) is MatrixState.BLOCKED


def test_unknown_or_naive_recorded_at_is_never_current():
    green = make_transcript(Verdict.PASS)
    for bad in ("", "not-a-date", "2026-11-06T12:00:00"):
        t = Transcript(Verdict.PASS, green.environment, green.commands, green.output_sha256, "", bad)
        assert not is_current(t, now=NOW)


def test_touches_surface_distinguishes_release_commits():
    release_commit = [
        ".release-please-manifest.json", "CHANGELOG.md", "README.md",
        "docs/howto/acq.md", "install.sh", "install.ps1", "package.json",
    ]
    assert not touches_surface(release_commit)
    assert not touches_surface(["py-acq/tests/test_lifecycle.py", ".github/workflows/release.yml"])
    assert touches_surface(["py-acq/src/acq_py/cli.py"])
    assert touches_surface(["scripts/qualify-backend-cell"])
    assert touches_surface(["qualification/runner.py", "README.md"])
    assert touches_surface(["qualification/cli.py"])
    # The matrix, ledger and gate only read transcripts; they are not the surface.
    assert not touches_surface(["qualification/matrix.py", "qualification/ledger.py", "qualification/gate.py"])
    assert not touches_surface(["py-acq/src_other/x.py"])
    assert not touches_surface(["scripts/qualify-backend-cell-x"])


def test_touches_surface_version_output_is_not_surface():
    # ADR-0044m: no oracle asserts the `version` command's exact output fields, and
    # its data + human/JSON output live together in version_info.py (run_version was
    # split out of cli.py). A version-output-only change must not expire a transcript.
    assert not touches_surface(["py-acq/src/acq_py/version_info.py"])
    assert not touches_surface(["py-acq/src/acq_py/version_info.py", "py-acq/src/acq_py/__init__.py"])
    # doctor/runtime and the deterministic test backends are likewise off-surface.
    assert not touches_surface(["py-acq/src/acq_py/doctor.py", "py-acq/src/acq_py/runtime.py"])
    assert not touches_surface(["py-acq/src/acq_py/_stub_msb.py", "py-acq/src/acq_py/_stub_sbx.py"])


def test_touches_surface_contract_modules_are_surface():
    # A diff to a genuinely contract-bearing module must still trigger the surface.
    for module in (
        "__main__.py", "backends.py", "cli.py", "config.py", "envelope.py",
        "errors.py", "kits.py", "lock.py", "migration.py", "msb.py",
        "provider_creds.py", "sbx.py", "security.py", "state.py",
    ):
        assert touches_surface([f"py-acq/src/acq_py/{module}"]), module


def test_failed_transcript_is_blocked_in_matrix():
    red = make_transcript(Verdict.FAIL)
    assert cell_state("msb", "linux-x86_64", transcript=red, now=NOW) is MatrixState.BLOCKED


def test_unqualified_cell_is_never_qualified_even_with_green_transcript():
    green = make_transcript(Verdict.PASS)
    assert cell_state("sbx", "macos-x86_64", transcript=green, now=NOW) is MatrixState.UNQUALIFIED


def test_is_claimed_matches_adr_qualified_matrix():
    assert is_claimed("msb", "linux-x86_64")
    assert is_claimed("msb", "linux-aarch64")
    assert is_claimed("msb", "macos-arm64")
    assert is_claimed("msb", "macos-x86_64")
    assert is_claimed("msb", "windows-x64")
    assert not is_claimed("msb", "windows-arm64")
    assert not is_claimed("msb", "linux-musl")
    assert is_claimed("sbx", "linux-x86_64")
    assert is_claimed("sbx", "macos-arm64")
    assert is_claimed("sbx", "windows-x64")
    assert not is_claimed("sbx", "macos-x86_64")
    assert not is_claimed("sbx", "linux-aarch64")


# --- no secret value ----------------------------------------------------------

SECRET = "QUALIFY_TOP_SECRET_MARKER"


def test_transcript_never_records_the_environment(monkeypatch):
    # A secret present only in the process environment never appears anywhere in
    # the transcript document or the RESULT line: the environment is never dumped.
    monkeypatch.setenv("FAKE_TOKEN", SECRET)
    result = run_cell([sys.executable, "-c", "pass"], make_env(), timeout=5.0)
    doc = transcript_document(result)
    serialized = json.dumps(doc)
    assert SECRET not in serialized
    # The recorded "environment" is the whitelisted identity only, never a dump of
    # os.environ: the secret's env var name is not among the recorded keys.
    recorded_env = doc["attempts"][0]["environment"]
    assert "FAKE_TOKEN" not in recorded_env
    assert set(recorded_env) == {
        "os", "os_build", "arch", "hypervisor", "backend", "backend_version",
        "image", "glibc_floor", "rev", "artifact_sha256", "transcript_dir",
    }
    assert doc["attempts"][0]["recorded_at"]
    assert SECRET not in format_result_line("PASS", result.environment)


def test_transcript_digests_output_never_persists_raw_output(monkeypatch):
    # The command prints the secret to stdout (drawn from the environment, so the
    # secret value is not in argv either). The harness keeps only the digest.
    monkeypatch.setenv("FAKE_TOKEN", SECRET)
    command = [
        sys.executable,
        "-c",
        "import os,sys; sys.stdout.buffer.write(os.environ['FAKE_TOKEN'].encode())",
    ]
    result = run_cell(command, make_env(), timeout=5.0)
    doc = transcript_document(result)
    assert result.attempts[0].verdict is Verdict.PASS
    # The digest proves the raw output was captured then reduced, never persisted.
    assert doc["attempts"][0]["output_sha256"] == sha256_hex(SECRET.encode())
    serialized = json.dumps(doc)
    assert SECRET not in serialized  # only the digest, never the raw value
