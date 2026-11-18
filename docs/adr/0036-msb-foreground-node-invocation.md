---
title: "Use a fixed shell for foreground MSB Node kit commands"
description: "Narrow, measured workaround for foreground Node invocation latency"
status: proposed
tier: 2
date: 2026-10-22
last_updated: "2026-10-22"
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-3", "SA-11", "SI-10"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
related_files: ["acq.backends/msb.sh", "scripts/probe-msb-node-startup", "test/bats/81-msb-node-invocation.bats"]
---

# ADR-0036: Use a fixed shell for foreground MSB Node kit commands

## Context and problem statement

A host macOS microbenchmark ran the same tiny Node script in an existing MSB
sandbox as `agent`, with `HOME=/home/agent`, without a per-call instrumentation
wrapper or PTY. Direct execution took 5.11955875 and 4.70029637 seconds. The fixed
shell form took 0.15991925 and 0.15972667 seconds. The second pass reversed the
order, and all four calls produced the expected output. The root cause is
unconfirmed. These are invocation measurements, not a measured reduction in the
real USAi configuration merge (previously approximately 9.2 seconds).

## Decision drivers and considered options

- Preserve argument boundaries, user, environment, errors, and install markers.
- Limit the workaround to the command shape for which evidence exists.
- Direct `node` execution retains the observed latency.
- Wrapping every executable would extend beyond the evidence.
- `sh -c 'exec "$@"'` would replace the shell, but its performance has not been
  measured. The measured waiting-shell form is the initial candidate.

## Decision outcome

In `acq.backends/msb.sh`, foreground kit commands whose first argument is exactly
`node` use `sh -c '"$@"' sh node ...`. All arguments remain separate positional
parameters; no kit value is interpolated into shell source. Both install and
initFiles/startup exec paths share this launch helper. Install marker keys are
computed from the original argv before wrapping. The existing caller-owned
warning and marker-on-success behavior remains in effect.

Background startup commands retain their existing `nohup` lifecycle. Staged
startup scripts, other executables (including absolute Node paths and `env node`),
and user-facing `acq exec` retain their existing dispatch.

## Consequences and validation

The waiting shell adds a process; it preserves normal exit status and streams,
but live interruption/process-cleanup behavior must be checked on MSB before
acceptance. Offline regression tests exercise exact argv, user/environment flags,
error reporting, marker stability, and unchanged background dispatch.

Run the calibration on the host, against an existing running sandbox:

```bash
python3 scripts/probe-msb-node-startup EXISTING_SANDBOX
```

It retains a unique guest scratch directory and writes only timing/status metadata
under repository `tmp/`, not captured output or environment values. Its offline
tests run through `test/bats/81-msb-node-invocation.bats` in the standard suite.

Then run `python3 scripts/probe-msb-startup --phase-only WORKSPACE_DIRECTORY` on
the host to measure a real fresh startup and configuration merge. Live MSB cannot
run inside the development sandbox; these end-to-end and interruption checks
remain pending in the draft change request. Acceptance requires actual observed
output/configuration correctness, not just faster timings.

Rollback restores the two foreground call sites to direct `_acq_msb_cli exec`.
No dependency, secret binding, authorization, or network policy change is needed.
