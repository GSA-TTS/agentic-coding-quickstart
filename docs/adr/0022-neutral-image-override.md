---
title: "Backend-Neutral Custom Base Image (--image / ACQ_IMAGE)"
status: accepted
date: 2026-08-20
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-6", "SA-8", "SA-15", "SR-3"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0022: Backend-Neutral Custom Base Image (`--image` / `ACQ_IMAGE`)

## Context and Problem Statement

The `acq` neutral adapter contract ([ADR-0010](0010-acq-pluggable-backends.md))
passes an *agent*, *workspace paths*, *kits*, *secrets*, and *ports* to each
backend — it deliberately does **not** carry a base image. As a result, choosing
a custom base image has been per-backend and asymmetric:

- **msb** already exposes `ACQ_MSB_IMAGE` — it runs a plain OCI image directly
  and layers the kits on top ([ADR-0011](0011-msb-backend-and-neutral-kits.md)).
- **sbx** has **no** `acq`-level knob. Its agent templates supply the image via
  Docker's template mechanism; a user who wanted a custom template had to reach
  around `acq` to `sbx create --template` themselves.

A user asked for the straightforward, backend-agnostic thing: "let me point
`acq` at a custom base image, once, and have it work regardless of backend." No
neutral vocabulary existed for that.

## Decision Drivers

- **One neutral knob** — a single `--image` / `ACQ_IMAGE` that both backends
  honor, so a workspace/team can pin a base image without caring which backend
  is active.
- **No regression to the existing per-backend knob** — `ACQ_MSB_IMAGE` and the
  msb prerequisite/synthesis logic must keep working unchanged.
- **Portability of the image itself** — the same image reference should be
  usable on both backends, which means documenting one image *contract* that
  satisfies the stricter of the two.
- **Least surprise on precedence** — a user who set a backend-specific var
  deliberately should not have it silently overridden by the neutral one.
- **Reversibility / auditability (CM-3, CM-6)** — the choice must be visible
  (a one-time notice) and confined to sandbox creation.

## Considered Options

1. **Neutral `--image` / `ACQ_IMAGE`; msb → `ACQ_MSB_IMAGE` path, sbx → `sbx
   create --template <ref>`.** Chosen. sbx's `--template` already accepts any OCI
   image reference that satisfies the published base-image contract, so no
   generated artifact is required.
2. **Neutral knob on msb only; error on sbx.** Rejected — it contradicts the
   stated "backend-agnostic" goal and leaves sbx users where they started.
3. **Synthesize a throwaway sbx *sandbox kit* (`kind: sandbox`,
   `sandbox.image: <ref>`) at run time and inject it via `--kit`.** Rejected as
   heavier with no benefit over `--template`: sandbox kits define a whole agent
   (image + entrypoint + command), the neutral→sbx translator today only emits
   *mixin* kits, and a sandbox kit would collide with `acq`'s four built-in mixin
   kits. `--template` is the purpose-built primitive.

## Decision Outcome

**Chosen: Option 1.** Add a backend-neutral image selector surfaced two ways:

- **CLI flag:** `--image <ref>`, accepted BOTH as a pre-subcommand global
  (`acq --backend msb --image <ref> create shell …`) and after the run/create
  subcommand (`acq create shell --image <ref> <path>`). Either position sets the
  same value; `--image` is acq-owned and is never forwarded to the backend CLI
  (neither `sbx` nor `msb` accepts a bare `--image`).
- **Environment:** `ACQ_IMAGE=<ref>`.

Both are resolved by a single helper, `acq_resolve_neutral_image` (in
`acq.backends/common.sh`), so the precedence rule lives in one place.

### Precedence

`ACQ_MSB_IMAGE` backend var **>** `--image` flag **>** `ACQ_IMAGE` env **>**
agent-derived backend default.

When a backend-specific var is **also** set (today only `ACQ_MSB_IMAGE`), the
**most-specific backend var wins**, and `acq` prints a one-time notice so the
override is not silent. Rationale: a user who set `ACQ_MSB_IMAGE` did so
deliberately for that backend; the neutral knob is the broader default and
should yield to the narrower one.

For msb, the agent-derived default uses the same sandbox-template naming
convention as sbx for known agent tokens:
`docker.io/docker/sandbox-templates:<agent>-docker`. Two agents are exceptions —
Docker publishes them under a longer product name than the short acq token, so
`claude` maps to `claude-code-docker` and `cursor` to `cursor-agent-docker` (all
other known agents follow `<agent>-docker` verbatim). If that derived image is
not found, acq retries once with
`docker.io/docker/sandbox-templates:shell-docker`. Explicit image failures do not
fall back silently.

### Per-backend mapping

| Backend | Neutral image maps to | Mechanism |
|---------|-----------------------|-----------|
| msb | `ACQ_MSB_IMAGE` (if that var is unset) | trailing OCI image positional on `msb create` |
| sbx | `sbx create --template <ref>` | injected **only** if the user did not already pass their own `--template`/`-t` |

**Local (registry-less) images.** `msb create` treats the image argument as a
**registry reference** and pulls it (policy `if-missing` by default) — it does
**not** read the host container engine's local image store. A locally-built tag
such as `localhost/foo:test` therefore fails (`msb` tries to reach a registry at
`localhost`). To use a local image on msb, import it into msb's own cache first
(`msb image load -i <tar> -t <ref>`, the analogue of sbx's `sbx template load`)
and create with pull disabled. acq exposes that pull policy as **`ACQ_MSB_PULL`**
(`always` | `if-missing` | `never`), forwarded to `msb create --pull`; set
`ACQ_MSB_PULL=never` alongside a pre-loaded `--image`. Registry-hosted images
(Docker Hub, ghcr.io, …) need no such step — the default pull path applies.

### The portable base-image contract

To keep a single image reference usable on **both** backends, an `--image`
target should satisfy the **stricter (sbx) form** of the base-image contract, as
published in the Docker Sandboxes kit reference
(<https://docs.docker.com/ai/sandboxes/customize/kit-reference/#sandbox-block> —
"The agent's container image must provide"):

- A non-root **`agent` user at UID 1000** with passwordless sudo.
- A **`/home/agent`** home directory owned by `agent`.
- **HTTP proxy env** (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) preserved across
  sudo.
- The four kit prerequisites present in the image: **`node`, `git`, `curl`,
  `update-ca-certificates`** (plus **`socat`** if git commit signing / ssh-agent
  forwarding is used).
- The **agent binary** baked in, or installable at provision (for `opencode`,
  `acq` runs `npm install -g opencode-ai` on msb; sbx's agent templates bake it).

The image does **not** have to be built `FROM docker/sandbox-templates:shell`
— it only has to *meet* the contract. Building `FROM
docker/sandbox-templates:shell` (or `shell-docker`) is the recommended shortcut
because it satisfies every point above for free.

**Build-time note (`RUN` runs as `USER=agent`).** Because the contract sets the
image `USER` to the non-root `agent`, a Dockerfile `RUN` step in a *derived*
image also runs as `agent`. Writes to root-owned paths (e.g. `/etc`) therefore
fail with `Permission denied` unless you `sudo` (the contract grants `agent`
passwordless sudo) or temporarily `USER root`. Prefer writing under the
agent-owned `/home/agent` where no elevation is needed. The
`scripts/verify-image-override` marker follows this rule (writes to
`/home/agent/.acq-image-marker`, no sudo) so it works whether a custom base
leaves `USER=agent` or `USER=root`.

**One documented divergence (a relaxation, not a conflict):** `acq`'s msb adapter
addresses the `agent` user **by name**, not by the literal UID 1000, and will
*synthesize* the user/sudo/proxy contract on a plain-OCI base that lacks it
([ADR-0011](0011-msb-backend-and-neutral-kits.md)). So an image that is portable
by the sbx rule above always works on msb; an image that works only on msb (e.g.
`agent` at a non-1000 UID, or no `agent` user at all) is **not** guaranteed on
sbx. Authoring to the sbx form keeps the reference portable.

### sbx operational caveats (surfaced, not automated)

`acq` prints a one-time notice on sbx when a neutral image is injected, covering
the three things `acq` cannot do for the user:

- The **agent token must match the image's agent variant** (e.g. run `opencode`
  against an `opencode`-derived template), or sbx warns and the sandbox may not
  work.
- A **private or non-Docker-Hub image** needs pull credentials stored first:
  `sbx secret set --registry <host> …`.
- A **locally-built image** that is not in a registry must be imported first:
  `sbx template load <tar>` (the tar can come from `docker save` **or** `podman
  save`).

### Registry-auth failure messaging

When a custom `--image` pull is **denied** (missing/incorrect credentials), the
backend CLI prints its own raw error (e.g. `unauthorized`). On top of that, `acq`
adds a **targeted, registry-agnostic** remediation hint derived from the *actual*
image reference — not a hardcoded list of hosts:

- `acq_registry_auth_hint` (in `acq.backends/common.sh`) parses the image's
  registry host via `_acq_image_registry_host` (a host is a leading component with
  a `.`, a `:port`, or exactly `localhost`; bare Docker Hub short names carry no
  host) and prints the correct command for the failing backend:
  `msb registry login <host> …` or `sbx secret set --registry <host> …`.
- For a **local** (registry-less) image it instead points at the import path
  (`msb image load` + `ACQ_MSB_PULL=never`, or `sbx template load`), and does not
  emit a spurious "login to localhost" line.
- Both backends' create-failure paths call this, so the sbx path is no longer
  limited to the backend's bare error and the msb path is no longer limited to a
  few hardcoded hosts.

## Consequences

- **Positive:** one neutral image knob; sbx gains custom-template support through
  `acq` for the first time; the existing `ACQ_MSB_IMAGE` path and msb synthesis
  are untouched; precedence is explicit and audited by a notice.
- **Negative / trade-off:** the neutral knob cannot paper over the genuine
  backend difference in the image contract (UID 1000 on sbx). We document one
  portable contract rather than hide the difference.
- **Scope:** applies at sandbox **creation** only, matching where both backends
  accept an image; it does not retro-fit a running sandbox.

## Validation

- **Offline (`scripts/test-acq-bats`, no Docker/KVM):** asserts `ACQ_IMAGE` and
  `--image` reach `msb create` as the image positional; that `ACQ_MSB_IMAGE`
  wins over `ACQ_IMAGE` (with the notice); that a neutral image injects `sbx
  create --template <ref>`; that a user-supplied `--template` is not
  double-injected; and that with no image set, sbx omits `--template` while msb
  derives an agent-specific sandbox-template image and falls back to
  `shell-docker` only when that derived image is not found.
- **Live (`scripts/verify-image-override`, host with a sandbox-capable
  runtime):** builds a tiny image `FROM docker/sandbox-templates:shell` (via
  `docker` or `podman` — Docker Desktop is not required), imports it into each
  installed backend's cache (`sbx template load` for sbx; `msb image load` for
  msb, then `--image` with `ACQ_MSB_PULL=never`), creates a throwaway sandbox
  with `--image`, and asserts the sandbox is exec-ready, the kits applied, and
  the custom image actually took effect (a unique marker baked into the image).
  A backend whose runtime is absent is `BLOCKED`/skipped, not failed — mirroring
  the [ADR-0011](0011-msb-backend-and-neutral-kits.md) live-validation cadence.

## Links

- [ADR-0010: acq pluggable backends](0010-acq-pluggable-backends.md) — the neutral
  adapter contract this extends.
- [ADR-0011: msb backend and neutral kits](0011-msb-backend-and-neutral-kits.md)
  — `ACQ_MSB_IMAGE`, the msb base-image contract, and the user/sudo synthesis.
- Docker Sandboxes base-image requirements:
  <https://docs.docker.com/ai/sandboxes/customize/kit-reference/#sandbox-block>
- Docker Sandboxes custom templates:
  <https://docs.docker.com/ai/sandboxes/customize/templates/>
- Related code: `acq`, `acq.backends/agents.sh`, `acq.backends/common.sh`,
  `acq.backends/sbx.sh`, `acq.backends/msb.sh`, `docs/BACKEND_GUIDE.md`.
