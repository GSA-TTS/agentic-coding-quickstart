"""Tier-2 tests for ``python -m qualification.host`` (ADR-0044m).

Offline: host facts, backend CLIs and the harness run are injected or stubbed; the
git behaviour is exercised against throwaway repositories.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from qualification import host, publish as pub  # noqa: E402
from qualification.ledger import entry_from_transcript, latest_entry, load_ledger  # noqa: E402

CELLS = [("msb", "macos-arm64"), ("sbx", "macos-arm64")]
# A stand-in for the committed cell oracle in the throwaway repositories: entries
# bind to the oracle as committed at their revision, so every test repo carries one.
ORACLE = "scripts/qualify-backend-cell"
ORACLE_BYTES = b"#!/usr/bin/env python3\nraise SystemExit(0)\n"
ORACLE_SHA = hashlib.sha256(ORACLE_BYTES).hexdigest()


def run(cwd, *args):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                          cwd=cwd, check=True, capture_output=True, text=True).stdout


def make_remote_repo(tmp_path, *, push=True):
    origin = tmp_path / "origin.git"
    run(tmp_path, "init", "-q", "--bare", "-b", "main", str(origin))
    work = tmp_path / "work"
    run(tmp_path, "clone", "-q", str(origin), str(work))
    (work / "docs").mkdir()
    (work / "docs" / "qualification-ledger.json").write_text("{}")
    (work / ".gitignore").write_text("tmp/\n")  # as in the real repo: run evidence lives in tmp/
    (work / "scripts").mkdir()
    (work / ORACLE).write_bytes(ORACLE_BYTES)
    run(work, "add", "-A")
    run(work, "commit", "-qm", "one")
    run(work, "branch", "-M", "main")
    if push:
        run(work, "push", "-q", "origin", "main")
    return work


# ---- host detection ---------------------------------------------------------

@pytest.mark.parametrize(
    "system,machine,token,hv",
    [("Darwin", "arm64", "macos-arm64", "hvf"), ("Darwin", "x86_64", "macos-x86_64", "hvf"),
     ("Windows", "AMD64", "windows-x64", "wsl2"), ("Linux", "x86_64", "linux-x86_64", "kvm"),
     ("Linux", "aarch64", "linux-aarch64", "kvm")],
)
def test_detect_host(system, machine, token, hv):
    h = host.detect_host(system=system, machine=machine, build="b", kvm_usable=True, translated=False)
    assert (h.platform, h.hypervisor) == (token, hv)
    assert h.arch in ("arm64", "x86_64", "aarch64")


def test_detect_host_fails_closed():
    with pytest.raises(pub.HostError, match="kvm"):
        host.detect_host(system="Linux", machine="x86_64", build="b", kvm_usable=False)
    with pytest.raises(pub.HostError, match="Rosetta"):
        host.detect_host(system="Darwin", machine="x86_64", build="b", translated=True)
    with pytest.raises(pub.HostError, match="unsupported OS"):
        host.detect_host(system="Plan9", machine="x86_64", build="b")
    with pytest.raises(pub.HostError):
        host.detect_host(system="Windows", machine="ARM64", build="b")  # not a claimed platform


def test_backend_version_parsing():
    class P:
        def __init__(self, rc, out): self.returncode, self.stdout, self.stderr = rc, out, ""

    assert host.backend_version("msb", which=lambda n: "/x/msb", run=lambda *a, **k: P(0, "msb 0.7.7")) == "0.7.7"
    assert host.backend_version("sbx", which=lambda n: "/x/sbx", run=lambda *a, **k: P(0, "sbx version v0.51.0 (abc)")) == "0.51.0"
    assert host.backend_version("msb", which=lambda n: None) is None
    assert host.backend_version("msb", which=lambda n: "/x", run=lambda *a, **k: P(1, "msb 0.7.7")) is None
    assert host.backend_version("msb", which=lambda n: "/x", run=lambda *a, **k: P(0, "dev build")) is None

    def boom(*a, **k): raise OSError("nope")
    assert host.backend_version("msb", which=lambda n: "/x", run=boom) is None


# ---- git preconditions ------------------------------------------------------

def test_check_checkout_requires_clean_tree_on_main(tmp_path):
    work = make_remote_repo(tmp_path)
    head = pub.check_checkout(work, "origin")
    assert head == run(work, "rev-parse", "HEAD").strip()

    (work / "stray.txt").write_text("x")
    with pytest.raises(pub.HostError, match="uncommitted or untracked"):
        pub.check_checkout(work, "origin")
    (work / "stray.txt").unlink()

    run(work, "switch", "-q", "-c", "side")
    (work / "f.txt").write_text("1")
    run(work, "add", "-A"); run(work, "commit", "-qm", "unpushed")
    with pytest.raises(pub.HostError, match="not on origin/main"):
        pub.check_checkout(work, "origin")


def test_check_checkout_rejects_a_commit_that_was_never_pushed(tmp_path):
    work = make_remote_repo(tmp_path, push=False)
    with pytest.raises(pub.HostError):
        pub.check_checkout(work, "origin")


def test_artifact_sha256_is_stable_and_tracks_content(tmp_path):
    work = make_remote_repo(tmp_path)
    first = pub.artifact_sha256(work)
    assert first == pub.artifact_sha256(work) and len(first) == 64
    (work / "new.txt").write_text("x"); run(work, "add", "-A"); run(work, "commit", "-qm", "two")
    assert pub.artifact_sha256(work) != first


@pytest.mark.parametrize(
    "remotes,explicit,expected",
    [
        ({"origin": "https://github.com/GSA-TTS/agentic-coding-quickstart.git", "mogul": "https://github.com/mogul/agentic-coding-quickstart"}, None, ("mogul", "mogul/agentic-coding-quickstart")),
        ({"fork": "git@github.com:me/agentic-coding-quickstart.git"}, None, ("fork", "me/agentic-coding-quickstart")),
        ({"a": "https://github.com/x/r.git", "b": "https://github.com/y/r.git"}, "b", ("b", "y/r")),
    ],
)
def test_choose_remote_never_the_upstream(tmp_path, remotes, explicit, expected):
    run(tmp_path, "init", "-q")
    for name, url in remotes.items():
        run(tmp_path, "remote", "add", name, url)
    assert pub.choose_remote(tmp_path, explicit) == expected


def test_choose_remote_refuses_upstream_and_ambiguity(tmp_path):
    run(tmp_path, "init", "-q")
    run(tmp_path, "remote", "add", "origin", "https://github.com/GSA-TTS/agentic-coding-quickstart.git")
    with pytest.raises(pub.HostError, match="cannot pick"):
        pub.choose_remote(tmp_path, None)
    with pytest.raises(pub.HostError, match="upstream"):
        pub.choose_remote(tmp_path, "origin")
    with pytest.raises(pub.HostError, match="no git remote"):
        pub.choose_remote(tmp_path, "nope")
    run(tmp_path, "remote", "add", "sneaky", "https://github.com/me/r")
    run(tmp_path, "remote", "set-url", "--push", "sneaky", "https://github.com/GSA-TTS/agentic-coding-quickstart.git")
    with pytest.raises(pub.HostError, match="upstream"):
        pub.choose_remote(tmp_path, "sneaky")  # a fork-looking fetch URL that pushes to the upstream
    run(tmp_path, "remote", "add", "a", "https://github.com/x/r")
    run(tmp_path, "remote", "add", "b", "https://github.com/y/r")
    with pytest.raises(pub.HostError, match="cannot pick"):
        pub.choose_remote(tmp_path, None)


# ---- running and recording --------------------------------------------------

def macos():
    return host.Host("Darwin", "arm64", "26.7.2", "hvf", "macos-arm64")


def make_ledger(tmp_path):
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps({
        "schema_version": 1,
        "accepted_backend_versions": {"msb": "0.7.7", "sbx": "0.51.0"},
        "entries": [],
        "waivers": [{"backend": b, "platform": p, "reason": "r", "expires": "2027-02-05"} for b, p in CELLS + [("msb", "linux-x86_64")]],
    }))
    return path


def oracle_repo(tmp_path):
    """A throwaway repository with the oracle committed (created once per test); returns it."""
    repo = tmp_path / "oracle-repo"
    if not repo.exists():
        (repo / "scripts").mkdir(parents=True)
        (repo / ORACLE).write_bytes(ORACLE_BYTES)
        run(tmp_path, "init", "-q", str(repo))
        run(repo, "add", "-A")
        run(repo, "commit", "-qm", "oracle")
    return repo


def make_transcript(tmp_path, backend, outcome="PASS", rev=None):
    out = tmp_path / f"t-{backend}"
    out.mkdir()
    rev = rev or run(oracle_repo(tmp_path), "rev-parse", "HEAD").strip()
    env = {"os": "Darwin", "os_build": "26.7.2", "arch": "arm64", "hypervisor": "hvf", "backend": backend,
           "backend_version": "0.7.7" if backend == "msb" else "0.51.0", "image": "i", "glibc_floor": None,
           "rev": rev, "artifact_sha256": "d" * 64, "transcript_dir": str(out)}
    # The argv qualification.host records (harness_command): the interpreter, then the oracle.
    attempt = {"verdict": outcome, "environment": env, "commands": [sys.executable, ORACLE, "--backend", backend],
               "output_sha256": "", "detail": "", "recorded_at": datetime.now(timezone.utc).isoformat()}
    path = out / "transcript.json"
    path.write_text(json.dumps({"schema_version": 1, "outcome": outcome, "attempts": [attempt]}))
    return host.Result(backend, outcome, "", f"RESULT {outcome} {backend}=1", path)


def test_apply_results_records_green_runs_and_retires_only_their_waivers(tmp_path):
    ledger = make_ledger(tmp_path)
    results = [make_transcript(tmp_path, "msb"), make_transcript(tmp_path, "sbx", "FAIL"),
               host.Result("x", "SKIPPED", "missing")]
    recorded = host.apply_results(ledger, results, macos(), record_failures=False, repo=oracle_repo(tmp_path))
    assert [r.backend for r in recorded] == ["msb"]
    parsed = load_ledger(ledger)
    assert latest_entry(parsed, "msb", "macos-arm64").verdict == "PASS"
    assert latest_entry(parsed, "sbx", "macos-arm64") is None  # a FAIL is not recorded by default
    waived = {(w.backend, w.platform) for w in parsed.waivers}
    assert waived == {("sbx", "macos-arm64"), ("msb", "linux-x86_64")}


def test_apply_results_can_record_failures_without_retiring_waivers(tmp_path):
    ledger = make_ledger(tmp_path)
    recorded = host.apply_results(ledger, [make_transcript(tmp_path, "sbx", "FAIL")], macos(), record_failures=True,
                                  repo=oracle_repo(tmp_path))
    assert len(recorded) == 1
    parsed = load_ledger(ledger)
    assert latest_entry(parsed, "sbx", "macos-arm64").verdict == "FAIL"
    assert ("sbx", "macos-arm64") in {(w.backend, w.platform) for w in parsed.waivers}


def test_exit_code_and_pr_text():
    assert host._exit_code([host.Result("msb", "PASS"), host.Result("sbx", "PASS")]) == 0
    assert host._exit_code([host.Result("msb", "PASS"), host.Result("sbx", "SKIPPED")]) == 2
    assert host._exit_code([host.Result("msb", "FAIL"), host.Result("sbx", "SKIPPED")]) == 1
    assert host._exit_code([host.Result("msb", "BLOCKED")]) == 2
    title, body = host.pr_text(macos(), [host.Result("msb", "PASS", "", "RESULT PASS msb=0.7.7")], "a" * 40)
    assert title == "chore(qualification): record macos-arm64 msb live runs" and len(title) < 72
    assert "RESULT PASS msb=0.7.7" in body and "a" * 40 in body


def test_harness_command_has_no_secrets_and_matches_the_cell():
    cmd = host.harness_command(macos(), "msb", "0.7.7", "r" * 40, "s" * 64, Path("out"), 900)
    assert cmd[:4] == [sys.executable, "-m", "qualification", "run"]
    assert cmd[cmd.index("--platform") + 1] == "macos-arm64"
    assert cmd[cmd.index("--hypervisor") + 1] == "hvf"
    assert cmd[-3:] == ["--backend", "msb"][-3:] or cmd[-2:] == ["--backend", "msb"]
    assert "scripts" in cmd[cmd.index("--") + 2]


def test_run_backend_maps_exit_codes_and_reads_the_result_line(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    (out / "transcript.json").write_text("{}")
    script = ("import sys; print('OUTCOME PASS'); print('RESULT PASS msb=1 image=i host=h rev=r dir=d'); sys.exit(%d)")
    for rc, status in [(0, "PASS"), (1, "FAIL"), (2, "BLOCKED"), (3, "FLAKY"), (9, "FAIL")]:
        r = host.run_backend([sys.executable, "-c", script % rc], out, "msb", cwd=tmp_path)
        assert r.status == status and r.result_line.startswith("RESULT PASS")
    assert host.run_backend([sys.executable, "-c", "pass"], tmp_path / "none", "msb", cwd=tmp_path).transcript is None


# ---- publish.py safety --------------------------------------------------------

def test_choose_remote_rejects_a_remote_with_any_upstream_push_url(tmp_path):
    run(tmp_path, "init", "-q")
    run(tmp_path, "remote", "add", "multi", "https://github.com/me/r")
    run(tmp_path, "remote", "set-url", "--add", "--push", "multi", "https://github.com/GSA-TTS/agentic-coding-quickstart.git")
    run(tmp_path, "remote", "set-url", "--add", "--push", "multi", "https://github.com/me/r")
    with pytest.raises(pub.HostError, match="upstream"):
        pub.choose_remote(tmp_path, "multi")
    with pytest.raises(pub.HostError, match="cannot pick"):
        pub.choose_remote(tmp_path, None)


@pytest.mark.parametrize("url", [
    "git@github.com:gsa-tts/Agentic-Coding-Quickstart.git", "ssh://git@github.com/GSA-TTS/agentic-coding-quickstart/",
    "https://user:tok@github.com/GSA-TTS/agentic-coding-quickstart",
])
def test_choose_remote_recognises_every_upstream_url_form(tmp_path, url):
    run(tmp_path, "init", "-q")
    run(tmp_path, "remote", "add", "up", url)
    with pytest.raises(pub.HostError):
        pub.choose_remote(tmp_path, "up")


def test_choose_remote_rejects_a_remote_whose_urls_name_different_repos(tmp_path):
    run(tmp_path, "init", "-q")
    run(tmp_path, "remote", "add", "split", "https://github.com/me/r")
    run(tmp_path, "remote", "set-url", "--push", "split", "https://github.com/other/r")
    with pytest.raises(pub.HostError, match="exactly one"):
        pub.choose_remote(tmp_path, "split")


def test_choose_remote_applies_insteadof_rewrites(tmp_path):
    run(tmp_path, "init", "-q")
    run(tmp_path, "config", "url.https://github.com/GSA-TTS/.insteadOf", "gh:")
    run(tmp_path, "remote", "add", "alias", "gh:agentic-coding-quickstart")
    with pytest.raises(pub.HostError, match="upstream"):
        pub.choose_remote(tmp_path, "alias")


def test_check_checkout_without_remote_matches_main_exactly(tmp_path):
    work = make_remote_repo(tmp_path, push=False)
    run(work, "update-ref", "refs/remotes/origin/feature/main", "HEAD")
    with pytest.raises(pub.HostError):
        pub.check_checkout(work, None)
    run(work, "update-ref", "refs/remotes/origin/main", "HEAD")
    assert pub.check_checkout(work, None)


def test_check_identity_and_reachability(tmp_path, monkeypatch):
    work = make_remote_repo(tmp_path)
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(tmp_path / "none"))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    with pytest.raises(pub.HostError, match="user.name"):
        pub.check_identity(work)
    run(work, "config", "user.name", "t"); run(work, "config", "user.email", "t@example.invalid")
    pub.check_identity(work)
    pub.check_remote_reachable(work, "origin")
    run(work, "remote", "add", "dead", str(tmp_path / "nowhere.git"))
    with pytest.raises(pub.HostError):
        pub.check_remote_reachable(work, "dead")


# ---- planning: any ledger state ------------------------------------------------

def committed_ledger(tmp_path, **kw):
    work = make_remote_repo(tmp_path)
    (work / "docs" / "qualification-ledger.json").write_text(json.dumps(kw["doc"]))
    run(work, "add", "-A"); run(work, "commit", "-qm", "ledger"); run(work, "push", "-q", "origin", "main")
    return work


def ledger_doc(entries=(), waivers=(), versions=None):
    return {"schema_version": 1, "accepted_backend_versions": versions or {"msb": "0.7.7", "sbx": "0.51.0"},
            "entries": list(entries), "waivers": list(waivers)}


def entry_for(work, backend, days_ago=1, verdict="PASS"):
    from datetime import timedelta
    head = run(work, "rev-parse", "HEAD").strip()
    return {"backend": backend, "platform": "macos-arm64", "verdict": verdict,
            "backend_version": "0.7.7" if backend == "msb" else "0.51.0", "os_build": "1", "arch": "arm64",
            "hypervisor": "hvf", "rev": head, "artifact_sha256": "b" * 64,
            "recorded_at": (datetime.now(timezone.utc) - timedelta(days=days_ago)).isoformat(),
            "transcript_sha256": hashlib.sha256((backend + verdict + str(days_ago)).encode()).hexdigest(),
            "oracle": ORACLE, "oracle_sha256": ORACLE_SHA}


VERSIONS = {"msb": "0.7.11", "sbx": "0.51.2"}


@pytest.mark.parametrize("state", ["empty", "waived", "expired-waiver", "stale", "current"])
def test_plan_handles_every_starting_ledger_state(tmp_path, state):
    from datetime import timedelta
    work = make_remote_repo(tmp_path)
    doc = ledger_doc()
    if state == "waived":
        doc["waivers"] = [{"backend": b, "platform": "macos-arm64", "reason": "r", "expires": "2999-01-01"} for b in VERSIONS]
    if state == "expired-waiver":
        doc["waivers"] = [{"backend": b, "platform": "macos-arm64", "reason": "r", "expires": "2000-01-01"} for b in VERSIONS]
    (work / "docs" / "qualification-ledger.json").write_text(json.dumps(doc))
    run(work, "add", "-A"); run(work, "commit", "-qm", "l"); run(work, "push", "-q", "origin", "main")
    if state in ("stale", "current"):
        doc["entries"] = [entry_for(work, b, days_ago=120 if state == "stale" else 1) for b in VERSIONS]
        (work / "docs" / "qualification-ledger.json").write_text(json.dumps(doc))
        run(work, "add", "-A"); run(work, "commit", "-qm", "l2"); run(work, "push", "-q", "origin", "main")
    to_run, skipped, accept, notes = host.plan(work, macos(), ["msb", "sbx"], VERSIONS, only_stale=False, accept_flag=False)
    assert to_run == ["msb", "sbx"] and skipped == [] and accept == {}  # always runs unless --only-stale
    to_run, skipped, _, _ = host.plan(work, macos(), ["msb", "sbx"], VERSIONS, only_stale=True, accept_flag=False)
    if state == "current":
        assert to_run == [] and {r.status for r in skipped} == {"CURRENT"}
    else:
        assert to_run == ["msb", "sbx"]


def test_plan_skips_missing_backends_and_demands_consent_to_move_the_version(tmp_path):
    work = committed_ledger(tmp_path, doc=ledger_doc())
    to_run, skipped, _, _ = host.plan(work, macos(), ["msb", "sbx"], {"msb": "0.7.7", "sbx": None}, False, False)
    assert to_run == ["msb"] and skipped[0].status == "SKIPPED"
    with pytest.raises(pub.HostError, match="--accept-backend-version"):
        host.plan(work, macos(), ["msb"], {"msb": "0.8.0"}, False, False)
    _, _, accept, _ = host.plan(work, macos(), ["msb"], {"msb": "0.8.0"}, False, True)
    assert accept == {"msb": "0.8.0"}
    with pytest.raises(pub.HostError):  # an unparseable accepted version is not silently accepted either
        host.plan(work, macos(), ["msb"], {"msb": "0.7"}, False, False)


def test_apply_results_moves_the_accepted_version(tmp_path):
    ledger = make_ledger(tmp_path)
    host.apply_results(ledger, [make_transcript(tmp_path, "msb")], macos(), False, accept={"msb": "0.7.11"},
                       repo=oracle_repo(tmp_path))
    assert load_ledger(ledger).accepted_backend_versions["msb"] == "0.7.11"


def test_apply_results_works_with_no_waiver_present(tmp_path):
    ledger = make_ledger(tmp_path)
    doc = json.loads(ledger.read_text()); doc["waivers"] = []; ledger.write_text(json.dumps(doc))
    assert len(host.apply_results(ledger, [make_transcript(tmp_path, "msb")], macos(), False,
                                  repo=oracle_repo(tmp_path))) == 1


def test_pr_text_scrubs_local_paths_and_flags_a_version_move():
    r = host.Result("msb", "PASS", "", "RESULT PASS msb=0.7.7 image=i host=h rev=r dir=/Users/someone/tmp/x")
    title, body = host.pr_text(macos(), [r], "a" * 40, {"msb": "0.8.0"})
    assert "/Users/someone" not in body and "dir=<transcript-dir>" in body
    assert "accepted backend version to msb 0.8.0" in body
    assert "accepted backend version" not in host.pr_text(macos(), [r], "a" * 40)[1]


def test_prerelease_backend_versions_are_not_accepted():
    class P:
        returncode, stderr = 0, ""
        def __init__(self, out): self.stdout = out

    for out in ("msb 0.7.8-rc1", "sbx 0.51.0+dev"):
        assert host.backend_version("msb", which=lambda n: "/x", run=lambda *a, **k: P(out)) is None


def test_musl_hosts_are_refused():
    with pytest.raises(pub.HostError, match="musl"):
        host.detect_host(system="Linux", machine="x86_64", build="b", kvm_usable=True, musl=True)


# ---- CLI --------------------------------------------------------------------

def setup_cli(tmp_path, monkeypatch, doc):
    work = make_remote_repo(tmp_path)
    (work / "docs" / "qualification-ledger.json").write_text(json.dumps(doc))
    run(work, "add", "-A"); run(work, "commit", "-qm", "ledger"); run(work, "push", "-q", "origin", "main")
    run(work, "config", "user.name", "t"); run(work, "config", "user.email", "t@example.invalid")
    fork = tmp_path / "fork.git"
    run(tmp_path, "init", "-q", "--bare", str(fork))
    run(work, "remote", "add", "fork", "https://github.com/me/agentic-coding-quickstart")
    run(work, "remote", "set-url", "--push", "fork", str(fork))
    run(work, "fetch", "-q", "origin")
    run(work, "update-ref", "refs/remotes/fork/main", "HEAD")
    head = run(work, "rev-parse", "HEAD").strip()
    monkeypatch.setattr(host, "REPO_ROOT", work)
    monkeypatch.setenv("PYTHONPATH", str(REPO_ROOT))
    monkeypatch.setattr(host, "detect_host", lambda: macos())
    monkeypatch.setattr(pub, "check_remote_reachable", lambda root, remote: None)
    monkeypatch.setattr(pub.shutil, "which", lambda name: None)  # no gh: print the URL
    # The fork here pushes to a local bare repo, which the real remote check rightly
    # rejects (its URLs must all name one GitHub repo; covered by the choose_remote
    # tests). Stub only the explicit-remote path; auto-selection still runs for real.
    real_choose = pub.choose_remote
    monkeypatch.setattr(
        pub, "choose_remote",
        lambda root, explicit: ("fork", "me/agentic-coding-quickstart") if explicit == "fork" else real_choose(root, explicit),
    )
    return work, fork, head


def fake_runner(tmp_path, head, outcomes):
    def fake_run(command, out, backend, cwd=None):
        out.mkdir(parents=True)
        status = outcomes.get(backend, "PASS")
        t = make_transcript(tmp_path, backend, status, rev=head)
        doc = json.loads(t.transcript.read_text())
        # a real run records the installed backend version, which is on its command line
        doc["attempts"][0]["environment"]["backend_version"] = command[command.index("--backend-version") + 1]
        (out / "transcript.json").write_text(json.dumps(doc))
        return host.Result(backend, status, "", f"RESULT {status} {backend}=1 dir={out}", out / "transcript.json")
    return fake_run


def test_dry_run_runs_nothing_and_shows_the_target(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    called = []
    monkeypatch.setattr(host, "run_backend", lambda *a, **k: called.append(a))
    assert host.main(["--dry-run", "--remote", "fork"]) == 0
    out = capsys.readouterr().out
    assert "cell=macos-arm64" in out and "PR into me/agentic-coding-quickstart:main" in out and not called
    run(work, "remote", "add", "other", "https://github.com/y/z")
    assert host.main(["--dry-run"]) == 2
    assert "cannot pick" in capsys.readouterr().err


def test_dirty_tree_and_missing_main_fail_before_anything_runs(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "run_backend", lambda *a, **k: pytest.fail("must not run"))
    (work / "dirty").write_text("x")
    assert host.main(["--remote", "fork"]) == 2 and "uncommitted" in capsys.readouterr().err


def test_publish_end_to_end_works_from_an_unwaived_empty_ledger(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())  # no waivers, no entries
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {}))
    assert host.main(["--remote", "fork"]) == 0
    out = capsys.readouterr().out
    assert "pull/new/chore/ledger-macos-arm64-" in out and "me/agentic-coding-quickstart:main" in out
    branches = run(fork, "branch", "--list").split()
    assert len(branches) == 1
    ledger = json.loads(run(fork, "show", f"{branches[0]}:docs/qualification-ledger.json"))
    assert {(e["backend"], e["platform"]) for e in ledger["entries"]} == set(CELLS)
    assert run(work, "status", "--porcelain").strip() == ""
    assert "ledger-" not in run(work, "worktree", "list") and "chore/ledger" not in run(work, "branch", "--list")


def test_publish_is_idempotent_and_only_stale_skips_current_cells(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {}))
    assert host.main(["--remote", "fork"]) == 0
    # a second run (different second, so a different branch) is allowed and adds fresh entries
    import time; time.sleep(1.1)
    (tmp_path / "t-msb").rename(tmp_path / "t-msb-1"); (tmp_path / "t-sbx").rename(tmp_path / "t-sbx-1")
    assert host.main(["--remote", "fork"]) == 0
    assert len(run(fork, "branch", "--list").split()) == 2
    # --only-stale, against a ledger where both cells are already current, runs nothing
    current = ledger_doc([entry_for(work, "msb"), entry_for(work, "sbx")])
    (work / "docs" / "qualification-ledger.json").write_text(json.dumps(current))
    run(work, "add", "-A"); run(work, "commit", "-qm", "cur"); run(work, "push", "-q", "origin", "main")
    run(work, "update-ref", "refs/remotes/fork/main", "HEAD")
    monkeypatch.setattr(host, "run_backend", lambda *a, **k: pytest.fail("must not run"))
    assert host.main(["--remote", "fork", "--only-stale"]) == 0
    assert "skipped by --only-stale" in capsys.readouterr().out


def test_mixed_result_publishes_only_the_green_cell_and_exits_1(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {"sbx": "FAIL"}))
    assert host.main(["--remote", "fork"]) == 1
    branches = run(fork, "branch", "--list").split()
    ledger = json.loads(run(fork, "show", f"{branches[0]}:docs/qualification-ledger.json"))
    assert {e["backend"] for e in ledger["entries"]} == {"msb"}


def test_record_failures_still_publishes(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {"sbx": "FAIL"}))
    assert host.main(["--remote", "fork", "--record-failures"]) == 1
    ledger = json.loads(run(fork, "show", f"{run(fork, 'branch', '--list').split()[0]}:docs/qualification-ledger.json"))
    assert {(e["backend"], e["verdict"]) for e in ledger["entries"]} == {("msb", "PASS"), ("sbx", "FAIL")}


def test_version_mismatch_stops_before_the_run_unless_accepted(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "backend_version", lambda b: "0.8.0" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", lambda *a, **k: pytest.fail("must not run"))
    assert host.main(["--remote", "fork", "--backend", "msb"]) == 2
    assert "--accept-backend-version" in capsys.readouterr().err
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {}))
    assert host.main(["--remote", "fork", "--backend", "msb", "--accept-backend-version"]) == 0
    ledger = json.loads(run(fork, "show", f"{run(fork, 'branch', '--list').split()[0]}:docs/qualification-ledger.json"))
    assert ledger["accepted_backend_versions"]["msb"] == "0.8.0"


def test_nothing_is_pushed_when_the_recorded_run_would_not_qualify(tmp_path, monkeypatch):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, "e" * 40, {}))  # rev git does not know
    assert host.main(["--remote", "fork"]) == 2
    assert run(fork, "branch", "--list").strip() == ""
    assert "ledger-" not in run(work, "worktree", "list") and "chore/ledger" not in run(work, "branch", "--list")


def test_no_publish_edits_this_checkouts_ledger(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else None)
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {}))
    assert host.main(["--no-publish"]) == 2  # sbx not installed: skipped
    parsed = load_ledger(work / "docs" / "qualification-ledger.json")
    assert latest_entry(parsed, "msb", "macos-arm64").verdict == "PASS"
    assert latest_entry(parsed, "sbx", "macos-arm64") is None
    assert "sbx: SKIPPED" in capsys.readouterr().out


# ---- review fixes: accept only what went green, blast radius, hardening ---------

def pushed_ledger(fork):
    branches = run(fork, "branch", "--list").split()
    assert len(branches) == 1, branches
    return json.loads(run(fork, "show", f"{branches[0]}:docs/qualification-ledger.json"))


def test_accepted_version_moves_only_for_a_backend_that_went_green(tmp_path, monkeypatch):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "backend_version", lambda b: "0.8.0" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {"msb": "FAIL"}))
    assert host.main(["--remote", "fork", "--accept-backend-version"]) == 1
    ledger = pushed_ledger(fork)  # sbx went green, so something is published
    assert ledger["accepted_backend_versions"]["msb"] == "0.7.7"  # msb failed: not moved
    assert {e["backend"] for e in ledger["entries"]} == {"sbx"}


def test_accepted_version_is_not_moved_for_a_backend_skipped_by_only_stale(tmp_path, monkeypatch):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    current = ledger_doc([entry_for_head(head, "msb")])
    (work / "docs" / "qualification-ledger.json").write_text(json.dumps(current))
    run(work, "add", "-A"); run(work, "commit", "-qm", "cur"); run(work, "push", "-q", "origin", "main")
    run(work, "update-ref", "refs/remotes/fork/main", "HEAD")
    head = run(work, "rev-parse", "HEAD").strip()
    monkeypatch.setattr(host, "backend_version", lambda b: "0.8.0" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {}))
    assert host.main(["--remote", "fork", "--accept-backend-version", "--only-stale"]) == 0
    assert pushed_ledger(fork)["accepted_backend_versions"]["msb"] == "0.7.7"  # msb was skipped, so not moved


def entry_for_head(rev, backend):
    e = {"backend": backend, "platform": "macos-arm64", "verdict": "PASS", "backend_version": "0.7.7", "os_build": "1",
         "arch": "arm64", "hypervisor": "hvf", "rev": rev, "artifact_sha256": "b" * 64,
         "recorded_at": datetime.now(timezone.utc).isoformat(), "transcript_sha256": hashlib.sha256((backend + "x").encode()).hexdigest(),
         "oracle": ORACLE, "oracle_sha256": ORACLE_SHA}
    return e


def test_blast_radius_names_the_cells_a_version_move_expires(tmp_path):
    work = make_remote_repo(tmp_path)
    head = run(work, "rev-parse", "HEAD").strip()
    doc = ledger_doc([entry_for_head(head, "msb"), {**entry_for_head(head, "msb"), "platform": "linux-x86_64",
                                                      "arch": "x86_64", "hypervisor": "kvm",
                                                      "transcript_sha256": "f" * 64}])
    (work / "docs" / "qualification-ledger.json").write_text(json.dumps(doc))
    run(work, "add", "-A"); run(work, "commit", "-qm", "l")
    assert host.blast_radius(work, {"msb": "0.8.0"}) == ["msb/linux-x86_64", "msb/macos-arm64"]
    # the host's own cell is excluded: the run being published re-qualifies it
    assert host.blast_radius(work, {"msb": "0.8.0"}, macos()) == ["msb/linux-x86_64"]
    assert host.blast_radius(work, {"msb": "0.7.11"}) == []  # a patch bump expires nothing
    assert host.blast_radius(work, {"sbx": "0.52.0"}) == []
    _title, body = host.pr_text(macos(), [host.Result("msb", "PASS", "", "RESULT PASS msb=1")], "a" * 40,
                                {"msb": "0.8.0"}, ["msb/linux-x86_64"])
    assert "stop being qualified because of this: msb/linux-x86_64" in body


def test_identity_and_reachability_failures_stop_everything(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "run_backend", lambda *a, **k: pytest.fail("must not run"))

    def boom(*a, **k): raise pub.HostError("no identity")
    monkeypatch.setattr(pub, "check_identity", boom)
    assert host.main(["--remote", "fork"]) == 2 and "no identity" in capsys.readouterr().err
    monkeypatch.setattr(pub, "check_identity", lambda root: None)
    monkeypatch.setattr(pub, "check_remote_reachable", boom)
    assert host.main(["--remote", "fork"]) == 2
    assert run(fork, "branch", "--list").strip() == ""


def test_a_failed_publish_tells_you_how_to_record_the_kept_runs(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, "e" * 40, {}))  # rev git does not know
    assert host.main(["--remote", "fork"]) == 2
    err = capsys.readouterr().err
    assert "python -m qualification.gate record" in err and "transcript.json" in err and "does not move accepted_backend_versions" in err


@pytest.mark.parametrize("url", [
    "https://github.com/me/r.git?x=1", "https://github.com/me/r#frag", "https://github.com/GSA-TTS/another-repo",
])
def test_choose_remote_rejects_odd_and_org_urls(tmp_path, url):
    run(tmp_path, "init", "-q")
    run(tmp_path, "remote", "add", "x", url)
    with pytest.raises(pub.HostError):
        pub.choose_remote(tmp_path, "x")


def test_publish_never_follows_tags(tmp_path, monkeypatch):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    run(work, "config", "push.followTags", "true")
    run(work, "tag", "-a", "v9", "-m", "x")
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {}))
    assert host.main(["--remote", "fork"]) == 0
    assert run(fork, "tag", "--list").strip() == ""


def test_a_current_cell_that_also_has_a_waiver_keeps_it_when_skipped(tmp_path, monkeypatch):
    work = make_remote_repo(tmp_path)
    head = run(work, "rev-parse", "HEAD").strip()
    doc = ledger_doc([entry_for_head(head, "msb")], waivers=[
        {"backend": "msb", "platform": "macos-arm64", "reason": "r", "expires": "2999-01-01"}])
    (work / "docs" / "qualification-ledger.json").write_text(json.dumps(doc))
    run(work, "add", "-A"); run(work, "commit", "-qm", "l")
    to_run, skipped, _, _ = host.plan(work, macos(), ["msb"], {"msb": "0.7.7"}, True, False)
    assert to_run == [] and skipped[0].status == "CURRENT"


def test_dry_run_previews_the_plan_even_when_a_real_run_would_refuse(tmp_path, monkeypatch, capsys):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    run(work, "switch", "-q", "-c", "feature")
    (work / "f.txt").write_text("1")
    run(work, "add", "-A"); run(work, "commit", "-qm", "only on a feature branch")
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", lambda *a, **k: pytest.fail("must not run"))
    assert host.main(["--dry-run", "--no-publish"]) == 2
    out = capsys.readouterr().out
    assert "cell=macos-arm64" in out and "msb: 0.7.7" in out  # the plan is still shown
    assert "WOULD REFUSE a real run" in out and "not on a remote main branch" in out
    # the same HEAD is a hard error without --dry-run, and runs nothing
    assert host.main(["--no-publish"]) == 2
    assert "not on a remote main branch" in capsys.readouterr().err


# ---- concurrent recording: two hosts must not conflict or revert each other ----

def test_publish_branches_from_the_remote_tip_and_preserves_the_other_hosts_entries(
    tmp_path, monkeypatch, capsys
):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    # Another host records windows-x64 and its PR merges into main while this host runs.
    other = ledger_doc([{**entry_for_head(head, "msb"), "platform": "windows-x64",
                         "transcript_sha256": "e" * 64}],
                       waivers=[{"backend": "msb", "platform": "linux-x86_64", "reason": "r",
                                 "expires": "2027-02-05"}])
    (work / "docs" / "qualification-ledger.json").write_text(json.dumps(other))
    run(work, "add", "-A"); run(work, "commit", "-qm", "other host's ledger PR")
    run(work, "push", "-q", "origin", "main")
    run(work, "push", "-q", "fork", "main")
    moved = run(work, "rev-parse", "HEAD").strip()
    run(work, "update-ref", "refs/remotes/fork/main", moved)  # as a successful fetch would
    # This host tested the OLDER revision; it must still branch from the new tip.
    run(work, "checkout", "-q", head)

    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {}))
    assert host.main(["--remote", "fork"]) == 0
    out = capsys.readouterr().out
    assert f"branching from fork/main {moved[:12]}" in out

    branch = [b for b in run(fork, "branch", "--list").split() if b.startswith("chore/ledger-")]
    assert len(branch) == 1
    ledger = json.loads(run(fork, "show", f"{branch[0]}:docs/qualification-ledger.json"))
    cells = {(e["backend"], e["platform"]) for e in ledger["entries"]}
    assert ("msb", "windows-x64") in cells          # the other host's entry survived
    assert ("msb", "macos-arm64") in cells          # and this host's was added
    assert ("sbx", "macos-arm64") in cells
    # The branch is a descendant of the moved tip, so the PR merges cleanly.
    run(fork, "merge-base", "--is-ancestor", moved, branch[0])


def test_publish_still_uses_the_tested_rev_for_the_entries(tmp_path, monkeypatch):
    work, fork, head = setup_cli(tmp_path, monkeypatch, ledger_doc())
    (work / "unrelated.txt").write_text("x")
    run(work, "add", "-A"); run(work, "commit", "-qm", "unrelated, non-surface")
    run(work, "push", "-q", "origin", "main"); run(work, "push", "-q", "fork", "main")
    run(work, "update-ref", "refs/remotes/fork/main", run(work, "rev-parse", "HEAD").strip())
    run(work, "checkout", "-q", head)
    monkeypatch.setattr(host, "backend_version", lambda b: "0.7.7" if b == "msb" else "0.51.0")
    monkeypatch.setattr(host, "run_backend", fake_runner(tmp_path, head, {}))
    assert host.main(["--remote", "fork"]) == 0
    branch = [b for b in run(fork, "branch", "--list").split() if b.startswith("chore/ledger-")][0]
    ledger = json.loads(run(fork, "show", f"{branch}:docs/qualification-ledger.json"))
    for e in ledger["entries"]:
        assert e["rev"] == head, "the entry must record the revision that was tested"


# ---- the PR body carries the transcripts (so host copies are disposable) -------

def test_pr_body_inlines_each_transcript_with_its_hash(tmp_path):
    msb_run = make_transcript(tmp_path, "msb")
    sbx_run = make_transcript(tmp_path, "sbx")
    _title, body = host.pr_text(macos(), [msb_run, sbx_run], "a" * 40)

    import hashlib

    for run in (msb_run, sbx_run):
        digest = hashlib.sha256(run.transcript.read_bytes()).hexdigest()
        assert digest in body, f"{run.backend}: the transcript's sha256 is not in the body"
        assert f"transcript.json</code> — {run.backend}" in body
    assert body.count("<details>") == 2 and body.count("</details>") == 2
    # the evidence itself, not just a reference to it
    assert '"outcome": "PASS"' in body and '"output_sha256"' in body


def test_pr_body_scrubs_the_local_path_from_the_transcript_and_the_result_line(tmp_path):
    run = make_transcript(tmp_path, "msb")
    doc = json.loads(run.transcript.read_text())
    doc["attempts"][0]["environment"]["transcript_dir"] = "/Users/someone/private/path"
    run.transcript.write_text(json.dumps(doc))
    run.result_line = "RESULT PASS msb=0.7.7 image=i host=h rev=r dir=/Users/someone/private/path"

    _title, body = host.pr_text(macos(), [run], "a" * 40)
    assert "/Users/someone" not in body
    assert body.count(host.SCRUBBED_DIR) >= 2  # the RESULT line and the transcript field
    # scrubbing must not disturb the file on disk: the ledger's hash is of the real bytes
    assert json.loads(run.transcript.read_text())["attempts"][0]["environment"]["transcript_dir"] \
        == "/Users/someone/private/path"


def test_pr_body_survives_an_unreadable_transcript(tmp_path):
    good = make_transcript(tmp_path, "msb")
    bad = make_transcript(tmp_path, "sbx")
    bad.transcript.write_text("{not json")
    _title, body = host.pr_text(macos(), [good, bad], "a" * 40)
    assert "transcript unreadable" in body       # reported, never silently dropped
    assert body.count("<details>") == 1          # the good one is still inlined


def test_transcript_evidence_carries_no_environment_dump_or_raw_output(tmp_path):
    # The harness digests observed output and never records os.environ; the PR body
    # must not reintroduce either. This guards the "transcripts are not sensitive"
    # claim the inlining rests on.
    run = make_transcript(tmp_path, "msb")
    doc = json.loads(run.transcript.read_text())
    recorded_fields = set(doc["attempts"][0]["environment"])
    assert recorded_fields == {
        "os", "os_build", "arch", "hypervisor", "backend", "backend_version", "image",
        "glibc_floor", "rev", "artifact_sha256", "transcript_dir",
    }
    blocks = "\n".join(host.transcript_evidence([run]))
    assert "output_sha256" in blocks          # the digest, which is all that is kept
    assert "os.environ" not in blocks         # never an environment dump
    assert '"stdout"' not in blocks and '"stderr"' not in blocks  # never raw output


def test_the_inlined_hash_is_of_the_real_file_so_a_reviewer_can_verify_it(tmp_path):
    # The hash in the PR body must be of the transcript's bytes ON DISK — the same
    # value the ledger entry records — not of the scrubbed copy shown beside it.
    # Otherwise `sha256sum transcript.json` would not match and the audit path the
    # inlining exists to provide would be broken.
    import hashlib
    import re

    run = make_transcript(tmp_path, "msb")
    on_disk = hashlib.sha256(run.transcript.read_bytes()).hexdigest()
    entry = entry_from_transcript(json.loads(run.transcript.read_bytes()), run.transcript.read_bytes(),
                                  oracle_digest=lambda rev, path: ORACLE_SHA)
    blocks = "\n".join(host.transcript_evidence([run]))
    shown = re.search(r"sha256 <code>([0-9a-f]{64})</code>", blocks).group(1)
    assert shown == on_disk == entry.transcript_sha256
