---
title: "acq Concepts"
description: "Backend-neutral concepts for working with acq sandboxes (workspaces, mounts)"
status: canonical
tier: 2
last_updated: "2026-08-21"
audience: "developers"
keywords: ["acq", "concepts", "workspace", "mount", "backend-neutral", "sbx", "msb"]
related_files: ["docs/QUICKSTART.md", "docs/BACKEND_GUIDE.md", "docs/adr/0010-acq-pluggable-backends.md", "docs/adr/0011-msb-backend-and-neutral-kits.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# acq Concepts

Cross-cutting concepts for working with `acq` sandboxes. These apply to **both**
backends (sbx and msb) because `acq` presents one neutral interface over both.
For per-backend strengths, tradeoffs, and caveats, see the
[Backend Guide](BACKEND_GUIDE.md).

---

## Multiple Workspaces

You can mount additional directories alongside the primary workspace when
creating a sandbox. This is useful when you need to reference multiple repos or
folders from one sandbox session — for example, editing an app while reading a
reference library or the playbook.

`acq` supports the multi-workspace positional list on **both** backends with
identical syntax, so this is the canonical, backend-neutral way to mount extra
directories.

### Syntax

```bash
acq run <agent> <primary-workspace> [extra-workspace][:ro] ...
# e.g.
acq run opencode ~/projects/app ~/projects/lib:ro
```

- **Primary workspace** — the first path. The agent starts here, and it is
  mounted read/write.
- **Extra workspaces** — additional paths the agent can access. Each mounts at
  its **absolute host path** inside the sandbox (e.g. `~/projects/lib` appears at
  `/Users/you/projects/lib`), matching across backends.
- **`:ro` suffix** — mounts that extra workspace read-only. Recommended for
  reference repos so the agent cannot modify them.
- **Mounts are fixed at creation** — you cannot add or remove workspaces from an
  existing sandbox. To change mounts, remove the sandbox (`acq rm <name>`) and
  recreate it with the new paths.

The same positional list works with `acq create` when you want to name a sandbox
without attaching immediately:

```bash
acq create <agent> <primary-workspace> [extra-workspace][:ro] ...
```

### Example: app repo + read-only reference

```bash
# Primary: your app (read/write)
# Secondary: the playbook, read-only reference
acq run opencode ~/projects/my-app ~/projects/agentic-coding-playbook:ro
```

The agent can edit `~/projects/my-app` and read from
`~/projects/agentic-coding-playbook` without risk of modifying the reference
content.

### Security recommendation

Prefer read-only (`:ro`) mounts for secondary workspaces unless the agent
genuinely needs write access. This limits accidental modification and reduces
the blast radius of agent errors.

> [!WARNING]
> Mounted directories expose **all content** to the agent, including `.env`
> files, `.git/config` (which may contain tokens), and any secrets in the
> mounted path. Mount only what the agent needs. Prefer selective, targeted
> mounts over mounting parent or home directories.

### Backend caveats

The syntax and semantics above are identical across backends, but each backend
has a few mechanics worth knowing. Rather than duplicate them here, see the
[Backend Guide](BACKEND_GUIDE.md) for:

- **msb** — each host workspace path must already exist (msb does not create the
  host mount path), and symlinked host paths (notably macOS `$TMPDIR`) are
  canonicalized to their real path before mounting.
- **sbx** — the `--clone` remote-clone lifecycle interacts with multi-workspace
  mounts; see the [sbx how-to guide](QUICKSTART_SBX.md) for the sbx-specific
  clone story.
