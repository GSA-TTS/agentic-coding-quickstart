---
title: "Agent Context Loading Guide"
description: "Compact routing document for AI agents — read this FIRST to determine which documents to load for your current task"
status: canonical
tier: 1
load_priority: "always"
audience: "all"
keywords: ["context", "loading", "routing", "index"]
related_files: ["AGENTS.md"]
review_cycle: "quarterly"
---

# Agent Context Loading Guide

> **Purpose:** Minimize token usage while ensuring compliance. Load only what your task requires.

## Loading Rules

1. **Always load** this file and the Tier 1 docs below
2. **Match keywords** from your task to the document triggers below
3. **Load on demand** — do NOT load all documents preemptively
4. **Security is non-negotiable** — when in doubt about a security requirement, load the relevant doc rather than guessing

## Tier 1 — Always Load

These define the behavioral contract. Load for **every task**.

| Document | What It Covers |
|----------|----------------|
| `AGENTS.md` | Agent rules: permissions, prohibitions, data handling, identity, meta-constraints |
| [`CODING_PRACTICES.md`](https://github.com/GSA-TTS/agentic-coding-playbook/blob/main/docs/CODING_PRACTICES.md) (GSA agentic-coding-playbook) | Secure coding: input validation, secrets, dependencies, architecture, TDD, SOLID |
| `~/.agentic-coding-playbook/docs/CODING_STANDARDS_COMPACT.md` | **Code generation shortcut** — load INSTEAD of the full CODING_PRACTICES.md for routine code tasks (from the playbook, delivered into the sandbox by the `agentic-coding-playbook` kit) |

## Tier 2 — Load When Task Matches

| Document | Load When Task Involves |
|----------|------------------------|
| `docs/howto/acq.md` | Setting up a sandbox with `acq`, running agents, USAi configuration, first-time setup (backend-neutral; default backend is msb) |
| `docs/CONCEPTS.md` | Cross-cutting, backend-neutral concepts (e.g. mounting multiple workspaces) |
| `docs/BACKEND_GUIDE.md` | Choosing between backends (msb, sbx); per-backend strengths, tradeoffs, and configuration |
| `docs/howto/msb.md` | msb-specific setup and mechanics (host readiness, egress tiers, images, ssh-agent forwarding) — the default backend |
| `docs/howto/sbx.md` | sbx-specific setup and mechanics (proxy secrets, `set-custom`, policy, `--clone`) — the sbx alternative to the default |
| `docs/KNOWN_FAILURE_MODES.md` | Debugging sandbox/USAi issues, troubleshooting, error diagnosis (both backends) |
| `docs/adr/0010-acq-pluggable-backends.md` | Understanding the acq pluggable-backend architecture |
| `docs/adr/0011-msb-backend-and-neutral-kits.md` | Understanding the msb backend and neutral kits |
| `docs/adr/0001-sbx-usai-agent-execution-architecture.md` | Understanding sbx architecture decisions, isolation rationale |

## Tier 3 — Reference Only

Load only when the specific activity is being performed.

| Document | Load When |
|----------|-----------|
| `checklists/pre-deployment.md` | Running pre-deployment checklist |
| `docs/risk-assessment.md` | Performing a risk assessment |

## Typical Task Profiles

| Task Type | Load |
|-----------|------|
| Code generation/review | Tier 1 only |
| Sandbox + USAi setup (default/neutral) | Tier 1 + docs/howto/acq.md (+ docs/BACKEND_GUIDE.md to choose a backend) |
| msb-specific setup | Tier 1 + docs/howto/msb.md |
| sbx-specific setup | Tier 1 + docs/howto/sbx.md |
| Debugging agent issues | Tier 1 + KNOWN_FAILURE_MODES.md |
| Pre-deployment review | Tier 1 + checklist |
