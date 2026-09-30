---
title: "Windows Host/Guest Path Forms and msb Argument Passthrough (MSYS)"
status: accepted
date: 2026-09-16
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-3", "SA-8", "SC-7"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0029: Windows Host/Guest Path Forms and msb Argument Passthrough (MSYS)

## Context and Problem Statement

The Windows preview runs the existing Bash `acq` under **Git Bash**
(MSYS/Cygwin) and drives the **native Windows** `msb.exe`. Two independent
path-vocabulary problems follow, and both must be handled for a workspace to
mount correctly.

**1. A mount needs two different forms of one path.** `msb create --volume`
takes `HOST:GUEST[:ro]`: the host side is resolved by native `msb.exe` on the
Windows filesystem (`C:/Users/me/proj`), and the guest side is the path inside
the Linux microVM, which must be POSIX (`/c/Users/me/proj`, or any absolute
`/...`). `C:/...` is **not** an absolute path in the guest. The same split
applies to the start directory (`msb exec -w`), the recorded
`/var/lib/acq/workspace` marker, and the `ACQ_WORKSPACE` create env
([ADR-0027](0027-neutral-clone-option.md)). An earlier revision passed one
`cygpath -m` value for both sides, which fixed the host side and broke the
guest (GSA-TTS/agentic-coding-quickstart#463).

**2. MSYS rewrites native-tool arguments.** When MSYS launches a native program
it rewrites POSIX-looking `argv` values to Windows form. Verified on Git for
Windows: `--volume C:/a:/c/b` survives, but `--volume /c/a:/c/a` becomes the
broken list `C:\a;C:\a`, `-w /home/agent` becomes
`C:/Program Files/Git/home/agent`, and `--env K=/c/a` becomes `C:/a`. So even a
correct guest value can be corrupted before `msb.exe` sees it. (The same
rewrite is *useful* for other native tools — `git.exe` relies on it to accept
`/c/...` — so it cannot simply be disabled process-wide.)

## Decision Drivers

- **Correct on Windows, unchanged on POSIX.** The fix must not alter
  macOS/Linux behavior, where the two forms are identical.
- **One source of truth per vocabulary.** Callers should never hand-roll path
  conversion; a value is either host-side or guest-side by construction.
- **No silent argument rewriting.** `msb` must receive the exact `argv` acq
  built, so every path form is auditable.
- **No new secret or trust surface.** This is pure argument plumbing.

## Considered Options

1. **Two helpers + a passthrough wrapper (chosen).**
   `canonicalize_path` emits the guest/POSIX form; a new `host_path` emits the
   native host form. Every `msb` invocation goes through a thin
   `_acq_msb_cli` wrapper that sets `MSYS2_ARG_CONV_EXCL='*'`, and each path
   argument is passed in its explicit form.
2. **Disable MSYS conversion process-wide.** Simplest single knob, but it
   breaks `git.exe`/`ssh`/native tooling that depends on the rewrite unless
   every such call site is also converted — a far larger, riskier change.
3. **Mount at a fixed guest root** (`/workspace`, `/home/agent/workspace`).
   Avoids needing a guest form derived from the host path, but loses sbx
   parity ("mounted at the same absolute path") and reintroduces the
   create-time mount-target ordering problem [ADR-0011](0011-msb-backend-and-neutral-kits.md)
   moved away from.

## Decision Outcome

**Chosen: Option 1.**

- `canonicalize_path` (common.sh) returns the real, symlink-free path in the
  shell's own POSIX vocabulary — on MSYS it normalizes with `cygpath -u`, so a
  drive-form path from a native tool becomes `/c/...`. This is the **guest**
  form (also what Bash itself wants).
- `host_path` (common.sh) returns the **native host** form — on MSYS
  `cygpath -m` (`/c/...` → `C:/...`) — and is the identity on POSIX. It is
  applied only to values a native host tool must resolve: the `--volume`
  source, `--script-path` file, `--tls-upstream-ca-cert` PEM, `--vsock` host
  socket, and the `msb copy` source. `msb ssh authorize --file` likewise.
- `_acq_msb_cli` (msb.sh) runs `MSYS2_ARG_CONV_EXCL='*' msb "$@"`, so MSYS
  leaves the argument vector untouched and the explicit forms survive. The
  exclusion is scoped to `msb` so `git`, `ssh`, and other native tools keep the
  rewrite they depend on.

Guest-side arguments keep the `canonicalize_path` form: the `--volume` target,
`--mount-named PATH`, `--env ACQ_WORKSPACE`, `-w`, `-e SSH_AUTH_SOCK`, and bare
`chmod`/`chown` guest paths. An explicit `ACQ_MSB_WORKSPACE` override is
host-vocabulary input too, so it is canonicalized to the guest form wherever it
is read (the provision-time marker write and `_acq_msb_workspace_for`) — without
that, a natural `C:/Users/me/proj` reaches `-w` verbatim. The workspace-marker
charset guard reverts to a conservative POSIX set (no `:`) now that the guest
value is never drive-form.

Three call sites cannot use `_acq_msb_cli` and inline the env prefix instead:

- the two `exec msb exec …` lines (`exec` needs a binary, not a function), and
- the backgrounded `msb ssh serve …` in `_acq_msb_serve_start`.

The backgrounded serve is the subtle one: wrapping a command in a shell function
makes bash fork a subshell for the background job, so `$!` is the subshell, not
`msb`. The recorded PID is then killed at teardown (or on the failed-forward
path) while the real `msb ssh serve` is reparented and keeps the loopback port
bound. A bare env-prefixed command is exec-optimized into the real process, so
`$! IS msb`. A regression test asserts the recorded PID is the stub's own `$$`.

`acq_backend_cp` is the one deliberate exception: `msb copy` takes one host path
and one `NAME:/guest/path` ref, and MSYS rewriting already converts the bare
host path while leaving the `NAME:`-prefixed guest ref verbatim. Parsing which
side is the sandbox ref would be ambiguous with a drive letter, so `acq cp`
keeps the rewrite.

### Testability

The real rewrite happens in the MSYS runtime, so a unit test cannot trigger it
on a POSIX CI host. Two seams make the contract testable instead:

- A fake `cygpath` (a stable POSIX↔drive bijection) planted on `PATH`
  exercises the two-form split on any host: the mount uses the host form for
  the source and the guest form for the target, `ACQ_WORKSPACE` stays POSIX,
  the `ACQ_MSB_WORKSPACE` override and `-w` are guest-form, and the
  `--script-path`, `--tls-upstream-ca-cert`, `--vsock`, `msb copy` source, and
  `ssh authorize --file` values are host-form (`test/bats/117-msys-path-forms.bats`).
- A stub `msb` asserts `MSYS2_ARG_CONV_EXCL=*` reaches the child, and a
  backgrounded `msb ssh serve` stub writes its own `$$` so
  `test/bats/112-msb-ports.bats` proves the recorded PID is the real process
  (not a function-wrapper subshell).

Tests that exercised the adapter without sourcing `common.sh` were updated to
source it (production sources `common.sh` before the backend), so `host_path`
is defined there too.

## Consequences

- **Positive:** a Windows workspace mounts at a valid guest path; POSIX hosts
  are byte-for-byte unchanged; each msb path argument has one correct form, and
  the passthrough wrapper makes the argv auditable.
- **Negative / trade-off:** `msb` calls are routed through a wrapper, so a
  future msb subcommand that needs MSYS conversion would have to say so
  explicitly; the wrapper is invoked without `command` so shell-function shims
  (used by tests) still shadow `msb`. The `MSYS2_ARG_CONV_EXCL='*'` assignment
  is therefore written literally at the three sites above in addition to the
  wrapper — an unavoidable drift surface (`exec` cannot run a function, and the
  backgrounded serve needs `$!` to be the real process).
- **Scope:** applies whenever `cygpath` is present (MSYS/Cygwin). `host_path`
  and `canonicalize_path` are intentionally guarded so a caller without
  `common.sh` degrades to the identity form rather than erroring; production
  always loads `common.sh` first.

## Links

- GSA-TTS/agentic-coding-quickstart#463 — the review that surfaced the
  single-form bug and the MSYS rewriting behavior.
- [ADR-0011: msb backend and neutral kits](0011-msb-backend-and-neutral-kits.md)
  — "mounted at the same absolute path inside the guest" and the symlink
  canonicalization this builds on.
- [ADR-0027: neutral `--clone`](0027-neutral-clone-option.md) — the guest
  markers (`ACQ_WORKSPACE`, `ACQ_CLONE`) that ride the same path vocabulary.
- `docs/BACKEND_GUIDE.md` (workspace mounting) and
  `docs/KNOWN_FAILURE_MODES.md` §39 (Windows preview).
