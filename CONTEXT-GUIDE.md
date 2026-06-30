---
title: "Agent Context Loading Guide"
description: "Compact routing document for AI agents — read this FIRST to determine which documents to load for your current task"
status: canonical
tier: 1
load_priority: "always"
audience: "all"
keywords: ["context", "loading", "routing", "index"]
related_files: ["AGENTS.md", "docs/CODING_PRACTICES.md"]
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
| `docs/CODING_PRACTICES.md` | Secure coding: input validation, secrets, dependencies, architecture, TDD, SOLID |
| `~/.agentic-coding-playbook/docs/CODING_STANDARDS_COMPACT.md` | **Code generation shortcut** — load INSTEAD of full CODING_PRACTICES.md for routine code tasks (from the playbook, cloned into the sandbox by the `agentic-coding-playbook` kit) |

## Tier 2 — Load When Task Matches

| Document | Load When Task Involves |
|----------|------------------------|
| `docs/QUICKSTART_SBX.md` | Setting up SBX, running agents, USAi configuration, first-time setup |
| `docs/KNOWN_FAILURE_MODES.md` | Debugging SBX/USAi issues, troubleshooting, error diagnosis |
| `docs/adr/0001-sbx-usai-agent-execution-architecture.md` | Understanding SBX architecture decisions, isolation rationale |

## Tier 3 — Reference Only

Load only when the specific activity is being performed.

| Document | Load When |
|----------|-----------|
| `opencode.jsonc` | Configuring OpenCode, model selection, provider setup |
| `checklists/pre-deployment.md` | Running pre-deployment checklist |
| `docs/risk-assessment.md` | Performing a risk assessment |

## Typical Task Profiles

| Task Type | Load |
|-----------|------|
| Code generation/review | Tier 1 only |
| SBX + USAi setup | Tier 1 + QUICKSTART_SBX.md |
| Debugging agent issues | Tier 1 + KNOWN_FAILURE_MODES.md |
| Pre-deployment review | Tier 1 + checklist |
