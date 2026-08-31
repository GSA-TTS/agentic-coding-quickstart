---
title: "Backend-Neutral Disposable Primary Workspace (--clone)"
status: accepted
date: 2026-08-28
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["AC-6", "CM-3", "SA-8", "SC-7"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0027: Backend-Neutral Disposable Primary Workspace (`--clone`)

## Context and Problem Statement

On sbx, `sbx create --clone` runs the agent on a private in-container clone of
the host repository: the agent branches, commits, and experiments without
touching the host checkout, and finished work comes back through an explicit
`git fetch sandbox-<name>` on the host. On msb, workspaces are direct host
mounts (rw or `:ro`) — the agent edits the real checkout. For teams whose
workflow depends on a disposable primary, that gap is the reason they cannot
leave sbx ([ADR-0011](0011-msb-backend-and-neutral-kits.md) pins it as
load-bearing).

Disposable working copies are the industry default for agent sandboxes: cloud
agents (Codex cloud, Cursor cloud agents, Google Jules) clone per task into a
fresh VM with an explicit git crossing back, and sandbox platforms bring code in
by clone or upload rather than mounting a host checkout rw. sbx's distinctive
contribution is cloning from the *local* host checkout (unpushed branches
included, no forge round-trip). That capability is worth neutral vocabulary
rather than remaining an sbx exclusive — the same trajectory as `--image`
([ADR-0022](0022-neutral-image-override.md)) and `volumes:`
([ADR-0023](0023-neutral-volumes-kit-vocabulary.md)).

## Decision Drivers

- **One neutral knob** — `--clone` (or `ACQ_CLONE=1`) works on both backends
  with identical UX: same flag, same `sandbox-<name>` fetch-back remote, same
  rm-time warning.
- **No upstream dependency** — land without waiting for msb to grow a native
  clone feature; if it does, the adapter can switch behind the same flag.
- **The crossing back must be inert data** — recovery via `git fetch` transfers
  hash-verified objects only; hooks and config never cross (they are
  host-executed code paths).
- **The copy must be physical** — a same-filesystem `git clone` hardlinks
  object files by default; an agent with write access to a hardlinked scratch
  `.git` could modify inodes shared with the real repo's object store.

## Considered Options

1. **Managed host-side scratch clone (msb emulation), sbx passthrough.**
   Chosen. `git clone --no-hardlinks` into acq-managed state, mounted rw as the
   primary; recovery and lifecycle mirror sbx exactly.
2. **In-guest clone from an `:ro` mount.** Closer to sbx's placement (the
   working copy dies with the sandbox), but recovery is worse: the host cannot
   fetch from guest storage, so commits leave via push (blocked today by the
   msb `:22` egress gap, GSA-TTS/agentic-coding-quickstart#402) or via bundles
   copied out. Possible later refinement.
3. **CoW overlay mount (OpenHands-style `:overlay`).** Perfect state fidelity
   including ignored files — but merge-back is diff-shaped rather than
   git-native, and ignored-state fidelity is exactly the contamination the git
   clone avoids.
4. **Clone-from-forge in-guest (the Codex/Jules pattern).** Works over HTTPS
   today, but loses uncommitted local branches and adds a forge round-trip —
   not a substitute for local-first workflows.

## Decision Outcome

**Chosen: Option 1.** `--clone` becomes acq-owned neutral vocabulary, extracted
at dispatch (mirroring `--image`) and never forwarded raw to a backend CLI.
`ACQ_CLONE=1` is the env equivalent; like `--image`, the option applies at
**create only** — a re-attach prints a note and ignores it.

### Per-backend mapping

| Backend | Mechanism |
|---------|-----------|
| sbx | re-injects the native `sbx create --clone` |
| msb | emulates: managed host-side scratch clone (below) |

### msb emulation

At create, when `--clone` is requested:

1. The **primary** workspace must be a git repository **root** (a
   subdirectory or non-repo path fails the create before any backend call).
   Secondaries are unchanged (`:ro` and direct mounts as before).
2. `git clone --no-hardlinks` the primary into
   `$XDG_STATE_HOME/acq/clones/<sandbox>/<repo>` (root overridable via
   `ACQ_STATE_DIR` / `ACQ_MSB_CLONES_DIR`). `--no-hardlinks` is load-bearing
   (see Decision Drivers).
3. Mount the scratch rw **at the original workspace's absolute path in the
   guest** (verified msb 0.6.15 mounts `--volume src:dst` with `src != dst`),
   so the agent's starting directory, kit behavior, and docs are identical to a
   non-clone run.
4. Register a `sandbox-<name>` remote in the host checkout pointing at the
   scratch dir; `git fetch sandbox-<name>` pulls agent branches back as
   hash-verified objects.
5. `acq rm` warns when the scratch holds commits absent from the host's object
   store, then deletes the scratch and removes the remote (same
   gone-after-remove-attempt rule as derived volumes, ADR-0023). A failed
   `msb create` cleans up its own fresh scratch immediately.

### Deliberate divergences from sbx (proposed as the better default)

A git clone carries **committed state only**:

- **No gitignored/untracked files.** sbx's `--clone` copies gitignored files,
  which is how host-side build state (e.g. a macOS-initialized Postgres cluster
  in `.devenv/state`) poisons sandboxes — a documented trap. Workflows that
  need a specific ignored file (`.env`) copy it in explicitly with `acq cp`;
  that doc story is now identical on both backends.
- **No uncommitted changes to tracked files.** sbx's copy-based clone carries a
  dirty working tree; the msb emulation does not. Create prints a notice when
  the host tree is dirty: commit first, or `acq cp` the files in.

### Trade-off stated openly

The scratch clone lives on **host disk** (unlike sbx's in-guest clone), so
agent writes land on the host — but confined to the acq-managed directory,
which is disposable by construction and never executed by the host's git (a
fetch transfers objects, not hooks or config).

## Consequences

- **Positive:** disposable-primary workflows work identically on both backends;
  the last load-bearing sbx exclusive named by ADR-0011 becomes neutral
  vocabulary; recovery UX (`git fetch sandbox-<name>`) is backend-invariant.
- **Negative / trade-off:** two documented state-fidelity divergences from sbx
  (above), both git-native and both with the same `acq cp` escape hatch; host
  disk holds a second physical copy of the repo per cloned sandbox.
- **Known limitation (accepted):** the scratch existence check and its `mkdir`
  are not atomic, so two concurrent creates with the same name can race, and
  the losing invocation's cleanup can delete the winner's fresh scratch. This
  requires the operator to race themselves with identical names in a
  single-operator interactive CLI, and msb's own name registration rejects the
  duplicate create anyway — accepted (surfaced by adversarial review) rather
  than complicating the claim into an atomic `mkdir` with EEXIST handling.
- **Scope:** applies at sandbox **creation** only; `acq stop`/restart preserve
  the scratch and remote; only `acq rm` (or a failed create) cleans them up.
