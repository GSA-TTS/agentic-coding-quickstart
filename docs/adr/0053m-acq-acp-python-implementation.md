---
title: "acq acp in the Python implementation: stdio discipline and streaming launch"
status: proposed
date: 2026-11-13
decision_makers: ["John Jediny"]
category: architecture
nist_controls: ["AC-3", "AC-6", "CM-5", "SC-7", "SI-10"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0053m: `acq acp` in the Python implementation: stdio discipline and streaming launch

## Context and Problem Statement

ADR-0040 added `acq acp` to the Bash `acq`: a subcommand that runs a sandboxed
agent's Agent Client Protocol (ACP) server over raw stdin and stdout, so an IDE
such as Zed can use `acq` as an `agent_servers` command. That change was proposed
as a Bash patch and set aside, on the maintainers' word, until the Python
implementation (ADR-0046m, ADR-0047m) is in place. This ADR is the port. It
restates ADR-0040's four invariants for Python and records the decisions the port
had to make that the Bash text did not.

An ACP client keeps stdin open for the life of the session and reads JSON-RPC 2.0
frames from stdout. So three things that are harmless for `acq run` are faults
here: a byte of prologue text on stdout corrupts the stream, a prompt that reads
stdin steals a frame, and a backend `exec` that waits for stdin EOF or allocates a
terminal never delivers one.

## Decision

`acq acp AGENT PATH [create-args] [-- ACP_ARGS...]` and `acq acp NAME [-- ACP_ARGS...]`
are handled by `py-acq/src/acq_py/commands/acp.py`. It takes the same arguments as
`acq run` and reuses `lifecycle.run_run` for the create-or-re-attach work (the
lock, the kit heal, the credential check). It replaces only the final launch, by
a `launch` parameter that `run_run` passes to its two launch sites.

The four invariants, in their Python form:

1. **Stdout purity.** For the whole prologue, file descriptor 1 is `dup2`'d onto
   descriptor 2, and the real stdout is restored immediately before the launch
   (and on every other exit path). The redirect is at the descriptor level, not
   a swap of `sys.stdout`, so output from a child process cannot reach the
   client's stream. `--json` is refused with the usage envelope, because the
   JSON envelope and the protocol cannot share stdout.
2. **Non-interactive, fail closed.** `ACQ_NO_PROMPT=1` and `ACQ_UPDATE_CHECK=0`
   are set for the prologue and restored afterwards, and descriptor 0 is bound to
   the null device for the same span. The second is what actually protects the
   client's pipe: not every prompt site consults `ACQ_NO_PROMPT`. The provider
   credential gate in `lifecycle._provider_gate` asks when `_stdin_is_terminal()`,
   and that test is true when an IDE launches `acq` from a terminal. With
   stdin bound to the null device those prompts do not fire, and a missing key
   fails with the existing `acq secret set -g usai` remediation.
3. **Pipe-clean streaming, no PTY.** Each adapter gains `stream_command`:
   `msb exec --stream` and `sbx exec -i`, never `-t`. It runs as the unprivileged
   `agent` user in the recorded workspace with the session environment (git
   identity, forwarded ssh-agent socket, kit environment), as `exec` does.
4. **ACP entrypoint resolution.** `AGENT` runs `AGENT acp`. `shell` is not an ACP
   server and is refused with usage exit 2, as is a sandbox whose recorded agent
   is `shell`. Arguments after `--` that start with `-` extend the ACP command;
   any other first word replaces it, matching `acq run NAME -- CMD...`.

### Differences from ADR-0040

* The Bash text sets `ACQ_SESSION_KIND=acp` and branches inside
  `acq_backend_run`. The Python adapters have no such global; `stream_command` is
  an explicit entry point, which is also what the unit tests address.
* ADR-0040's validation names `opencode acp --cwd <workspace>`. OpenCode 2.0.30
  removed `--cwd` (KFM 53), and the Bash implementation already relies on the
  backend's `-w`. The Python launch does the same, so no `--cwd` is passed.
* ADR-0040 fast-paths an already-running, current sandbox past the kit heal. The
  Python `run_run` already heals on re-attach, and its behaviour there is
  qualified (ADR-0044m); this port does not add a second path. If reconnect
  latency matters, it is a separate change to `run_run`'s heal, not to `acp`.

## Consequences

* A change under `py-acq/src/acq_py/` is on the Tier-3 surface (ADR-0044m), so
  merging this expires the live qualification transcripts and needs a
  re-qualification run on the claimed cells. The change is kept to one new module,
  two new adapter functions, a keyword parameter on `run_run`, and the dispatch
  wiring, so the diff names what changed.
* `lifecycle.run_run`'s signature gains an optional `launch` argument. It is
  `None` for every existing caller, which keeps the default behaviour.
* The streaming contract is tested in `py-acq/tests/test_acp.py` at Tier 2, against
  file descriptors. The vector harness cannot yet seed a host-authoritative state
  record, so Tier 1 covers only the refusals that need none
  (`cli/acp-shell-refused`, `cli/acp-unknown-target`, `cli/acp-json-refused`).
  A live check that the real `msb exec --stream` and `sbx exec -i` carry a full
  ACP exchange is Tier 3 and has not been run for this ADR.

## Alternatives considered

* **Duplicate the prologue in `acp.py`** rather than parameterize `run_run`. It
  keeps `lifecycle.py` untouched but copies the create, lock and heal logic, which
  would then drift. Rejected.
* **Swap `sys.stdout` for `sys.stderr`** rather than `dup2`. Simpler, but a
  subprocess that inherits descriptor 1 still writes to the client's stream.
  Rejected.
* **Rely on `ACQ_NO_PROMPT` alone.** Insufficient, as invariant 2 explains.

## Verification

`py-acq/tests/test_acp.py` (29 tests) covers each invariant, including a test
that holds a pending answer on a real pseudo-terminal behind descriptor 0 and
checks it is neither read nor prompted for. Four deliberate breakages (stdin not
bound, fd 1 not redirected, prompts not disabled, `--stream` dropped) each fail a
named test.
