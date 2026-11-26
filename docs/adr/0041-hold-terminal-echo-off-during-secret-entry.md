---
title: "Hold terminal echo off throughout secret entry"
description: "Fail closed on terminal setup failure and restore settings across input exit paths"
status: proposed
tier: 2
date: 2026-11-17
decision_makers: ["Bret Mogilefsky"]
category: security
nist_controls: ["IA-5", "SC-28", "SI-17"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
related_files: ["acq.backends/secret-store.sh", "docs/KNOWN_FAILURE_MODES.md"]
---

# ADR-0041: Hold terminal echo off throughout secret entry

## Context and Problem Statement

Per-character silent reads restore echo between reads, allowing a fast paste to
echo at the terminal. The old helper also fell back to visible input on failure.
Pipe-only tests cannot observe this terminal behavior.

## Decision Drivers

- Secret input must not become visible when secure input setup fails.
- The ready prompt must follow successful echo suppression.
- Preserve the user's terminal settings on completion and interruption.

## Considered Options

1. Keep per-character silent reads: rejected because echo toggles between reads.
2. Use a single silent line read: safe but loses masked feedback and editing.
3. Hold echo off around masked input in a cleanup-owning subshell: chosen.

## Decision Outcome

Save terminal state, install subshell-local cleanup and signal traps, then disable
echo and canonical editing before displaying the prompt. Read characters without
toggling echo; preserve signal handling, backspace editing and masked feedback.
Abort on EOF, Ctrl-D or setup failure; never fall back to visible input. Restore
the exact saved settings before returning to the caller. Piped secret input
continues through the existing non-interactive path.

## Consequences

The helper needs the host's existing `stty` utility. Failure is explicit rather
than accepting a credential insecurely. Pseudo-terminal regressions use synthetic
text and exercise paste, typing, editing, signals and setup failure. SIGKILL and
terminal destruction cannot be trapped; a terminal left altered may require
`stty sane`. No new runtime dependency or credential storage mechanism is added.
