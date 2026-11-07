"""Tier-2 tests for the Tier-3 ledger and release gate (ADR-0044m).

Offline: the git diff is injected, so no repository state is needed. Each guard is
written so that mutating it (treating a waiver as forever, ignoring a failed
verdict, passing on an unknown revision) fails the suite.
"""

from __future__ import annotations

import copy
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from qualification import gate  # noqa: E402
from qualification.ledger import (  # noqa: E402
    LedgerError,
    append_entry,
    entry_from_transcript,
    latest_entry,
    load_ledger,
    parse_ledger,
    platform_token,
)

NOW = datetime(2026, 11, 7, 12, 0, tzinfo=timezone.utc)
CLAIMED = [
    ("msb", p) for p in ("linux-x86_64", "linux-aarch64", "macos-arm64", "macos-x86_64", "windows-x64")
] + [("sbx", p) for p in ("linux-x86_64", "macos-arm64", "windows-x64")]


def entry(backend, platform, *, verdict="PASS", days_ago=1, version=None, rev="a" * 40):
    return {
        "backend": backend,
        "platform": platform,
        "verdict": verdict,
        "backend_version": version or ("0.7.7" if backend == "msb" else "0.51.0"),
        "os_build": "1",
        "arch": "x",
        "hypervisor": "hvf",
        "rev": rev,
        "artifact_sha256": "b" * 64,
        "recorded_at": (NOW - timedelta(days=days_ago)).isoformat(),
        "transcript_sha256": f"{backend}{platform}{verdict}{days_ago}{rev}".ljust(64, "0")[:64],
    }


def doc(entries=(), waivers=(), versions=None):
    return {
        "schema_version": 1,
        "accepted_backend_versions": versions if versions is not None else {"msb": "0.7.7", "sbx": "0.51.0"},
        "entries": list(entries),
        "waivers": list(waivers),
    }


def waiver(backend, platform, expires="2027-02-05"):
    return {"backend": backend, "platform": platform, "reason": "r", "expires": expires}


def status_of(ledger_doc, paths=(), cell=("msb", "macos-arm64")):
    statuses = gate.evaluate(parse_ledger(ledger_doc), now=NOW, changed_paths=lambda rev: list(paths))
    return {(s.backend, s.platform): s for s in statuses}[cell]


def full_green():
    return doc([entry(b, p) for b, p in CLAIMED])


def test_all_current_cells_pass_the_gate():
    statuses = gate.evaluate(parse_ledger(full_green()), now=NOW, changed_paths=lambda rev: [])
    assert len(statuses) == 8
    assert {s.status for s in statuses} == {"qualified"}


def test_a_release_only_commit_does_not_expire_any_cell():
    release = [".release-please-manifest.json", "CHANGELOG.md", "install.sh", "package.json", "README.md"]
    statuses = gate.evaluate(parse_ledger(full_green()), now=NOW, changed_paths=lambda rev: release)
    assert {s.status for s in statuses} == {"qualified"}


def test_missing_transcript_is_blocked():
    s = status_of(doc())
    assert s.status == "blocked" and "no transcript" in s.reason


def test_surface_change_after_the_run_blocks_the_cell():
    s = status_of(doc([entry("msb", "macos-arm64")]), paths=["py-acq/src/acq_py/cli.py"])
    assert s.status == "blocked" and "Tier-3 surface" in s.reason


def test_latest_entry_wins_even_when_it_failed():
    ledger = doc([entry("msb", "macos-arm64", days_ago=5), entry("msb", "macos-arm64", verdict="FAIL", days_ago=1)])
    s = status_of(ledger)
    assert s.status == "blocked" and "FAIL" in s.reason
    older_fail = doc([entry("msb", "macos-arm64", verdict="FAIL", days_ago=5), entry("msb", "macos-arm64", days_ago=1)])
    assert status_of(older_fail).status == "qualified"


def test_old_and_wrong_minor_transcripts_block():
    assert status_of(doc([entry("msb", "macos-arm64", days_ago=91)])).status == "blocked"
    moved = doc([entry("msb", "macos-arm64")], versions={"msb": "0.8.0", "sbx": "0.51.0"})
    assert status_of(moved).status == "blocked"
    patch = doc([entry("msb", "macos-arm64")], versions={"msb": "0.7.11", "sbx": "0.51.0"})
    assert status_of(patch).status == "qualified"


def test_missing_accepted_version_fails_closed():
    s = status_of(doc([entry("msb", "macos-arm64")], versions={"sbx": "0.51.0"}))
    assert s.status == "blocked" and "accepted_backend_versions" in s.reason


def test_unknown_revision_fails_closed():
    statuses = gate.evaluate(parse_ledger(doc([entry("msb", "macos-arm64")])), now=NOW, changed_paths=lambda rev: None)
    s = {(x.backend, x.platform): x for x in statuses}[("msb", "macos-arm64")]
    assert s.status == "blocked" and "git history" in s.reason


def test_waiver_covers_a_blocked_cell_until_it_expires():
    live = status_of(doc(waivers=[waiver("msb", "macos-arm64", "2026-11-07")]))
    assert live.status == "waived" and "waived until 2026-11-07" in live.reason
    expired = status_of(doc(waivers=[waiver("msb", "macos-arm64", "2026-11-06")]))
    assert expired.status == "blocked" and "waiver expired" in expired.reason


def test_a_current_transcript_is_qualified_not_waived():
    s = status_of(doc([entry("msb", "macos-arm64")], waivers=[waiver("msb", "macos-arm64")]))
    assert s.status == "qualified"


def test_unclaimed_cells_are_not_evaluated():
    cells = {(s.backend, s.platform) for s in gate.evaluate(parse_ledger(doc()), now=NOW, changed_paths=lambda r: [])}
    assert cells == set(CLAIMED)


@pytest.mark.parametrize(
    "bad",
    [
        {"schema_version": 2},
        {"schema_version": 1, "accepted_backend_versions": {"msb": "0.7"}},
        {"schema_version": 1, "accepted_backend_versions": {"zzz": "1.2.3"}},
        {"schema_version": 1, "entries": [{"backend": "msb"}]},
        {"schema_version": 1, "entries": [{**entry("msb", "macos-arm64"), "verdict": "MAYBE"}]},
        {"schema_version": 1, "entries": [{**entry("msb", "macos-arm64"), "recorded_at": "2026-11-06T00:00:00"}]},
        {"schema_version": 1, "entries": [{**entry("msb", "macos-arm64"), "platform": "plan9"}]},
        {"schema_version": 1, "waivers": [{"backend": "sbx", "platform": "macos-x86_64", "reason": "r", "expires": "2027-01-01"}]},
        {"schema_version": 1, "waivers": [{**waiver("msb", "macos-arm64"), "expires": "soon"}]},
        {"schema_version": 1, "waivers": [{"backend": "msb", "platform": "macos-arm64", "expires": "2027-01-01"}]},
    ],
)
def test_malformed_ledger_is_rejected(bad):
    with pytest.raises(LedgerError):
        parse_ledger(bad)


def test_main_exit_codes(tmp_path, capsys):
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps(doc(waivers=[waiver(b, p) for b, p in CLAIMED])))
    # An unknown rev cannot occur here (no entries), so the waivers decide.
    assert gate.main(["--ledger", str(path), "check"]) == 0
    path.write_text(json.dumps(doc()))
    assert gate.main(["--ledger", str(path), "check"]) == 1
    assert "FAILS" in capsys.readouterr().out
    assert gate.main(["--ledger", str(tmp_path / "missing.json"), "check"]) == 2
    path.write_text("{not json")
    assert gate.main(["--ledger", str(path), "check"]) == 2


def transcript(outcome="PASS", **env_over):
    env = {
        "os": "Darwin", "os_build": "26.7.2", "arch": "arm64", "hypervisor": "hvf", "backend": "msb",
        "backend_version": "0.7.7", "image": "i", "glibc_floor": None, "rev": "c" * 40,
        "artifact_sha256": "d" * 64, "transcript_dir": "/x",
    }
    env.update(env_over)
    attempt = {"verdict": outcome, "environment": env, "commands": [], "output_sha256": "", "detail": "",
               "recorded_at": "2026-11-07T07:04:20+00:00"}
    return {"schema_version": 1, "outcome": outcome, "attempts": [attempt]}


def test_record_appends_an_entry_and_is_idempotent_guarded(tmp_path):
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps(doc(waivers=[waiver("msb", "macos-arm64")])))
    raw = json.dumps(transcript()).encode()
    e = entry_from_transcript(json.loads(raw), raw)
    assert (e.backend, e.platform, e.verdict) == ("msb", "macos-arm64", "PASS")
    append_entry(path, e)
    ledger = load_ledger(path)
    assert latest_entry(ledger, "msb", "macos-arm64").transcript_sha256 == e.transcript_sha256
    assert len(ledger.waivers) == 1  # everything else is preserved
    with pytest.raises(LedgerError):
        append_entry(path, e)


def test_record_rejects_unusable_transcripts():
    raw = b"{}"
    with pytest.raises(LedgerError):
        entry_from_transcript({}, raw)
    old = transcript()
    del old["attempts"][0]["recorded_at"]
    with pytest.raises(LedgerError):
        entry_from_transcript(old, json.dumps(old).encode())
    ok = entry_from_transcript(old, json.dumps(old).encode(), recorded_at="2026-11-07T07:00:00+00:00")
    assert ok.recorded_at == "2026-11-07T07:00:00+00:00"
    with pytest.raises(LedgerError):
        platform_token("Plan9", "mips")
    odd = copy.deepcopy(transcript(arch="mips"))
    with pytest.raises(LedgerError):
        entry_from_transcript(odd, json.dumps(odd).encode())


def test_the_committed_ledger_is_valid():
    ledger = load_ledger(REPO_ROOT / gate.DEFAULT_LEDGER)
    assert set(ledger.accepted_backend_versions) == {"msb", "sbx"}
    assert all(w.reason for w in ledger.waivers)


def test_git_changed_paths_against_a_real_repository(tmp_path, monkeypatch):
    import subprocess

    def git(*args):
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                       cwd=tmp_path, check=True, capture_output=True)

    git("init", "-q")
    (tmp_path / "a.txt").write_text("1")
    git("add", "-A")
    git("commit", "-qm", "one")
    first = subprocess.run(["git", "rev-parse", "HEAD"], cwd=tmp_path, capture_output=True, text=True).stdout.strip()
    (tmp_path / "b.txt").write_text("2")
    git("add", "-A")
    git("commit", "-qm", "two")
    monkeypatch.chdir(tmp_path)
    assert gate.git_changed_paths(first) == ["b.txt"]
    assert gate.git_changed_paths("f" * 40) is None  # unknown revision fails closed
    assert gate.git_changed_paths("--output=x") is None  # never an option injection
    assert gate.git_changed_paths("HEAD") is None  # only hex revisions are accepted


def test_git_changed_paths_sees_moves_and_non_ascii_paths(tmp_path, monkeypatch):
    import subprocess

    def git(*args):
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                       cwd=tmp_path, check=True, capture_output=True)

    surface = tmp_path / "py-acq" / "src" / "acq_py"
    surface.mkdir(parents=True)
    (surface / "cli.py").write_text("x = 1\n" * 20)
    git("init", "-q")
    git("add", "-A")
    git("commit", "-qm", "one")
    first = subprocess.run(["git", "rev-parse", "HEAD"], cwd=tmp_path, capture_output=True, text=True).stdout.strip()
    git("mv", "py-acq/src/acq_py/cli.py", "elsewhere.py")  # moved OUT of the surface
    (surface / "é.py").write_text("y = 2\n")
    git("add", "-A")
    git("commit", "-qm", "two")
    monkeypatch.chdir(tmp_path)
    paths = gate.git_changed_paths(first)
    assert "py-acq/src/acq_py/cli.py" in paths  # the old side of a move is listed
    assert "py-acq/src/acq_py/é.py" in paths  # not quoted or octal-escaped
    from qualification.matrix import touches_surface

    # The moved cli.py is a contract-bearing module, so it still counts as surface;
    # é.py is not a real module and is off-surface (whitelist, ADR-0044m).
    assert touches_surface(paths)


def test_equal_timestamps_fail_closed():
    stamp = entry("msb", "macos-arm64")["recorded_at"]
    passed = {**entry("msb", "macos-arm64"), "recorded_at": stamp}
    failed = {**entry("msb", "macos-arm64", verdict="FAIL"), "recorded_at": stamp}
    for order in ([passed, failed], [failed, passed]):
        assert status_of(doc(order)).status == "blocked"


def test_latest_expiring_waiver_wins():
    stale, fresh = waiver("msb", "macos-arm64", "2026-11-01"), waiver("msb", "macos-arm64", "2027-01-01")
    assert status_of(doc(waivers=[stale, fresh])).status == "waived"
    assert status_of(doc(waivers=[fresh, stale])).status == "waived"


@pytest.mark.parametrize(
    "bad", [{"schema_version": 1, "entries": 5}, {"schema_version": 1, "waivers": None}, {"schema_version": 1, "entries": [5]}]
)
def test_non_list_ledger_sections_are_rejected_not_crashed(bad):
    with pytest.raises(LedgerError):
        parse_ledger(bad)


def test_bad_ledger_bytes_exit_2_not_a_traceback(tmp_path):
    path = tmp_path / "ledger.json"
    path.write_bytes(b"\xff\xfe\x00bad")
    assert gate.main(["--ledger", str(path), "check"]) == 2
    path.write_text(json.dumps({"schema_version": 1, "entries": 5}))
    assert gate.main(["--ledger", str(path), "check"]) == 2


def test_record_refuses_the_all_zero_default_rev_and_malformed_transcripts(tmp_path):
    zero = transcript(rev="0" * 40)
    with pytest.raises(LedgerError, match="real commit"):
        entry_from_transcript(zero, json.dumps(zero).encode())
    for bad in ({"attempts": ["x"]}, {"attempts": [{}]}, {"attempts": [{"environment": {"backend": "msb"}}]}):
        with pytest.raises(LedgerError):
            entry_from_transcript(bad, json.dumps(bad).encode(), recorded_at="2026-11-07T07:00:00+00:00")
    path = tmp_path / "t.json"
    path.write_text(json.dumps({"attempts": ["x"]}))
    ledger = tmp_path / "ledger.json"
    ledger.write_text(json.dumps(doc()))
    assert gate.main(["--ledger", str(ledger), "record", str(path)]) == 2


def test_main_record_end_to_end(tmp_path, capsys):
    ledger = tmp_path / "ledger.json"
    ledger.write_text(json.dumps(doc()))
    path = tmp_path / "t.json"
    path.write_text(json.dumps(transcript()))
    assert gate.main(["--ledger", str(ledger), "record", str(path)]) == 0
    assert "recorded PASS msb/macos-arm64" in capsys.readouterr().out
    assert gate.main(["--ledger", str(ledger), "record", str(path)]) == 2  # already recorded


@pytest.mark.parametrize(
    "os_name,arch,token",
    [("Darwin", "arm64", "macos-arm64"), ("Darwin", "x86_64", "macos-x86_64"), ("Linux", "x86_64", "linux-x86_64"),
     ("Linux", "aarch64", "linux-aarch64"), ("Linux", "arm64", "linux-aarch64"), ("Windows", "AMD64", "windows-x64"),
     ("Windows", "x86_64", "windows-x64")],
)
def test_platform_tokens(os_name, arch, token):
    assert platform_token(os_name, arch) == token


def test_every_harness_module_is_classified_as_surface_or_read_only():
    # A new run-path module must be added to TIER3_SURFACE, or explicitly listed here
    # as read-only; otherwise editing it would silently not expire any evidence.
    from qualification.matrix import TIER3_SURFACE

    read_only = {"qualification/matrix.py", "qualification/ledger.py", "qualification/gate.py", "qualification/host.py", "qualification/publish.py"}
    for path in sorted((REPO_ROOT / "qualification").glob("*.py")):
        rel = f"qualification/{path.name}"
        assert rel in TIER3_SURFACE or rel in read_only, f"{rel} is not classified"
    assert not read_only & set(TIER3_SURFACE)


def test_every_acq_py_module_is_classified_as_surface_or_off_surface():
    # A new acq_py module must be added to TIER3_SURFACE (contract-bearing) or
    # explicitly listed here as off-surface (no live oracle asserts it); otherwise
    # editing it would silently not expire any evidence (ADR-0044m narrowed surface).
    from qualification.matrix import TIER3_SURFACE

    off_surface = {
        "py-acq/src/acq_py/__init__.py",      # package version constant (release-only)
        "py-acq/src/acq_py/version_info.py",  # `version` data + output (no oracle asserts it)
        "py-acq/src/acq_py/doctor.py",        # `acq doctor` (no oracle asserts it)
        "py-acq/src/acq_py/runtime.py",       # managed-runtime resolution (only via doctor)
        "py-acq/src/acq_py/_stub_msb.py",     # deterministic test backend, not the live CLI
        "py-acq/src/acq_py/_stub_sbx.py",     # deterministic test backend, not the live CLI
    }
    for path in sorted((REPO_ROOT / "py-acq" / "src" / "acq_py").glob("*.py")):
        rel = f"py-acq/src/acq_py/{path.name}"
        assert rel in TIER3_SURFACE or rel in off_surface, f"{rel} is not classified"
    assert not off_surface & set(TIER3_SURFACE)


def test_rendered_summary_cannot_be_broken_by_a_waiver_reason():
    s = gate.CellStatus("msb", "macos-arm64", "waived", "a | b\nc")
    row = gate.render([s]).splitlines()[2]
    assert row.count("|") == 5 and "\n" not in row
