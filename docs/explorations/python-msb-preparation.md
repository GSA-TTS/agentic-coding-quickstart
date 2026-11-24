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
   detached exec, no stdin, timeout, named user, read-only attach, limited inventory,
   direct job inspection, signal and kill. Older, future and malformed versions fail closed. Help text
   is a compatibility check, not authentication of the executable.
3. Take a bounded pre-launch inventory. Reject reused detached IDs, including
   retained jobs from an earlier boot. Launch with `--detach --no-stdin`, a
   native timeout derived from the remaining shared deadline, and a named
   `--user`. No TTY flags, stdin, or provider-controlled argv.
4. Require one exact `job_<32 lowercase hex>` response; fetch its exact command,
   no-TTY/closed-stdin flags, v1 schema and valid boot ID. Bind all subsequent
   observations to that boot ID. Read-only attach captures raw bytes. After
   attach, poll the exact job to terminal state; attach's CLI exit alone is not
   guest completion evidence.
5. Require no native timeout/failure/error and validate guest output using the
   authoritative job exit code. A successful job with failed attach is refused.
   Native signaled jobs report `exit_code: -1`, **not** shell status 143; no signal
   identity is inferred from that value.

One monotonic deadline covers capability checks, inventory, launch, attach and
terminal polling (default 60 seconds, maximum 300). Native timeout uses positive
whole milliseconds rounded down from the remaining budget. Each subprocess has
null stdin, two binary pipes and a new host session. A selector concurrently
drains both pipes with read-time caps: 1,024 attached stdout bytes, 16,384 stderr
bytes, 262,144 control stdout bytes. There is no unbounded `communicate` or text
capture. Host subprocess reap after failure has a separate 0.5-second ceiling.

Pre-launch inventory requests `--limit 100` (the native CLI's maximum) and accepts at most 100 jobs and one
complete page. A non-null cursor refuses before launch, never silently truncating
evidence. After launch, all status reads, including cleanup, use
`inspect --job JOB --format json NAME` and require the returned ID to equal the
requested ID. A new job crossing the inventory page boundary therefore does not
prevent its supervision or cleanup. Duplicate
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
`SystemExit`, initiates guest `signal --job ... --signal TERM` and, if needed,
guest `kill --job ...`. A separate five-second cleanup budget polls the exact
job and boot for terminal status. A refused control command is not confirmation;
only validated terminal status confirms managed-job cleanup. On confirmed
cleanup the original exception propagates. Otherwise `CleanupUnconfirmed`
requires quarantine. Polling after signals is intentional reconciliation, not a
retry of preparation or a second launch.

Killing/reaping a host transport group **never proves guest cleanup**. If launch
may have happened but its ID was lost, malformed, duplicated or already in the
pre-launch inventory, the module does not guess a job to signal: it reports
unconfirmed cleanup. Native timeout remains the backstop, not observed cleanup.
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

No signal handlers are installed or replaced. Normal Python cancellation
exceptions are handled, including default SIGINT/KeyboardInterrupt. Default
SIGTERM, SIGKILL, interpreter crash, a second interrupt during cleanup, or host
shutdown cannot promise confirmed cleanup. A coordinating process may translate
its own cancellation into an exception, but this module does not change global
signal policy. Native timeout and quarantine/reconciliation remain necessary.

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

### Synthetic state publication regression

The primary's initial combined sandbox run reported 81 passed, one skipped and
one failure: the stdout-cap case raised `CleanupUnconfirmed`. Static inspection
identified a race in the synthetic executable: after emitting oversized stdout,
attach used `Path.write_text` on the authoritative job file. Killing that host
transport could interrupt the truncate/write sequence, leaving cleanup unable
to read any job status. The failure summary alone cannot establish whether that
specific run hit this race or exhausted its shortened cleanup budget.

The fixture now publishes job state via a private per-process file and atomic
replace. This models the relevant native boundary: killing attach must not tear
the backend's authoritative job record. A deterministic case emits oversized
stdout while a private state file contains only partial JSON; it requires the
original output-limit refusal and confirmed exact-job TERM cleanup. A separate
case deliberately corrupts the authoritative file and still requires
`CleanupUnconfirmed`, including attempted TERM/KILL. No production cleanup
deadline or refusal assertion was relaxed. These added tests need a fresh
sandbox run; the edit-only worker has not executed them.

### Inventory page-boundary regression

The runner now explicitly requests its bounded pre-launch limit and uses direct
job inspection for every post-launch status read. Synthetic cases cover a full
pre-launch page followed by a successful new job or output-cap cleanup, a wrong
returned job ID, and refusal of incomplete pre-launch inventory before any exec.
The pre-launch limit remains intentional protection against retained-ID reuse.
These edits have not been executed by the edit-only worker. Actual new-runner
qualification remains unverified and needs an isolated controller; authorization
for earlier native CLI probes does not permit executing new code on the operator
host. See [ADR-0054](../adr/0054-fresh-only-terminal-preparation.md) for the launch
integration decisions still required.
