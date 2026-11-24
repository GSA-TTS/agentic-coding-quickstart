# ADR-0054: Fresh-only terminal preparation

Status: Proposed. The implementation plan and limited operational trust model
are approved; the integrated candidate still requires isolated validation and
native qualification.

## Scope

The candidate is limited to the exact packaged USAi provider or explicit provider
NONE, with plain OpenCode on POSIX MSB. It does not claim SBX, Windows, custom image or kit,
daemon, team, or cached-preparation parity. Unrelated agents and backends retain
their existing behavior. Unsupported OpenCode profiles must be refused before
startup or other mutations, not after a competing renderer has run.

Public create, recreate, start, restart, run and attach must reach fresh live
preparation before reporting success or admitting a dependent launch. Public
exec and shell on this profile pass the same fresh admission; internal
setup/readiness probes must not recurse into public admission.

## Proposed architecture

1. Check the exact selected profile before effects. Adapt selected command lists
   in memory to suppress the legacy renderer; never modify the pinned bundle.
2. Use `fresh_inputs.prepare` to snapshot and validate verified packaged bytes.
   Mount the unpublished generation read-only using existing provider-input
   flags. Publish only after backend acceptance.
3. Read the actual backend mount source, not a mutable current pointer. Verify
   its closed receipt, runtime and base digests against current verified sources,
   instance identity and current credential bindings before guest preparation.
4. Execute the packaged CLI through bounded `msb_preparation.run_preparation`
   inside the actual target guest with its proxied credential. There is no host
   discovery or helper VM. Reuse the packaged managed-config renderer, with a
   clean initial environment and the approved guest Node and CA paths. Consume only a completed live
   result bound to the exact attempt, instance, generation and routing snapshot.
   Recheck those identities and bindings immediately before launch admission.
5. Hold lifecycle and shared credential-store synchronization through checked
   preparation and backend-acknowledged managed-job launch. Start foreground MSB
   exec with inherited stdio under the lock, correlate its attempt-unique wrapper
   argv with one new managed job, then release locks before waiting for the CLI.
   The pinned harness always receives `--standalone`, so fresh preparation does
   not hand off to an already-running service with stale configuration.
   Preserve TTY, stdin, environment, workspace and child-status semantics. Until
   separately qualified, nonempty harness arguments refuse. Public exec forwards
   its argv opaquely without a TTY; public shell uses the existing login-shell
   and terminal-detection behavior after the same fresh admission.

There is no cache or reuse. Unknown keychain/environment revisions remain
unknown; matching bindings and fresh live success may qualify without falsely
requiring an `applied` record. Credential writers and confirmation hooks remain
owned by their existing implementation. No generic lease or job framework is
introduced.

Explicit NONE materializes a present empty `models/providers` directory plus
the same verified runtime and base, with a distinct closed receipt and routing
digest. Missing inventory never means NONE. The coordinator verifies the host
selection agrees with that receipt, refuses residual active USAi bindings, and
still invokes live-required preparation. The clean wrapper omits USAi entirely
for NONE. The existing renderer removes previously owned provider entries while
preserving user configuration; it is not skipped because discovery is empty.
Unrelated support-kit failures retain their existing warning/provenance behavior;
only agent, provider and CA prerequisites are preparation-fatal at create.

## Managed preparation job inventory

Pre-launch inventory is bounded and must be complete: request the native maximum
explicit limit of 100
and refuse a remaining cursor before launch. After acknowledgment, query the
exact job with `inspect --job JOB --format json NAME`, including during cleanup.
Require its returned ID to match the requested ID, in addition to command and
runtime-boot identity checks. Crossing an inventory page boundary must not make
an acknowledged job impossible to supervise or clean up.

## Candidate dispatch and validation

`fresh_launch.py` is called by lifecycle and session dispatch, not merely a
protocol library. Create/recreate stage a fresh immutable input generation and
run preparation after kit setup, before success. Start/restart re-run live
preparation against the actual mounted generation after setup. Run/attach run
another fresh preparation immediately before acknowledged foreground launch.
Public exec/shell on the OpenCode profile perform fresh preparation and owned
foreground admission before the requested guest command. No internal setup
probe enters those public commands. Other agents and SBX retain their paths.

Typed `run AGENT PATH --name NAME` must agree with an existing OpenCode host
record; a different typed agent cannot heal or launch the recorded entrypoint
through the legacy path. The check is repeated under the transaction lock.
Selection centrally suppresses the legacy renderer for every plain OpenCode
caller. Force kit update and single-kit apply explicitly refuse this profile;
they cannot replace live configuration with a snapshot while a harness runs.

An old sandbox without the exact fresh-input mount refuses; this is not a
silent migration or fallback. The existing security-exception-only recreate
eligibility is unchanged, so a legacy sandbox that otherwise passes its trust
gate may require explicit removal and creation. A quarantined fresh instance
also requires removal/recreation. No old configuration or previous result
supplies admission on failure. The candidate currently repeats preparation for
new `run` (create completion and terminal admission); it deliberately does not
cache or carry forward the first result.

`test_fresh_launch.py` covers real plan/dispatch/coordinator/parser seams with
fake backend boundaries: exact profiles before effects, nonmutating renderer
suppression, actual generation staging, mounted receipts, unknown revisions,
changed instance/bindings/mount/CA, old-config failure without success, opaque
exec/login-shell admission, and foreground acknowledgment under locks with wait outside.
These edits were not executed by the edit-only worker. Primary isolation tests,
quality checks, broader compatibility tests, and native exact-implementation
qualification are mandatory before claiming readiness.

## Open decisions and qualification limits

This is an operational completion gate, not malicious-root attestation.
Consistent with ADR-0035, the host supplies verified read-only code and invokes
the established guest interpreter. Host-selected bindings, routes, mounts and
profiles remain authoritative. Guest catalogs and generated configuration are
never read back as authority for host policy or credential routing. The initial
environment removes Node preload/TLS-disable overrides before Node starts and
preserves only the target guest's proxied USAi placeholder and approved CA path.
The preparation runs as agent; the existing privilege model is unchanged. Guest
root can subvert guest execution, so completion does not attest against that
attacker. No such stronger guarantee is claimed.

The approved static guest CA must include MSB's interception trust and be
canonical, bounded to 2 MiB, non-writable by the preparation user and protected
by non-writable parents. Enterprise certificates used by the host backend on
its upstream TLS leg are a separate setting. Never export a mutable guest CA
back to the host. Fixed initial environment overrides remove shell startup and
loader hooks before the fixed shell program invokes `env -i`; this hygiene does
not attest the guest shell, loader or OS. Only the injected placeholder, not the
actual proxied credential, is expanded into guest-local environment arguments.

Native inspection of a cached devenv image establishes `/usr/bin/node` and agent
uid 1000. That image is not the default digest in this candidate, so its result
does not qualify the candidate image. It also establishes that agent cannot
traverse `/.msb` to the automatically supplied `/.msb/tls/ca.pem`; the underlying
runtime mount is writable. That path is not an acceptable fallback. Do not copy
the runtime's guest-state certificate back to host storage and then treat the
copy as trusted. Exact MSB source establishes the host original: the configured
interception public certificate, or `tls/ca.crt` under the MSB home established
by backend storage inspection (cross-checked against an explicit MSB_HOME).
Read only that bounded public-only PEM with no-follow ancestor checks; reject
guest mount overlap. Stage a fresh 0444 copy in the already verified read-only
host-config mount, compare the original again after preparation and immediately
before launch, then remove the staged copy. Never read/copy the private key or
generate a CA. An unreadable, rotated or ambiguous source refuses admission.

Terminal admission retains a separate attempt-private public CA copy and passes
its read-only guest path as NODE_EXTRA_CA_CERTS and SSL_CERT_FILE to OpenCode,
overriding inherited session CA variables and enabling TLS verification. That
copy remains available through foreground completion, then is removed. An
uncertain launch retains it with quarantine until sandbox removal, rather than
breaking a possibly live guest. No private key or credential is retained.

Foreground cleanup ownership starts before spawn and spans acknowledgment,
lock release, handoff and waiting. Its narrow handle retains the host process,
backend command, exact job ID/boot/argv, TTY mode and public CA path. Parent-only
SIGTERM/SIGHUP and handoff exceptions unwind the owning context, terminate/reap
the host transport with bounded escalation, then inspect and signal the exact
guest job with bounded TERM/KILL reconciliation. A host exit alone never permits
CA deletion. Only confirmed host and exact guest completion remove the copy;
uncertainty retains it and records quarantine. Cleanup does not replace the
original termination exception, so the existing CLI boundary retains signal
exit semantics. SIGKILL, repeated signals that force interpreter exit, or a
compromised same-account backend remain outside this cleanup guarantee.

Parent termination forwards its original signal (including SIGHUP), rather than
converting it to SIGTERM. Foreground waiting uses the existing hostexec interrupt
handler and SIGINT re-raise pattern: a whole-job SIGINT that kills the child ends
acq by SIGINT after cleanup, preserving calling-shell loop behavior. A signal
directed only at the child retains the ordinary status-130 result.

The SIGINT handler is installed before foreground spawn and retained through
acknowledgment, handoff and waiting. An interrupt received during job polling is
not reset at wait entry and must not prematurely terminate a child that is
handling the terminal's interrupt.

The ownership scope also delegates the installed CLI termination handlers while
recording the original termination exception/signal before unwinding begins.
If a control-process reap or another finalizer raises a secondary operational
error, that error cannot turn SIGHUP into default TERM cleanup or exit 1. Handler
dispositions and the CLI's repeated-signal policy are preserved; handlers are
restored after cleanup. Deterministic tests inject masked HUP during exact-job
acknowledgment, identity recheck and active-record persistence, separately from
the unchanged real-PTY/parent-signal tests.

Host-only per-attempt files exclude unresolved launches across crashes and
failed quarantine writes. Under the lifecycle lock, a pending record is created
and fsynced before spawn; failure refuses launch. Its owner holds an advisory
lock on that exact file, and writes the acknowledged job/boot/argv as active.
Admission permits healthy concurrent sessions only when the bounded active
record still has a live owner lock and exact backend identity. Pending, cleaning,
malformed or abandoned records refuse admission. Cleanup reacquires the
lifecycle lock before host/guest termination and deletes its record only after
confirmed cleanup. On persistence failure, the original record remains and its
owner lock closes before lifecycle unlock, making abandonment fail closed.
No new admission relies on a late best-effort quarantine write. This is bounded
foreground coordination (at most 32 attempts), not cache/reuse authority. Confirmed
sandbox removal/replacement retires abandoned records; healthy concurrent
sessions do not hold the lifecycle lock for their interactive duration.

An owner also retains its original host-held sandbox instance and open attempt
file. Under the lifecycle lock, cleanup compares the instance and the file's
device/inode/link identity before any name-scoped mutation. If removal or
recreation retired/replaced either, only the old host transport is reaped: the
replacement is neither signaled nor quarantined, and no replacement CA/attempt
file is deleted. Old guest completion remains explicitly unconfirmed. Before
spawn, attempt-directory creation syncs its containing directory chain as well
as the pending record and its directory; a failed directory sync refuses launch.

Native probes now establish detached TTY/open-stdin jobs and subsequent
input-owning attach, including pipe input. They also show that attach omits early
output retained by logs. Launching the harness before attach therefore does not
preserve foreground semantics. The candidate therefore uses foreground exec,
connected to stdio from inception, not detached exec followed by attach or log
replay. Bounded inventory must acknowledge exactly one new attempt-unique wrapper
command before locks are released. The guest can run while acknowledgment is
being observed; this is launch acknowledgment, not a two-phase guest release.
Failure after spawning is conservatively quarantined, with no automatic retry
or success envelope. Exact implementation qualification is still required.

Synthetic executable tests are offline transport evidence only. Native execution
of the new runner remains unverified and requires an isolated controller; an
ordinary worktree or the operator host is not that environment. Existing native
CLI probes do not qualify the new runner or the complete launch integration.

Until integrated dispatch tests and native qualification pass, this remains a
candidate rather than a delivered launch barrier. In particular,
an old generated configuration must never turn preparation failure into success.
