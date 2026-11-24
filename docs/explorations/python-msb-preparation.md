# Narrow Python MSB preparation transport

## Interface (frozen for coordinator integration)

`acq_py.msb_preparation.run_preparation(name, identity, *, node, artifact,
provider_root, global_dir, base_config, guest_user="agent", timeout=60.0,
ca_bundle=None)`
returns the existing immutable `runtime_preparation.PreparationResult`. Identity
is the exact host-supplied `InvocationIdentity`, not fields read from guest
output. Guest argv is built only by `runtime_preparation.build_argv`; the exact
job's terminal exit code and bounded raw stdout go to `parse_result`.

`ManagedJobError` derives from the existing `PreparationError` and contains only
fixed diagnostics. `CleanupUnconfirmed` derives from `ManagedJobError` and means
the coordinator **must quarantine/refuse activation**: a guest may remain alive.
Protocol failures use the existing parser's closed diagnostics. Neither error
class prints backend output, guest paths, or secrets.

There is no lifecycle/store integration, mount mutation, live activation,
credential access, persistent receipt, or general job framework here. The module
uses the standard library on POSIX. The caller owns lifecycle serialization,
fresh input verification, current identity comparison and evidence consumption.

## Managed-job sequence and bounds

1. Validate the invocation and resolve `msb.msb_command()` once. It must produce
   an absolute executable plus trusted argv. The existing host resolver excludes
   relative PATH entries; an operator-controlled override remains trusted code,
   not a guest-controlled setting. No argv is interpolated into a shell.
2. Require the explicitly qualified version (`msb 0.7.16`) and help flags for
   streaming exec, no stdin, timeout, named user, limited inventory,
   direct job inspection, signal and kill. Older, future and malformed versions fail closed. Help text
   is a compatibility check, not authentication of the executable.
3. Take a bounded pre-launch inventory, reserving one slot for acknowledgment.
   Launch with `--stream --no-stdin`, a native CLI timeout derived from the shared
   deadline, and a named `--user`. A fixed `exec "$@"` wrapper carries a new
   host-generated nonce as its shell argument zero. No provider-controlled shell
   source, TTY, stdin, detached launch, attach replay, or log replay is used.
4. Capture raw stdout/stderr through separate bounded pipes from launch inception.
   Independently enumerate jobs until exactly one new ID matches the complete
   unique argv; validate no-TTY/closed-stdin flags, v1 schema and boot ID. Then
   poll only that exact job, binding observations to its boot. A completed job
   can be acknowledged after it emitted all output; no output subscription is
   opened after launch. CLI exit alone is not guest completion evidence.
5. Require no native timeout/failure/error and validate guest output using the
   authoritative job exit code. A successful job with failed transport is refused.
   Native signaled jobs report `exit_code: -1`, **not** shell status 143; no signal
   identity is inferred from that value.

One monotonic deadline covers capability checks, inventory, launch, capture and
terminal polling (default 60 seconds, maximum 300). Native timeout uses positive
whole milliseconds rounded down from the remaining budget. Each subprocess has
null stdin, two binary pipes and a new host session. A selector concurrently
drains both pipes with read-time caps: 1,024 preparation stdout bytes, 16,384 stderr
bytes, 262,144 control stdout bytes. There is no unbounded `communicate` or text
capture. Host subprocess reap after failure has a separate 0.5-second ceiling.

Pre-launch inventory requests `--limit 100` (the native CLI's maximum) and accepts
at most 99 jobs and one complete page. A full page or non-null cursor refuses
before launch. Acknowledgment also requires one complete bounded page; unrelated
external launches that overflow it cause quarantine, not guessed identification.
After acknowledgment, all status reads, including cleanup, use
`inspect --job JOB --format json NAME` and require the returned ID to equal the
requested ID. Later inventory growth does not affect exact-job supervision. Duplicate
JSON keys, duplicate/malformed job IDs, invalid UTF-8, nonfinite JSON, unknown
exact-job fields/states, missing jobs, inconsistent terminal fields and changed
boot IDs are refused. Only the observed `running` and `exited` states are
supported; a future or early queued-state response is not guessed to be safe.
Bounded pre-launch inventory still detects IDs present before launch; direct
inspection does not replace that freshness check.

## Cancellation and trust limits

The opt-in `ca_bundle` path enables the candidate's fixed clean launch. It must
be an explicitly approved absolute guest CA path, not provider input or an
enterprise upstream-CA setting. A fixed `/bin/sh` program checks a bounded,
nonempty regular CA file and non-writable, non-symlink parents as the preparation
user, then uses `/usr/bin/env -i` **before** Node starts. Only fixed HOME/PATH, the
guest's backend-injected USAi placeholder and the approved CA path survive.
Node options/preloads, TLS-disable settings and unrelated secrets do not. The
host never reads the placeholder value; it appears only in guest-local env argv,
not host argv, and is not the real proxied credential. Fixed MSB environment
overrides clear shell startup and dynamic-loader hooks before the shell starts.
This assumes the normally provisioned guest OS, not a compromised loader/shell.
The coordinator uses this mode with the host-selected `/usr/bin/node`. It reads
only the backend-resolved host original public interception CA, stages a private
attempt copy read-only in host-config, and refuses rotation or source mismatch.
The legacy direct protocol-test mode is not a clean-environment launch admission.
The exact integrated coordinator/runner still requires isolated qualification.

Every exception after an accepted job ID, including `KeyboardInterrupt` and
`SystemExit`, checks the exact identity/status before guest
`signal --job ... --signal TERM` and, if needed, `kill --job ...`. Already terminal
jobs need no signal; malformed or changed identities are never signaled.
A separate five-second cleanup budget polls the exact
job and boot for terminal status. A refused control command is not confirmation;
only validated terminal status confirms managed-job cleanup. On confirmed
cleanup the original exception propagates. Otherwise `CleanupUnconfirmed`
requires quarantine. Polling after signals is intentional reconciliation, not a
retry of preparation or a second launch.

Killing/reaping a host transport group **never proves guest cleanup**. If launch
may have happened before acknowledgment, one separately bounded inventory read
attempts to recover the unique exact-argv job. Missing, ambiguous, reused or
unverifiable identity means unconfirmed cleanup, never a guessed signal target.
Foreground native timeout is a **CLI-owned timer**, not an independent guest
watchdog: the native stream path passes no SDK timeout. Killing/crashing the CLI
can remove that timer. Host caps require `--stream`, because without it the CLI
internally accumulates unbounded output before printing.
The caller needs an explicit quarantine/remediation path for this uncertainty.

The native sandbox-inspect receipt does not expose a current runtime boot ID.
Retained completed jobs survive restart with their old boot IDs. Consequently,
the module proves that the returned ID was absent from its pre-launch inventory
and that subsequent exact-job observations have one stable boot; **it does not
independently prove the currently running sandbox boot or authenticate the
host's sandbox-instance token**. The caller must hold the lifecycle barrier from
before invocation through identity revalidation/use and must reject any known
restart/removal. An external same-account operator bypassing that barrier is
outside this guarantee. The trusted native backend must allocate fresh job IDs.

During Popen creation/handle registration the preparation transport temporarily
wraps existing callable TERM/HUP handlers, delegates to them immediately, and
defers their exceptions until the handle is owned inside the cleanup block. This
preserves the CLI repeat-signal grace clock without an inherited blocked mask or
SIG_IGN. Outside that interval it restores the previous handlers. Normal Python
cancellation exceptions are handled, including default SIGINT/KeyboardInterrupt. Default
SIGTERM, SIGKILL, interpreter crash, a second interrupt during cleanup, or host
shutdown cannot promise confirmed cleanup. A coordinating process may translate
its own cancellation into an exception, but this module does not change global
signal policy. Independent exact-job cleanup and quarantine remain necessary.

Terminal status proves the native managed job ended, not arbitrary malicious
descendant containment. Guest process-group TERM/KILL and native timeout depend
on MSB's qualified behavior; a process escaping the group is outside this narrow
transport's guarantee. The reviewed preparation artifact must keep its children
in the managed group. Guest-root compromise or a same-account replacement of the
host CLI is not defended by protocol parsing or help checks.

## Validation ownership and remaining qualification

`py-acq/tests/test_msb_preparation.py` writes an actual synthetic Python CLI executable
and resolves it through the real `ACQ_MSB_BIN` argv path. It exercises real raw
pipes, control refusals, exact argv, no stdin/TTY, native-timeout flag derivation,
shared deadlines, both stream caps, malformed/ambiguous responses, retained IDs,
boot mismatch, TERM/KILL escalation, cleanup refusal, and exception cancellation.
The fake never executes guest argv; it does not claim native isolation or guest
descendant cleanup. Test dependencies are the repository's existing pytest only.

The test lives in the Python package's ordinary test directory. A sandbox
validation command from the repository root is:

```text
PYTHONPATH=py-acq/src python -m pytest py-acq/tests/test_msb_preparation.py
```

No test, install, shell command, native probe or Git operation was executed by
the edit-only worker. The primary session must run the synthetic suite and
quality checks inside its reviewed workspace sandbox, then qualify this exact
runner with the actual native CLI. In particular, verify version-banner bytes,
the exec help flags and millisecond timeout syntax, the guest named-user setup,
successful preparation, a real Node parent/child cancellation, and native timeout
cleanup. Existing native receipts establish attach/read-only behavior, the v1
job JSON shape, `-1` signaled exits and retained old-boot jobs; those observations
are not a passing test result for this new implementation.

### Historical detached-fixture state publication regression

The primary's initial combined sandbox run reported 81 passed, one skipped and
one failure: the stdout-cap case raised `CleanupUnconfirmed`. Static inspection
identified a race in the synthetic executable: after emitting oversized stdout,
attach used `Path.write_text` on the authoritative job file. Killing that host
transport could interrupt the truncate/write sequence, leaving cleanup unable
to read any job status. The failure summary alone cannot establish whether that
specific run hit this race or exhausted its shortened cleanup budget.

The fixture publishes job state via a private per-process file and atomic
replace. This models the relevant native boundary: killing attach must not tear
the backend's authoritative job record. A deterministic case emits oversized
stdout while a private state file contains only partial JSON; it requires the
original output-limit refusal and confirmed exact-job TERM cleanup. A separate
case deliberately corrupts the authoritative file and still requires
`CleanupUnconfirmed`, including attempted TERM/KILL. No production cleanup
deadline or refusal assertion was relaxed. These added tests need a fresh
sandbox run; the edit-only worker has not executed them.

### Superseded detached inventory behavior

The former detached transport could accept 100 preexisting jobs because exec
returned the new ID directly. The foreground replacement instead reserves an
acknowledgment slot and tests pre-launch refusal at that boundary. It still uses
direct inspection after acknowledgment and refuses retained-ID reuse.

### Foreground output regression and remaining qualification

Native qualification reported that a fast detached job reached exited/zero but
later attach returned no stdout. Job-log export retained that probe's output,
but retention/truncation and completion-flush guarantees were not established.
Even the exported job ID is CLI-selector-derived, not independent entry evidence.
Neither attach nor logs is a complete-output acceptance channel here.

The primary reports native MSB 0.7.16/current-image qualification of immediate
output with `exec --stream --no-stdin --timeout 5s`, and a healthy CLI's one-second
timeout ending both a shell and its sleep child. This is not evidence of a
watchdog surviving CLI death, nor a passing run of this modified Python runner.
The synthetic fast-completion case gates acknowledgment until terminal metadata
and all output are published. Both synthetic backends now emit protocol output
during exec rather than inventing attach replay.

The edit-only worker has not run these changes. The primary must run the affected
fixtures and full Python suite in its reviewed workspace sandbox, then qualify
the exact runner with native MSB: immediate completion before acknowledgment,
live target-VM proxied refresh, both output caps, timeout, cancellation, exact-job
cleanup and acknowledgment uncertainty. Revalidate covered lifecycle/session
commands; older-head test counts do not validate this patch.

Foreground session ownership now defers raising TERM/HUP only across child
creation/handle registration, preserving the installed CLI repeat-signal policy.
Cleanup lock refusal still reaps the owned host child, without guest/name-state
mutation or deletion of the durable attempt/CA. Deterministic spawn injection and
a live-host-child lock-refusal fixture cover these boundaries. Subprocess CA
fixtures provision a private root under a validated checkout or pre-test HOME;
when neither has trusted ancestors, provision e.g. `/validation/home` before
pytest. Shared `/tmp` is never chmodded and production validation is unchanged.

### Qualified legacy session admission

The former outside-lock legacy/non-OpenCode selection could choose the old launch
path before a same-name removal/recreation as OpenCode. Rechecking only the fresh
branch was insufficient. The explicit compatibility decision now requires exact
MSB 0.7.16 qualification for **all run, attach, exec and shell sessions**, including
typed and by-name run. Older and unqualified future versions receive an explicit
upgrade/qualification refusal before session effects. Other lifecycle commands
and SBX retain their existing version policy.

All MSB session routes now hold one lifecycle lock from final record/path selection
through exact-job acknowledgment, releasing it before foreground wait. Legacy
profiles share attempt ownership, quarantine/abandonment checks and acknowledgment
but do not acquire OpenCode provider/CA preparation. Their exec argv stays opaque
behind the fixed positional wrapper; shell/login/TTY, environment precedence,
entrypoint selection, workspace translation and exit/signal handling are retained.
Older host records need no token rewrite: when the held instance token is absent,
the native inspect creation identity guards ownership and replacement cleanup.

Typed and by-name run no longer unlock between heal/key checks and name-based
launch. Optional refresh prompts occur before final admission, outside the lock;
their later locked refresh refuses a now-OpenCode/quarantined replacement. Final
admission rereads the record rather than treating prompt-time observations as
authority. Changed record/instance or quarantine before acknowledgment refuses
success and leaves replacement state untouched during cleanup.

New deterministic fixtures cover all five routes before selection, quarantine
and replacement during acknowledgment, plus two healthy legacy owners and exact
version refusals. Legacy session fixtures explicitly opt into qualified jobs;
the general old-version stub and non-session lifecycle fixtures are not globally
masked. These new changes remain unexecuted by the edit-only worker. The primary's
earlier four-repair run reported 277 passes and four cleanup failures; the latter
were traced to host cleanup being repeated outside an already-acquired lock.
Fallback host-only cleanup is now restricted to lock acquisition failure. That
run is not validation of this combined session patch.

Non-TTY foreground sessions explicitly request `--stream`; inherited output fds
alone do not prevent native CLI buffering. TTY sessions retain their native TTY
path without `--stream`. The synthetic session test withholds completion until
the parent has actually received output, covering both piped stdin and terminal
stdin with non-TTY exec. For terminal stdin, non-TTY exec adds `--no-stdin` to
preserve native noninteractive EOF semantics: MSB rejects `--stream` with terminal
stdin without that flag. Real pipe input remains connected and is tested byte for
byte; normal TTY run/attach/shell adds neither flag. The fixture enforces the native
restriction before job creation and checks successful completion without quarantine.
Preparation spawn regressions create a real host child,
inject TERM/HUP before Popen returns its handle, and require host reap plus exact
guest cleanup (or explicit unacknowledged-launch uncertainty). These additional
repairs and tests remain unexecuted by the edit-only worker.

### Native CLI foreground job-inventory blocker (handoff status)

Subsequent native MSB `0.7.16` probes against the current guest image refuted the
CLI foreground inventory-acknowledgment assumption: both fast-completing and
30-second running `msb exec --stream` commands execute over the direct agent
execution stream without creating or appearing in `msb job list` (only earlier
detached jobs appear in the job inventory). Because the CLI does not expose a
foreground `Started` acknowledgment or per-execution control handle, synthetic
CLI stub passes do not establish native compatibility for `msb_preparation.py`
or `fresh_launch.py`'s foreground inventory acknowledgment loop.

This branch (`feat/python-guest-refresh`) is published as a draft handoff to
preserve the staging, managed-config renderer, ownership, signal-deferral, and
cleanup-lock repairs while the transport layer is migrated to the Python SDK
`Sandbox.exec_stream` / `LocalContext` contract prototyped on
`experiment/python-sdk-transport`. Do not merge this branch with the CLI
inventory-polling transport in place.
