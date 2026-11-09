"""Tier-2 tests for the Tier-3 ledger and release gate (ADR-0044m).

Offline: the git diff is injected, so no repository state is needed. Each guard is
written so that mutating it (treating a waiver as forever, ignoring a failed
verdict, passing on an unknown revision) fails the suite.
"""

from __future__ import annotations

import copy
import hashlib
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
ORACLE = "scripts/qualify-backend-cell"
ORACLE_SHA = "e" * 64


def committed_oracle(rev, path):
    """The injected stand-in for ``git cat-file`` at ``rev``: the oracle is committed everywhere."""
    return ORACLE_SHA if path == ORACLE else None


# (arch, hypervisor) a host in each cell reports.
HOSTS = {
    "linux-x86_64": ("x86_64", "kvm"), "linux-aarch64": ("aarch64", "kvm"), "macos-arm64": ("arm64", "hvf"),
    "macos-x86_64": ("x86_64", "hvf"), "windows-x64": ("x86_64", "wsl2"),
}
CLAIMED = [
    ("msb", p) for p in ("linux-x86_64", "linux-aarch64", "macos-arm64", "windows-x64")
] + [("sbx", p) for p in ("linux-x86_64", "macos-arm64", "windows-x64")]


def entry(backend, platform, *, verdict="PASS", days_ago=1, version=None, rev="a" * 40):
    return {
        "backend": backend,
        "platform": platform,
        "verdict": verdict,
        "backend_version": version or ("0.7.7" if backend == "msb" else "0.51.0"),
        "os_build": "1",
        "arch": HOSTS[platform][0],
        "hypervisor": HOSTS[platform][1],
        "rev": rev,
        "artifact_sha256": "b" * 64,
        "recorded_at": (NOW - timedelta(days=days_ago)).isoformat(),
        "transcript_sha256": hashlib.sha256(f"{backend}{platform}{verdict}{days_ago}{rev}".encode()).hexdigest(),
        "oracle": ORACLE,
        "oracle_sha256": ORACLE_SHA,
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


def evaluate(ledger_doc, paths=(), digest=committed_oracle):
    return gate.evaluate(parse_ledger(ledger_doc), now=NOW, changed_paths=lambda rev: list(paths), oracle_digest=digest)


def status_of(ledger_doc, paths=(), cell=("msb", "macos-arm64"), digest=committed_oracle):
    statuses = evaluate(ledger_doc, paths, digest)
    return {(s.backend, s.platform): s for s in statuses}[cell]


def full_green():
    return doc([entry(b, p) for b, p in CLAIMED])


def test_all_current_cells_pass_the_gate():
    statuses = evaluate(full_green())
    assert len(statuses) == 7
    assert {s.status for s in statuses} == {"qualified"}


def test_a_release_only_commit_does_not_expire_any_cell():
    release = [".release-please-manifest.json", "CHANGELOG.md", "install.sh", "package.json", "README.md"]
    statuses = evaluate(full_green(), release)
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
    statuses = gate.evaluate(parse_ledger(doc([entry("msb", "macos-arm64")])), now=NOW, changed_paths=lambda rev: None,
                             oracle_digest=committed_oracle)
    s = {(x.backend, x.platform): x for x in statuses}[("msb", "macos-arm64")]
    assert s.status == "blocked" and "not an ancestor of HEAD" in s.reason


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
        {"schema_version": 1, "entries": [{k: v for k, v in entry("msb", "macos-arm64").items() if k != "oracle_sha256"}]},
        {"schema_version": 1, "entries": [{**entry("msb", "macos-arm64"), "oracle_sha256": "E" * 64}]},
        {"schema_version": 1, "entries": [{**entry("msb", "macos-arm64"), "oracle": ""}]},
        {"schema_version": 1, "entries": [entry("msb", "macos-arm64", rev="abcdef1")]},  # abbreviated rev
        {"schema_version": 1, "entries": [entry("msb", "macos-arm64", rev="A" * 40)]},
        {"schema_version": 1, "entries": [{**entry("msb", "macos-arm64"), "transcript_sha256": "AB" * 32}]},
        {"schema_version": 1, "entries": [{**entry("msb", "macos-arm64"), "transcript_sha256": "ab" * 31}]},
        {"schema_version": 1, "entries": [{**entry("msb", "macos-arm64"), "transcript_sha256": "z" * 64}]},
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


def oracle_argv(backend="msb", python="/usr/bin/python3"):
    """The argv ``qualification.host`` records: the interpreter, then the committed oracle."""
    return [python, ORACLE, "--backend", backend]


def transcript(outcome="PASS", commands=None, **env_over):
    env = {
        "os": "Darwin", "os_build": "26.7.2", "arch": "arm64", "hypervisor": "hvf", "backend": "msb",
        "backend_version": "0.7.7", "image": "i", "glibc_floor": None, "rev": "c" * 40,
        "artifact_sha256": "d" * 64, "transcript_dir": "/x",
    }
    env.update(env_over)
    argv = oracle_argv(env["backend"]) if commands is None else commands
    attempt = {"verdict": outcome, "environment": env, "commands": argv, "output_sha256": "", "detail": "",
               "recorded_at": "2026-11-07T07:04:20+00:00"}
    return {"schema_version": 1, "outcome": outcome, "attempts": [attempt]}


def test_record_appends_an_entry_and_is_idempotent_guarded(tmp_path):
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps(doc(waivers=[waiver("msb", "macos-arm64")])))
    raw = json.dumps(transcript()).encode()
    e = entry_from_transcript(json.loads(raw), raw, oracle_digest=committed_oracle)
    assert (e.backend, e.platform, e.verdict) == ("msb", "macos-arm64", "PASS")
    assert (e.oracle, e.oracle_sha256) == (ORACLE, ORACLE_SHA)
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
        entry_from_transcript(old, json.dumps(old).encode(), oracle_digest=committed_oracle)
    ok = entry_from_transcript(old, json.dumps(old).encode(), recorded_at="2026-11-07T07:00:00+00:00",
                               oracle_digest=committed_oracle)
    assert ok.recorded_at == "2026-11-07T07:00:00+00:00"
    with pytest.raises(LedgerError):
        platform_token("Plan9", "mips")
    odd = copy.deepcopy(transcript(arch="mips"))
    with pytest.raises(LedgerError):
        entry_from_transcript(odd, json.dumps(odd).encode(), oracle_digest=committed_oracle)


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
    (surface / "a.py").write_text("x = 1\n" * 20)
    git("init", "-q")
    git("add", "-A")
    git("commit", "-qm", "one")
    first = subprocess.run(["git", "rev-parse", "HEAD"], cwd=tmp_path, capture_output=True, text=True).stdout.strip()
    git("mv", "py-acq/src/acq_py/a.py", "elsewhere.py")  # moved OUT of the surface
    (surface / "é.py").write_text("y = 2\n")
    git("add", "-A")
    git("commit", "-qm", "two")
    monkeypatch.chdir(tmp_path)
    paths = gate.git_changed_paths(first)
    assert "py-acq/src/acq_py/a.py" in paths  # the old side of a move is listed
    assert "py-acq/src/acq_py/é.py" in paths  # not quoted or octal-escaped
    from qualification.matrix import touches_surface

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


def oracle_repo(tmp_path, content=b"#!/usr/bin/env python3\nraise SystemExit(0)\n"):
    """A throwaway repository with the oracle committed; returns ``(path, head, oracle sha256)``."""
    import hashlib
    import subprocess

    repo = tmp_path / "repo"
    (repo / "scripts").mkdir(parents=True)
    (repo / ORACLE).write_bytes(content)
    for args in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "oracle"]):
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                       cwd=repo, check=True, capture_output=True)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
    return repo, head, hashlib.sha256(content).hexdigest()


def test_main_record_end_to_end(tmp_path, capsys, monkeypatch):
    repo, head, digest = oracle_repo(tmp_path)
    monkeypatch.chdir(repo)  # `record` reads the oracle as committed at the run's rev from this checkout
    ledger = tmp_path / "ledger.json"
    ledger.write_text(json.dumps(doc()))
    path = tmp_path / "t.json"
    path.write_text(json.dumps(transcript(rev=head)))
    assert gate.main(["--ledger", str(ledger), "record", str(path)]) == 0
    assert "recorded PASS msb/macos-arm64" in capsys.readouterr().out
    assert load_ledger(ledger).entries[0].oracle_sha256 == digest
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


def test_off_surface_modules_are_not_loaded_by_cli():
    # A module that is off the surface must be genuinely unreachable from the
    # oracle's commands (ADR-0044m): importing acq_py.cli — the dispatch the live
    # oracle drives — must not load any off-surface module, or a break there would
    # kill create/ls/exec/rm/secret/provider-credential while touches_surface() says
    # False. Run in a fresh interpreter (sys.modules is polluted by sibling tests in
    # this process); the module names are derived from the exclusion list so the two
    # stay in lockstep.
    import subprocess

    from qualification.matrix import TIER3_SURFACE_EXCLUSIONS

    prefix = "py-acq/src/acq_py/"
    off_surface_modules = tuple(
        "acq_py." + path[len(prefix):-len(".py")]
        for path in TIER3_SURFACE_EXCLUSIONS
        if path.startswith(prefix) and path.endswith(".py")
    )
    assert off_surface_modules, "expected at least one off-surface acq_py module"
    code = (
        "import sys; import acq_py.cli; "
        "targets = set(%r); "
        "print(','.join(sorted(m for m in sys.modules if m in targets)))"
        % (off_surface_modules,)
    )
    proc = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    loaded = [m for m in proc.stdout.strip().split(",") if m]
    assert not loaded, f"off-surface modules loaded by importing acq_py.cli: {loaded}"


def test_rendered_summary_cannot_be_broken_by_a_waiver_reason():
    s = gate.CellStatus("msb", "macos-arm64", "waived", "a | b\nc")
    row = gate.render([s]).splitlines()[2]
    assert row.count("|") == 5 and "\n" not in row


# ---- evidence binding: an entry is a run of the committed oracle on its own cell ----


def unbound(e):
    return {k: v for k, v in e.items() if k not in ("oracle", "oracle_sha256")}


@pytest.mark.parametrize(
    "commands",
    [
        [],
        ["true"],  # a no-op exits 0, which the harness classifies PASS
        ["/usr/bin/python3", "-c", "pass"],
        ["/usr/bin/python3", "-c", "pass", ORACLE, "--backend", "msb"],
        oracle_argv("sbx"),  # the sbx oracle run passed off as the msb cell
        ["/usr/bin/python3", "elsewhere/qualify-backend-cell", "--backend", "msb"],
        ["/usr/bin/python3", "/tmp/x/" + ORACLE, "--backend", "msb"],  # not this checkout's oracle
        ["/usr/bin/python3", ORACLE, "--backend", "msb", "--skip-secrets"],
        ["/bin/sh", ORACLE, "--backend", "msb"],
    ],
)
def test_record_refuses_a_transcript_that_did_not_run_the_committed_oracle(commands):
    t = transcript(commands=commands)
    with pytest.raises(LedgerError, match="did not run the committed cell oracle"):
        entry_from_transcript(t, json.dumps(t).encode(), oracle_digest=committed_oracle)


def test_record_refuses_when_any_attempt_did_not_run_the_oracle():
    t = transcript()
    t["attempts"].append({**t["attempts"][0], "commands": ["true"]})
    with pytest.raises(LedgerError, match="did not run the committed cell oracle"):
        entry_from_transcript(t, json.dumps(t).encode(), oracle_digest=committed_oracle)


@pytest.mark.parametrize(
    "commands",
    [
        [ORACLE, "--backend", "msb"],  # run through its shebang
        ["C:\\Python312\\python.exe", "scripts\\qualify-backend-cell", "--backend", "msb"],  # Windows host
        ["/opt/homebrew/bin/python3.12", "./" + ORACLE, "--backend", "msb"],
    ],
)
def test_record_accepts_every_form_the_harness_records_the_oracle_in(commands):
    t = transcript(commands=commands)
    assert entry_from_transcript(t, json.dumps(t).encode(), oracle_digest=committed_oracle).oracle == ORACLE


def test_record_refuses_a_revision_where_the_oracle_is_not_committed():
    t = transcript()
    with pytest.raises(LedgerError, match="not committed at revision"):
        entry_from_transcript(t, json.dumps(t).encode(), oracle_digest=lambda rev, path: None)


@pytest.mark.parametrize("platform", ["linux-x86_64", "linux-aarch64", "macos-x86_64", "windows-x64"])
def test_record_refuses_a_platform_that_is_not_the_transcripts_host(platform):
    # One macOS arm64 run must not be recordable as another cell's evidence.
    t = transcript()
    with pytest.raises(LedgerError, match="not the transcript's host"):
        entry_from_transcript(t, json.dumps(t).encode(), platform=platform, oracle_digest=committed_oracle)


def test_record_accepts_the_matching_platform_and_musl_on_linux():
    t = transcript()
    assert entry_from_transcript(
        t, json.dumps(t).encode(), platform="macos-arm64", oracle_digest=committed_oracle
    ).platform == "macos-arm64"
    linux = transcript(os="Linux", arch="x86_64", hypervisor="kvm")
    assert entry_from_transcript(
        linux, json.dumps(linux).encode(), platform="linux-musl", oracle_digest=committed_oracle
    ).platform == "linux-musl"


def test_record_refuses_a_hypervisor_that_is_not_the_cells():
    t = transcript(hypervisor="unknown")
    with pytest.raises(LedgerError, match="hypervisor"):
        entry_from_transcript(t, json.dumps(t).encode(), oracle_digest=committed_oracle)


@pytest.mark.parametrize(
    "cell,arch,hypervisor",
    [
        (("msb", "linux-x86_64"), "arm64", "hvf"),     # a macOS run filed under Linux
        (("msb", "linux-x86_64"), "x86_64", "wsl2"),   # a Windows run filed under Linux
        (("sbx", "windows-x64"), "x86_64", "kvm"),     # a Linux run filed under Windows
        (("msb", "linux-aarch64"), "x86_64", "kvm"),   # the wrong architecture
    ],
)
def test_an_entry_recorded_on_another_host_qualifies_nothing(cell, arch, hypervisor):
    e = {**entry(*cell), "arch": arch, "hypervisor": hypervisor}
    s = status_of(doc([e]), cell=cell)
    assert s.status == "blocked" and "another host" in s.reason


def test_an_entry_without_an_oracle_binding_is_blocked():
    s = status_of(doc([unbound(entry("msb", "macos-arm64"))]))
    assert s.status == "blocked" and "no oracle binding" in s.reason


def test_an_entry_naming_another_oracle_is_blocked():
    s = status_of(doc([{**entry("msb", "macos-arm64"), "oracle": "scripts/noop"}]))
    assert s.status == "blocked" and "not the committed cell oracle" in s.reason


def test_an_oracle_hash_that_does_not_match_the_committed_oracle_is_blocked():
    s = status_of(doc([{**entry("msb", "macos-arm64"), "oracle_sha256": "f" * 64}]))
    assert s.status == "blocked" and "does not match" in s.reason
    missing = status_of(doc([entry("msb", "macos-arm64")]), digest=lambda rev, path: None)
    assert missing.status == "blocked" and "not committed at revision" in missing.reason


def legacy_entry(index=0):
    """A committed legacy entry, exactly as listed (no oracle binding)."""
    from qualification.ledger import LEGACY_FIELDS, LEGACY_UNBOUND_ENTRIES

    digest, values = list(LEGACY_UNBOUND_ENTRIES.items())[index]
    return {**dict(zip(LEGACY_FIELDS, values)), "transcript_sha256": digest}


def test_a_listed_legacy_entry_passes_without_a_binding():
    e = legacy_entry()  # msb macos-arm64, recorded 2026-11-07T07:04:20Z, before NOW
    assert (e["backend"], e["platform"]) == ("msb", "macos-arm64")
    assert status_of(doc([e])).status == "qualified"
    # ...but only as an exemption from the binding: the other rules still apply.
    assert status_of(doc([e]), paths=["py-acq/src/acq_py/cli.py"]).status == "blocked"


@pytest.mark.parametrize(
    "cell,changes",
    [
        # A listed hash copied onto another cell whose host the entry self-reports,
        # at a fresh revision and date: the attack the exemption must not allow.
        (("msb", "linux-x86_64"), {"platform": "linux-x86_64", "arch": "x86_64", "hypervisor": "kvm",
                                   "rev": "a" * 40, "recorded_at": (NOW - timedelta(days=1)).isoformat()}),
        (("sbx", "macos-arm64"), {"backend": "sbx", "backend_version": "0.51.0"}),  # the other backend, same host
        (("msb", "macos-arm64"), {"recorded_at": (NOW - timedelta(minutes=5)).isoformat()}),  # a fresh date only
        (("msb", "macos-arm64"), {"rev": "a" * 40}),  # another revision only
        (("msb", "macos-arm64"), {"backend_version": "0.7.11"}),  # another version only
    ],
)
def test_a_legacy_hash_on_any_other_identity_earns_no_exemption(cell, changes):
    s = status_of(doc([{**legacy_entry(), **changes}]), cell=cell)
    assert s.status == "blocked" and "no oracle binding" in s.reason


def test_the_legacy_exemption_ends_at_the_cutoff_whatever_the_entry_says():
    from qualification.ledger import LEGACY_UNBOUND_UNTIL, binding_problem

    e = parse_ledger(doc([legacy_entry()])).entries[0]
    assert binding_problem(e, committed_oracle, LEGACY_UNBOUND_UNTIL - timedelta(seconds=1)) is None
    assert "no oracle binding" in binding_problem(e, committed_oracle, LEGACY_UNBOUND_UNTIL)
    assert "no oracle binding" in binding_problem(e, committed_oracle)  # no clock, no exemption
    assert LEGACY_UNBOUND_UNTIL == datetime(2027, 2, 6, tzinfo=timezone.utc)


def test_one_transcript_cannot_be_filed_under_two_cells():
    # msb and sbx on one host share arch, hypervisor and oracle hash; only the
    # transcript hash tells their runs apart.
    msb = entry("msb", "macos-arm64")
    sbx = {**entry("sbx", "macos-arm64"), "transcript_sha256": msb["transcript_sha256"]}
    with pytest.raises(LedgerError, match="already recorded"):
        parse_ledger(doc([msb, sbx]))
    relabelled = {**msb, "platform": "linux-x86_64", "arch": "x86_64", "hypervisor": "kvm"}
    with pytest.raises(LedgerError, match="already recorded"):
        parse_ledger(doc([msb, relabelled]))
    legacy = legacy_entry()
    with pytest.raises(LedgerError, match="already recorded"):
        parse_ledger(doc([legacy, {**legacy, "backend": "sbx", "backend_version": "0.51.0"}]))


def test_a_case_variant_of_a_recorded_hash_is_not_a_second_transcript(tmp_path):
    # Hex compares case-insensitively in an audit, so "AB..." is the same transcript as
    # "ab..."; it must not slip past the duplicate check as a different string.
    msb = {**entry("msb", "linux-x86_64"), "transcript_sha256": "ab" * 32}
    sbx = {**entry("sbx", "linux-x86_64"), "transcript_sha256": "AB" * 32}
    with pytest.raises(LedgerError, match="lowercase hex"):
        parse_ledger(doc([msb, sbx]))
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps(doc([msb, sbx], [waiver(b, p) for b, p in CLAIMED])))
    assert gate.main(["--ledger", str(path), "check"]) == 2


def test_a_duplicated_transcript_makes_the_gate_exit_2(tmp_path):
    msb = entry("msb", "macos-arm64")
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps(doc([msb, {**entry("sbx", "macos-arm64"), "transcript_sha256": msb["transcript_sha256"]}])))
    assert gate.main(["--ledger", str(path), "check"]) == 2


def test_record_refuses_an_abbreviated_revision():
    t = transcript(rev="c" * 12)
    with pytest.raises(LedgerError, match="real commit"):
        entry_from_transcript(t, json.dumps(t).encode(), oracle_digest=committed_oracle)


def test_git_changed_paths_refuses_a_revision_off_the_evaluated_history(tmp_path, monkeypatch):
    _git(tmp_path, "init", "-q", "-b", "main")
    (tmp_path / "a.txt").write_text("1")
    _git(tmp_path, "add", "-A")
    _git(tmp_path, "commit", "-qm", "one")
    first = _git(tmp_path, "rev-parse", "HEAD")
    _git(tmp_path, "switch", "-q", "-c", "side")
    (tmp_path / "b.txt").write_text("2")
    _git(tmp_path, "add", "-A")
    _git(tmp_path, "commit", "-qm", "only on a side branch")
    side = _git(tmp_path, "rev-parse", "HEAD")
    _git(tmp_path, "switch", "-q", "main")
    monkeypatch.chdir(tmp_path)
    assert gate.git_changed_paths(first) == []
    assert gate.git_changed_paths(side) is None  # exists, but is not an ancestor of HEAD
    assert gate.git_changed_paths(first[:12]) is None  # never an abbreviation


def test_every_committed_entry_is_bound_or_grandfathered_and_on_its_own_host():
    # The binding must not silently invalidate genuine evidence already in the ledger:
    # each unbound committed entry must be field-for-field its legacy listing.
    from qualification.ledger import binding_problem

    before_cutoff = datetime(2026, 11, 9, tzinfo=timezone.utc)
    ledger = load_ledger(REPO_ROOT / gate.DEFAULT_LEDGER)
    for e in ledger.entries:
        assert binding_problem(e, lambda rev, path, e=e: e.oracle_sha256, before_cutoff) is None, e


def test_the_gate_reads_the_oracle_as_committed_at_the_entrys_revision(tmp_path):
    from qualification.ledger import git_oracle_digest

    repo, head, digest = oracle_repo(tmp_path)
    assert git_oracle_digest(head, ORACLE, cwd=repo) == digest
    assert git_oracle_digest("f" * 40, ORACLE, cwd=repo) is None    # unknown revision
    assert git_oracle_digest(head, "missing", cwd=repo) is None      # not committed there
    assert git_oracle_digest("HEAD", ORACLE, cwd=repo) is None       # only hex revisions
    assert git_oracle_digest(head, "--output=x", cwd=repo) is None   # never an option


# ---- the rules come from the base branch, not the change under test ------------

WORKFLOW = REPO_ROOT / ".github" / "workflows" / "tier3-release-gate.yml"


def test_the_pr_gate_runs_the_base_branchs_rules():
    # The workflow is the trust anchor (CODEOWNERS: admins): on a pull request it must
    # import qualification/ from a worktree of the base commit, with -P so the PR's
    # checkout (the working directory) is not on sys.path.
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "BASE_SHA: ${{ github.event.pull_request.base.sha }}" in text
    assert 'git worktree add --detach "$RUNNER_TEMP/gate-rules" "$BASE_SHA"' in text
    assert 'rules="$RUNNER_TEMP/gate-rules"' in text
    assert 'PYTHONPATH="$rules" python -P -m qualification.gate check' in text
    assert "python -m qualification.gate" not in text  # no path that imports the PR's copy


def test_codeowners_protects_the_gate_rules_and_the_oracles():
    owners = (REPO_ROOT / ".github" / "CODEOWNERS").read_text(encoding="utf-8")
    for path in ("/qualification/", "/scripts/qualify-backend-cell", "/scripts/qualify-msb-ro-mount",
                 "/docs/qualification-ledger.json", "/.github/workflows/", "/.github/CODEOWNERS"):
        assert f"\n{path} @GSA-TTS/agentic-coding-admins" in owners, path


def _git(cwd, *args):
    import subprocess

    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                          cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def _run_gate(cwd, rules):
    """The workflow's invocation: ``PYTHONPATH=<rules> python -P -m qualification.gate check``."""
    import os
    import subprocess

    env = {**os.environ, "PYTHONPATH": str(rules)}
    proc = subprocess.run([sys.executable, "-P", "-m", "qualification.gate", "check", "--json"],
                          cwd=cwd, env=env, capture_output=True, text=True)
    assert proc.stdout, proc.stderr
    return proc.returncode, {(c["backend"], c["platform"]): c for c in json.loads(proc.stdout)}


def test_a_pr_cannot_carve_its_own_change_out_of_the_surface_or_rewrite_the_gate(tmp_path):
    # End to end in a throwaway repository: the base commit holds this package and a
    # ledger with a bound, current entry. The "PR" changes the CLI (a Tier-3 surface
    # change, which must expire the entry) and, in the same commit, excludes the CLI
    # from the surface and rewrites the gate to report every cell qualified. Judged by
    # its own copy of qualification/ it passes; judged by the base's, as CI now does,
    # the cell is blocked.
    import hashlib
    import shutil

    repo = tmp_path / "repo"
    (repo / "scripts").mkdir(parents=True)
    shutil.copytree(REPO_ROOT / "qualification", repo / "qualification",
                    ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy(REPO_ROOT / ORACLE, repo / ORACLE)
    cli = repo / "py-acq" / "src" / "acq_py" / "cli.py"
    cli.parent.mkdir(parents=True)
    cli.write_text("def main():\n    return 0\n")
    _git(repo, "init", "-q")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "base")
    tested = _git(repo, "rev-parse", "HEAD")

    now = datetime.now(timezone.utc)
    e = {**entry("msb", "macos-arm64", rev=tested), "recorded_at": (now - timedelta(days=1)).isoformat(),
         "oracle_sha256": hashlib.sha256((repo / ORACLE).read_bytes()).hexdigest()}
    others = [waiver(b, p, (now + timedelta(days=30)).date().isoformat())
              for b, p in CLAIMED if (b, p) != ("msb", "macos-arm64")]
    (repo / "docs").mkdir()
    (repo / "docs" / "qualification-ledger.json").write_text(json.dumps(doc([e], others)))
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "ledger")
    base = _git(repo, "rev-parse", "HEAD")

    rc, cells = _run_gate(repo, repo)
    assert rc == 0 and cells[("msb", "macos-arm64")]["status"] == "qualified"  # the honest baseline

    cli.write_text("def main():\n    return 1  # broken\n")
    matrix = repo / "qualification" / "matrix.py"
    marker = "TIER3_SURFACE_EXCLUSIONS = ("
    assert marker in matrix.read_text()
    matrix.write_text(matrix.read_text().replace(marker, marker + '\n    "py-acq/src/acq_py/cli.py",', 1))
    gate_py = repo / "qualification" / "gate.py"
    gate_py.write_text(gate_py.read_text() + (
        "\n_real_evaluate = evaluate\n"
        "def evaluate(ledger, **kw):\n"
        "    return [CellStatus(s.backend, s.platform, 'qualified') for s in _real_evaluate(ledger, **kw)]\n"
    ))
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "the PR under test")

    rc, cells = _run_gate(repo, repo)  # the PR's own rules: the bypass this closes
    assert rc == 0 and cells[("msb", "macos-arm64")]["status"] == "qualified"

    rules = tmp_path / "gate-rules"
    _git(repo, "worktree", "add", "--detach", str(rules), base)
    rc, cells = _run_gate(repo, rules)  # the base branch's rules, as CI runs them
    cell = cells[("msb", "macos-arm64")]
    assert rc == 1 and cell["status"] == "blocked" and "Tier-3 surface" in cell["reason"]
