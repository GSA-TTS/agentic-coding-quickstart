"""Qualify THIS host in one command, on any OS (ADR-0044m).

    python -m qualification.host                 # run, record, open a ledger PR
    python -m qualification.host --dry-run       # show the plan and any refusal; run nothing
    python -m qualification.host --only-stale    # skip cells that are already current
    python -m qualification.host --no-publish    # record in this checkout only

It detects the host (OS, build, architecture, hypervisor), runs the committed cell
oracle (``scripts/qualify-backend-cell``) through the harness for every backend
claimed on this platform, and records the green runs in the committed ledger
(``docs/qualification-ledger.json``), retiring that cell's waiver if it has one.
Unless ``--no-publish`` is given it then commits the ledger change in a throwaway
worktree, pushes a new ``chore/ledger-*`` branch to a fork remote, and opens a PR.
See :mod:`qualification.publish` for the safety rules (fork only, one new branch,
your checkout is never touched).

It works from any ledger state: a cell with no entry, a stale entry, an expired or
missing waiver, or an already-current entry all just get a new entry (re-running is
safe; ``--only-stale`` skips cells that are already current). It refuses to run
unless the tree is clean and HEAD is on the fork's ``main``, because the entry binds
to HEAD and the gate can only find a commit that is on ``main``.

If the installed backend's ``major.minor`` is not the one the ledger accepts, it
stops before the (long) run and names ``--accept-backend-version``, which moves the
accepted version in the same PR; that expires every cell recorded at the old minor,
so it is never automatic.

Only green runs are recorded by default. A missing backend CLI is not evidence (the
cell is reported SKIPPED); a real FAIL/FLAKY is recorded only with
``--record-failures`` (the latest entry decides a cell, so a mistaken failure would
shadow a good run).

This module launches runs and edits the ledger; it is not what the runs exercise,
so it is deliberately not part of the Tier-3 surface.

Python >= 3.12, standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from . import publish as pub
from dataclasses import replace

from .gate import evaluate, git_changed_paths
from .ledger import DEFAULT_LEDGER, LedgerError, append_entry, entry_from_transcript, load_ledger, platform_token, set_accepted_version
from .matrix import MSB, SBX, is_claimed, same_minor
from .publish import HostError

REPO_ROOT = Path(__file__).resolve().parent.parent
# The image the cell oracle creates sandboxes from (scripts/qualify-backend-cell).
IMAGE = "docker.io/docker/sandbox-templates:shell-docker"
_VERSION = re.compile(r"\d+\.\d+\.\d+")
_VERSION_ARGV = {MSB: ["--version"], SBX: ["version"]}
_STATUS = {0: "PASS", 1: "FAIL", 2: "BLOCKED", 3: "FLAKY"}
_OK = ("PASS", "CURRENT")


@dataclass(frozen=True)
class Host:
    system: str
    arch: str
    os_build: str
    hypervisor: str
    platform: str


@dataclass
class Result:
    backend: str
    status: str  # PASS | FAIL | BLOCKED | FLAKY | SKIPPED | CURRENT
    detail: str = ""
    result_line: str = ""
    transcript: Path | None = None


def normalize_arch(machine: str) -> str:
    """The harness's raw arch value (Windows reports AMD64; the ADR uses x86_64)."""
    return {"amd64": "x86_64", "x64": "x86_64"}.get(machine.lower(), machine)


def _translated_x86_on_arm_mac() -> bool:
    if sys.platform != "darwin":
        return False
    proc = subprocess.run(["sysctl", "-n", "sysctl.proc_translated"], capture_output=True, text=True)
    return proc.returncode == 0 and proc.stdout.strip() == "1"


def _os_build(system: str) -> str:
    if system == "Darwin":
        version = platform.mac_ver()[0]
        if version.startswith("10.16"):  # a Python built against an old SDK lies on macOS 11+
            proc = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True)
            version = proc.stdout.strip() or version
        return version
    return platform.version() if system == "Windows" else platform.release()


def _is_musl() -> bool:
    return any(Path("/lib").glob("ld-musl-*"))


def detect_host(
    *, system: str | None = None, machine: str | None = None, build: str | None = None,
    kvm_usable: bool | None = None, translated: bool | None = None, musl: bool | None = None,
) -> Host:
    """Identify this host, failing closed on anything that would mislabel the cell."""
    system = system or platform.system()
    arch = normalize_arch(machine or platform.machine())
    if system == "Darwin" and arch == "x86_64" and (
        _translated_x86_on_arm_mac() if translated is None else translated
    ):
        raise HostError("this Python runs under Rosetta; use a native arm64 Python so the cell is labelled correctly")
    if system == "Darwin":
        hypervisor = "hvf"
    elif system == "Windows":
        hypervisor = "wsl2"
    elif system == "Linux":
        if _is_musl() if musl is None else musl:
            raise HostError("this host uses musl libc (linux-musl), which is not a claimed platform")
        usable = os.access("/dev/kvm", os.R_OK | os.W_OK) if kvm_usable is None else kvm_usable
        if not usable:
            raise HostError("/dev/kvm is missing or not accessible; msb and sbx need KVM on Linux")
        hypervisor = "kvm"
    else:
        raise HostError(f"unsupported OS {system!r}")
    try:
        token = platform_token(system, arch)
    except LedgerError as exc:
        raise HostError(str(exc)) from None
    return Host(system, arch, build or _os_build(system), hypervisor, token)


def backend_version(backend: str, *, which=shutil.which, run=subprocess.run) -> str | None:
    """The backend CLI's final ``X.Y.Z`` version, or ``None`` when absent, unrunnable or not final."""
    exe = which(backend)
    if exe is None:
        return None
    try:
        proc = run([exe, *_VERSION_ARGV[backend]], capture_output=True, text=True, errors="replace", timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = (proc.stdout or "") + (proc.stderr or "")
    match = _VERSION.search(text)
    if proc.returncode != 0 or not match or text[match.end():match.end() + 1] in ("-", "+"):
        return None  # a pre-release is not a version the ledger can accept
    return match.group(0)


def harness_command(host: Host, backend: str, version: str, rev: str, sha: str, out: Path, timeout: int) -> list[str]:
    return [
        sys.executable, "-m", "qualification", "run",
        "--backend", backend, "--backend-version", version, "--platform", host.platform,
        "--os", host.system, "--os-build", host.os_build, "--arch", host.arch,
        "--hypervisor", host.hypervisor, "--image", IMAGE, "--rev", rev,
        "--artifact-sha256", sha, "--transcript-dir", str(out), "--timeout", str(timeout),
        "--", sys.executable, str(Path("scripts") / "qualify-backend-cell"), "--backend", backend,
    ]


def run_backend(command: list[str], out: Path, backend: str, cwd: Path | None = None) -> Result:
    proc = subprocess.run(command, cwd=cwd or REPO_ROOT, capture_output=True, text=True, errors="replace")
    line = next((x for x in proc.stdout.splitlines() if x.startswith("RESULT ")), "")
    transcript = out / "transcript.json"
    status = _STATUS.get(proc.returncode, "FAIL")
    return Result(backend, status, proc.stderr.strip()[-400:], line, transcript if transcript.exists() else None)


def _recordable(r: Result, record_failures: bool) -> bool:
    return r.transcript is not None and (r.status == "PASS" or (record_failures and r.status in ("FAIL", "FLAKY")))


def apply_results(
    ledger: Path, results: list[Result], host: Host, record_failures: bool, accept: dict[str, str] | None = None
) -> list[Result]:
    """Edit ``ledger``: move accepted versions, then record each qualifying run."""
    for backend, version in (accept or {}).items():
        set_accepted_version(ledger, backend, version)
    recorded = []
    for r in results:
        if not _recordable(r, record_failures):
            continue
        raw = r.transcript.read_bytes()
        entry = entry_from_transcript(json.loads(raw), raw, platform=host.platform)
        append_entry(ledger, entry, retire_waiver=entry.verdict == "PASS")
        recorded.append(r)
    return recorded


def blast_radius(root: Path, accept: dict[str, str], host: Host | None = None) -> list[str]:
    """Other cells that stop being qualified if ``accept`` is applied.

    The host's own cell for each moved backend is excluded: this run re-qualifies it.
    """
    ledger = load_ledger(root / DEFAULT_LEDGER)
    moved = replace(ledger, accepted_backend_versions={**ledger.accepted_backend_versions, **accept})
    now = datetime.now(timezone.utc)
    paths = lambda r: git_changed_paths(r, cwd=root)  # noqa: E731
    before = {(s.backend, s.platform): s.status for s in evaluate(ledger, now=now, changed_paths=paths)}
    after = {(s.backend, s.platform): s.status for s in evaluate(moved, now=now, changed_paths=paths)}
    own = {(b, host.platform) for b in accept} if host else set()
    return sorted(
        f"{b}/{p}" for (b, p), status in before.items()
        if status == "qualified" and after[(b, p)] != "qualified" and (b, p) not in own
    )


def pr_text(
    host: Host, recorded: list[Result], rev: str, accept: dict[str, str] | None = None, expired: list[str] | None = None
) -> tuple[str, str]:
    names = " and ".join(r.backend for r in recorded)
    kind = "live runs" if all(r.status == "PASS" for r in recorded) else "live run results"
    title = f"chore(qualification): record {host.platform} {names} {kind}"
    lines = [
        f"Records live Tier-3 runs on {host.system} {host.os_build} ({host.arch}, {host.hypervisor}) at `{rev}`.",
        "", "```text",
        *[re.sub(r"dir=\S+", "dir=<transcript-dir>", r.result_line or f"{r.backend} {r.status}") for r in recorded],
        "```", "",
    ]
    if accept:
        moved = ", ".join(f"{b} {v}" for b, v in sorted(accept.items()))
        lines += [f"**Moves the accepted backend version to {moved}**, which expires every cell recorded at the old "
                  "major.minor until it is re-run."]
        lines += [f"Cells that stop being qualified because of this: {', '.join(expired) if expired else 'none'}.", ""]
    lines += [
        "A green run retires that cell's waiver, if it has one. Transcripts are not committed; the ledger holds their "
        "SHA-256, and the `transcript.json` files stay on the host that ran them.",
        "", "Generated by `python -m qualification.host`. AI-assisted tooling.",
    ]
    return title, "\n".join(lines)


def _cells_qualified(worktree: Path, host: Host, backends: list[str]) -> str | None:
    """None if every listed backend's cell is qualified in the edited ledger; else why not.

    Run inside the publish worktree, so the surface diff is evaluated against the
    branch point (the remote's current ``main``) — the same comparison CI will make.
    """
    proc = subprocess.run(
        [sys.executable, "-m", "qualification.gate", "--ledger", DEFAULT_LEDGER, "check", "--json"],
        cwd=worktree, capture_output=True, text=True,
    )
    try:
        cells = {(c["backend"], c["platform"]): c for c in json.loads(proc.stdout)}
    except (json.JSONDecodeError, KeyError, TypeError):
        return f"the gate could not be evaluated: {proc.stderr.strip() or proc.stdout.strip()}"
    bad = [f"{b}/{host.platform}: {cells[(b, host.platform)]['reason'] or cells[(b, host.platform)]['status']}"
           for b in backends if cells[(b, host.platform)]["status"] != "qualified"]
    return "; ".join(bad) or None


def plan(root: Path, host: Host, backends: list[str], versions: dict, only_stale: bool, accept_flag: bool):
    """Decide what to run: ``(to_run, results_for_skipped, proposed_version_moves, notes)``."""
    ledger = load_ledger(root / DEFAULT_LEDGER)
    status = {
        (s.backend, s.platform): s
        for s in evaluate(ledger, now=datetime.now(timezone.utc), changed_paths=lambda r: git_changed_paths(r, cwd=root))
    }
    to_run, skipped, moves, notes = [], [], {}, []
    for b in backends:
        cell = status[(b, host.platform)]
        if versions[b] is None:
            skipped.append(Result(b, "SKIPPED", f"{b} CLI not found, not runnable, or not a final release"))
            notes.append(f"{b}: not found on PATH (or not a final release); skipped")
            continue
        accepted = ledger.accepted_backend_versions.get(b)
        if accepted is None or not same_minor(versions[b], accepted):
            if not accept_flag:
                raise HostError(
                    f"installed {b} {versions[b]} is not the ledger's accepted {b} {accepted or '(none)'} (major.minor). "
                    f"Install {accepted or 'the accepted version'}, or pass --accept-backend-version to move it in the same "
                    f"PR (that expires every {b} cell recorded at the old minor until re-run)."
                )
            moves[b] = versions[b]
        if only_stale and cell.status == "qualified":
            skipped.append(Result(b, "CURRENT", "already current"))
            notes.append(f"{b}: {cell.status} (current); skipped by --only-stale")
            continue
        to_run.append(b)
        notes.append(f"{b}: {versions[b]}; cell is {cell.status}" + (f" ({cell.reason})" if cell.reason else ""))
    # Only backends that will actually run may move the accepted version; the caller
    # keeps the move only for those that then go green.
    return to_run, skipped, {b: v for b, v in moves.items() if b in to_run}, notes


def _exit_code(results: list[Result]) -> int:
    if any(r.status in ("FAIL", "FLAKY") for r in results):
        return 1
    return 0 if all(r.status in _OK for r in results) else 2


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="qualification.host", description=__doc__.split("\n")[0])
    p.add_argument("--backend", choices=[MSB, SBX], action="append", help="limit to a backend (repeatable)")
    p.add_argument("--only-stale", action="store_true", help="skip cells that are already current")
    p.add_argument("--no-publish", action="store_true", help="record in this checkout's ledger; no branch, push or PR")
    p.add_argument("--dry-run", action="store_true", help="show the plan and run nothing")
    p.add_argument("--remote", default=None, help="fork remote to publish to (default: the only non-upstream remote)")
    p.add_argument("--record-failures", action="store_true", help="also record FAIL/FLAKY outcomes")
    p.add_argument("--accept-backend-version", action="store_true",
                   help="move the ledger's accepted backend version to the installed one (expires other cells)")
    p.add_argument("--timeout", type=int, default=900,
                   help="seconds per attempt (a FAIL is retried up to 3 times; default 900)")
    return p


def _run(args: argparse.Namespace) -> int:
    root = REPO_ROOT
    if sys.version_info < (3, 12):
        raise HostError(f"Python >= 3.12 is required (running {platform.python_version()})")
    host = detect_host()
    backends = [b for b in (args.backend or [MSB, SBX]) if is_claimed(b, host.platform)]
    if not backends:
        raise HostError(f"{host.platform} is not a claimed platform for {args.backend or 'msb/sbx'}")
    remote = slug = None
    if not args.no_publish:
        remote, slug = pub.choose_remote(root, args.remote)
        pub.check_identity(root)
        pub.check_remote_reachable(root, remote)
    refusal = None
    try:
        rev = pub.check_checkout(root, remote)
    except HostError as exc:
        if not args.dry_run:
            raise
        # A preview should still show the rest of the plan; remember that a real run refuses.
        refusal, rev = str(exc), pub.git(root, "rev-parse", "HEAD").strip()
    sha = pub.artifact_sha256(root)
    versions = {b: backend_version(b) for b in backends}
    to_run, results, proposed, notes = plan(root, host, backends, versions, args.only_stale, args.accept_backend_version)

    print(f"host: {host.system} {host.os_build} {host.arch} hypervisor={host.hypervisor} cell={host.platform}")
    print(f"rev={rev}\nartifact-sha256={sha}\ntmpdir={os.environ.get('TMPDIR') or os.environ.get('TEMP') or '(default)'}")
    print("\n".join(notes))
    if proposed:
        print("will accept backend version(s) if they pass: " + ", ".join(f"{b} {v}" for b, v in sorted(proposed.items())))
        print("  cells that would stop being qualified: " + (", ".join(blast_radius(root, proposed, host)) or "none"))
    print("publish: " + (f"{remote} ({slug}) -> PR into {slug}:main" if remote else "no"))
    if args.dry_run:
        if refusal:
            print(f"\nWOULD REFUSE a real run: {refusal}")
            return 2
        return 0

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for b in to_run:
        out = root / "tmp" / f"qualify-out-{stamp}" / f"transcript-{b}"
        print(f"\n== {b} {versions[b]} ==", flush=True)
        r = run_backend(harness_command(host, b, versions[b], rev, sha, out, args.timeout), out, b)
        results.append(r)
        print(r.result_line or f"{b}: {r.status}")
        if r.status not in _OK:
            print(f"  to see the failing step, run: {sys.executable} scripts/qualify-backend-cell --backend {b}")
    if any(r.status == "PASS" and r.transcript is None for r in results):
        raise HostError("a run passed but left no transcript; nothing was recorded")

    recorded = [r for r in results if _recordable(r, args.record_failures)]
    green = [r.backend for r in recorded if r.status == "PASS"]
    accept = {b: v for b, v in proposed.items() if b in green}  # only a backend that went green moves its version
    if recorded and args.no_publish:
        apply_results(root / DEFAULT_LEDGER, results, host, args.record_failures, accept)
        print(f"\nrecorded in {DEFAULT_LEDGER}; commit it through a PR.")
    elif recorded:
        title, body = pr_text(host, recorded, rev, accept, blast_radius(root, accept, host) if accept else None)
        try:
            pub.publish(
                root, remote=remote, slug=slug, rev=rev, platform=host.platform, title=title, body=body,
                edit=lambda path: apply_results(path, results, host, args.record_failures, accept),
                verify=lambda wt: _cells_qualified(wt, host, green),
            )
        except HostError as exc:
            kept = [str(r.transcript) for r in recorded]
            raise HostError(
                f"{exc}\n  the runs are kept in {root / 'tmp'}; once the problem is fixed, re-run this command, or record "
                "them by hand with: " + "; ".join(f"python -m qualification.gate record {k}" for k in kept)
                + " (that does not move accepted_backend_versions or retire a waiver; edit the ledger for those)"
            ) from None
    for r in results:
        if r.status not in _OK:
            print(f"{r.backend}: {r.status} {r.detail}")
    return _exit_code(results)


def main(argv: list[str] | None = None) -> int:
    try:
        return _run(_build_parser().parse_args(argv))
    except (HostError, LedgerError, OSError) as exc:
        sys.stderr.write(f"qualification.host: {exc}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
