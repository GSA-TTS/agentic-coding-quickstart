---
title: "Ensure an OCI container engine in msb sandboxes via rootless podman, not docker-in-docker"
status: accepted
date: 2026-08-11
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-6", "CM-7", "SA-8", "SA-15", "SC-7", "SI-10"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0020: Ensure an OCI container engine in msb sandboxes via rootless podman

> **Revision note (2026-08-11, pre-merge, no PR yet):** This ADR originally chose
> **rootful** podman to avoid a create-time download dependency on the rootless
> prerequisites (`uidmap`, `passt`). Once we had a working implementation, that
> premise did not hold: the adapter *already* installs `podman podman-compose
> fuse-overlayfs` from the OS mirror at provision, so the rootless prereqs are two
> more packages from the *same mirror in the same install step* — not a new
> dependency class. Meanwhile rootful required a `sudo`-wrapping `docker` alias and
> produced a rootful/rootless probe mismatch (containers ran as root inside the
> VM, and the verifier had to probe via sudo). We therefore **reversed the decision
> to rootless** and revised this ADR in place (the branch had never merged). The
> superseded rootful reasoning is preserved under *Alternatives considered*.

## Context

Agents working inside an msb sandbox frequently need to run OCI images — pull
and `docker run` an image, or bring up a `docker-compose.yaml`. Just as the msb
adapter idempotently guarantees the base-image *contract* (an `agent` user,
`/home/agent`, passwordless sudo, proxy `env_keep`; see
[ADR-0011](0011-msb-backend-and-neutral-kits.md) and `_acq_msb_ensure_agent_user`),
we want to guarantee an OCI-run *capability* regardless of what the base image
brings.

The situation on the default image
(`docker/sandbox-templates:shell-docker`, an Ubuntu base) was investigated live
inside an msb sandbox:

- The **Docker CLI, compose v2 plugin, `dockerd`, `containerd`, and `runc` are
  all installed**, but msb's microVM init is `/init.krun` — **not** systemd or
  any service manager — so **nothing starts `dockerd`**. The Docker socket
  (`/var/run/docker.sock`) does not exist, and every `docker` command fails with
  `Cannot connect to the Docker daemon`.
- The sandbox **root filesystem is already an `overlay` mount**
  (`/.msb/rootfs/...`). Docker's default `overlay2` storage driver **cannot be
  stacked on an overlay root** without a dedicated lower-level filesystem —
  which is exactly why the msb project's own
  [docker-in-a-sandbox recipe](https://github.com/superradcompany/microsandbox/blob/main/docs/recipes/docker/docker-in-sandbox.mdx)
  boots the `docker:dind` image *as the sandbox entrypoint* and mounts a
  **disk-backed** named volume at `/var/lib/docker`.
- **`/dev/kvm` is absent** (no nested virtualization) — but that only rules out
  nested *VMs*, not containers, which run as ordinary `runc`/`crun` processes.
- The agent user has **passwordless sudo** (guaranteed by the base-image
  contract), and `/dev/fuse` is present.
- The kernel supports **unprivileged user namespaces** (`max_user_namespaces` is
  large, no restrictive `unprivileged_userns_clone` knob), and `/etc/subuid` +
  `/etc/subgid` already grant the `agent` user a `100000:65536` range — the
  prerequisites for **rootless** containers. The rootless *userland* tools
  (`newuidmap`/`newgidmap` from `uidmap`, `passt`/`slirp4netns` for networking)
  are **not** preinstalled, and `/dev/net/tun` is root-only (`crw------- root
  root`) — both fixable at provision.

So the bundled Docker is inert here, and the blessed way to make it work (the
dind recipe) is an *image/entrypoint* strategy that does not fit our adapter:
`acq` boots a general base image and launches the agent — it does not own the
sandbox entrypoint, and would have to (a) start `dockerd` itself post-boot and
poll the socket, (b) keep that daemon alive across every `msb start`/restart
(the same restart-durability problem [ADR-0017](0017-msb-create-time-startup-script-staging.md)
already wrestles with), and (c) provision a per-sandbox disk-backed
`--mount-named docker-data:/var/lib/docker:kind=disk` volume and tear it down.

## Decision

Provision **podman** at provision time as the OCI engine, run it **rootless as
the agent user**, and alias `docker` → `podman` so both `docker run …` and
`docker compose …` work inside the sandbox. Implemented as a new idempotent,
marker-gated step `_acq_msb_ensure_oci`, called from `acq_backend_provision`
right after `_acq_msb_ensure_agent_user`.

1. **podman over docker-in-docker.** podman is **daemonless** — each invocation
   forks `runc`/`crun` directly, so there is no socket to start, poll, or keep
   alive across restarts (eliminating the dind lifecycle problem entirely). It
   uses **`fuse-overlayfs`** (we have `/dev/fuse`) or `vfs` on the overlay root,
   so **no disk-backed volume** is required. It needs **no nested
   virtualization**. And it is CLI-compatible with docker for the
   run/build/compose workflows this targets.

   **Storage driver on an overlay root.** podman's default **kernel `overlay`**
   graph driver **cannot stack on msb's overlay root** — `podman info` fails with
   `'overlay' is not supported over overlayfs, a mount_program is required`. This
   applies to **both** rootful and rootless. The adapter therefore writes
   `/etc/containers/storage.conf` **before** the engine verify, selecting a driver
   that works on an overlay root:
   - **Preferred:** `overlay` + `mount_program = fuse-overlayfs` when
     `fuse-overlayfs` is installed (fast, thin-on-disk; msb provides `/dev/fuse`).
   - **Fallback:** `vfs`, which works everywhere with no extra package and no
     `/dev/fuse` (correct but disk-heavy — a full copy per layer). Used when
     `fuse-overlayfs` is unavailable, and as a last-resort retry (a **user-level**
     `~/.config/containers/storage.conf`) if the rootless verify still fails.
   The system file is honored by rootless podman as its lowest-precedence source.
   The adapter does not clobber an operator-provided `storage.conf` that already
   names a `driver`.

2. **Rootless, run as the agent user.** The package **install** runs as root
   (`msb exec -u 0`, needed to install), but the **engine runs rootless** as the
   unprivileged `agent`. Rootless needs four things the default image lacks,
   which the adapter provides at provision:
   - **`uidmap`** (`newuidmap`/`newgidmap`) — the setuid helpers that map the
     agent's `/etc/subuid`/`/etc/subgid` `100000:65536` range (already present).
   - **`passt` + `slirp4netns`** — rootless container networking backends.
   - **`/dev/net/tun` access** — root-only by default (`crw------- root root`);
     the rootless network backend must open it. The adapter **group-scopes** it to
     the agent (`chown root:agent`, `chmod 0660`) — see item 6.
   - **`/dev/fuse` access** — likewise root-only by default; the `fuse-overlayfs`
     storage driver (our preferred driver on the overlay root) must open it to
     mount image layers. Without it `podman info` still passes but `podman run`
     fails at mount time (`fuse: failed to open /dev/fuse: Permission denied`) —
     the exact info-OK-but-run-FAILS split first seen on the host. Group-scoped to
     the agent the same way — see item 6.

   These are installed from the **same OS mirror in the same `apt-get install`**
   as podman itself, so rootless adds **no new dependency class** over the engine
   we already download. Running rootless keeps containers **unprivileged even
   inside the microVM** (defense-in-depth), **aligns container/host UIDs** for
   bind mounts, and lets the agent invoke podman **directly** (no sudo wrapper,
   no rootful/rootless probe mismatch). Verified live: with the prereqs installed,
   a `driver="vfs"` (or fuse-overlayfs) storage config, and `/dev/net/tun` +
   `/dev/fuse` group-scoped, `podman info` and `docker run --rm docker.io/library/hello-world`
   both succeed **as the agent user** (`rootless=true`).

3. **Alias `docker` → `podman` (do not fix the bundled Docker).** A tiny exec
   wrapper is written to **`/usr/local/bin/docker`** (ahead of `/usr/bin` on the
   default PATH), shadowing the bundled-but-non-functional `/usr/bin/docker`. We
   never touch the base image's `/usr/bin/docker`. Because the bundled Docker CLI
   does not work here anyway (dead socket), shadowing it loses nothing and makes
   both `docker run` and `docker compose` route to the working podman engine.

   **The wrapper execs a plain `podman "$@"`** (no sudo): the engine runs rootless
   as the agent, so the agent invokes podman directly. This is why the
   `scripts/verify-backends` OCI check probes `docker info` **as the agent** (via
   `acq exec`, which already runs as the agent) — it exercises the real usable
   path (rootless prereqs + storage driver + alias) with no privilege escalation.

4. **`docker compose`, not `docker-compose`.** The standalone `docker-compose`
   CLI is deprecated in favour of the `docker compose` subcommand. With the alias
   in place, `docker compose …` becomes `podman compose …`, which dispatches
   through the installed **`podman-compose`** provider. So we install
   `podman podman-compose` (plus the storage/rootless prereqs, `ACQ_MSB_PODMAN_PKGS`)
   and do **not** ship a separate `docker-compose` binary. The goal is that
   `docker-compose.yaml` files work, not that the deprecated CLI name exists.

5. **Docker-Hub-first image resolution.** Stock podman resolves many unadorned
   short names to **quay.io** (e.g. `hello-world` → `quay.io/podman/hello`) and
   ships **no** default unqualified search registry, so `docker run nginx` does
   not "just work" the way Docker users expect. To reduce migration burden for
   users whose code assumes Docker Hub, the adapter writes system drop-ins:
   - `registries.conf.d/00-acq-docker-first.conf`:
     `unqualified-search-registries = ["docker.io"]` + `short-name-mode = "enforcing"`.
   - `registries.conf.d/01-acq-shortnames.conf`: `[aliases]` remapping
     `hello`/`hello-world` to `docker.io/library/hello-world` (a user drop-in
     override cleanly wins over the stock alias — no merge conflict).
   These are system-level so they apply to the rootless agent. This **deliberately
   diverges from stock podman**; it is a config-only change and Docker Hub's CDNs
   are in the balanced egress baseline (see Consequences).

   **Short-name mode defaults to `enforcing` (least-privilege / prompt-injection
   defense).** Because there is a **single** unqualified search registry
   (`docker.io`), unqualified names still resolve **deterministically** to Docker
   Hub — migration ergonomics are preserved. `enforcing` only fails **closed** on
   interactively-ambiguous short names instead of silently resolving them, so an
   injected `docker run nginx` on the prompt-injectable agent path cannot be
   silently substituted (typosquatting / image substitution). With one search
   registry, enforcing costs essentially no day-to-day ergonomics. Operators MAY
   opt into `permissive` (or `disabled`) via **`ACQ_MSB_SHORT_NAME_MODE`**; an
   invalid value warns and falls back to `enforcing` (fail-closed). Setting
   `permissive` is an explicit operator override that **removes** the
   typosquatting / image-substitution guardrail.

   > **Revision note (post PR #302 review).** The permissive default was
   > reconsidered after review: a 3-model consensus plus the reviewer recommended
   > **AGAINST** `permissive` as a federal-sandbox default, because it removes the
   > defense against image substitution / typosquatting for a prompt-injectable
   > agent. The default was changed to `enforcing`; `permissive` remains available
   > as an explicit opt-in.

6. **Idempotent + marker-gated + fail-soft, with an un-gated device-node
   grant.** The heavy install/config step returns early if the marker
   `/var/lib/acq/oci-ready` exists. It verifies **rootless** `podman info` (as the
   agent) before writing the marker. If the engine cannot be provisioned it
   **warns and returns 0** — provision continues, OCI is simply unavailable —
   mirroring the agent-install and prereq-check steps (§Failure Handling,
   `AGENTS.md`). Toggle off with `ACQ_MSB_ENSURE_OCI=0`.

   The device-node grants (`/dev/net/tun` for networking, `/dev/fuse` for
   fuse-overlayfs) are handled by a **separate `_acq_msb_grant_oci_devs` helper
   called on EVERY provision pass (before the install-marker gate) AND on restart
   (`acq_backend_start`)** — because `/dev` is a devtmpfs re-created at each boot,
   a grant baked behind the persistent marker would be lost after `msb start`. The
   helper is cheap, idempotent, and a best-effort no-op for any device that is
   absent or when `ACQ_MSB_ENSURE_OCI` is disabled. NOTE: because rootless
   `podman info` (the verify) does NOT open `/dev/fuse` but `podman run` does, the
   grant covering `/dev/fuse` must NOT be gated behind the `podman info` verify —
   omitting it caused a real host regression where the engine check passed but
   `docker run` failed at layer-mount time.

## Consequences

- **OCI-run capability is guaranteed** on the default image and any base with a
  supported package manager (apt-get/dnf/apk), without owning the entrypoint,
  managing a daemon lifecycle, or provisioning a disk-backed volume.
- **Depends on the OS package mirror being reachable at provision.** Unlike the
  npm-registry allow-rule (which had to be *added* because the registry was not
  otherwise reachable), the Ubuntu/Debian mirror hosts
  (`archive.ubuntu.com`, `ports.ubuntu.com` — this arch is arm64, so `ports` —
  `security.ubuntu.com`, `**.debian.org`, `launchpad.net`) are **already in the
  default balanced egress baseline** ([ADR-0018](0018-msb-balanced-egress-baseline.md)),
  so no new net-rule is needed under the default policy. With
  `ACQ_NETWORK_TIER=strict` (or the deprecated `ACQ_MSB_BALANCED_EGRESS=0`, which
  now maps to `strict`), or a custom base whose egress is otherwise
  narrowed, the mirror is unreachable and the step **fails soft** — chosen
  deliberately so an operator's explicit egress narrowing is respected rather
  than silently re-widened (the warning names the mirror hosts and the
  `ACQ_MSB_ENSURE_OCI=0` escape hatch).
- **Behavioral parity with Docker is high but not total.** podman's docker-CLI
  compatibility covers the run/build/compose workflows this targets; uncommon
  edge cases (Docker build-secret syntax, some compose v3 keys, `buildx`-specific
  features) may differ. Acceptable for agent workflows; the bundled Docker was
  non-functional here regardless.
- **Unadorned image names resolve to Docker Hub, not stock podman defaults.** The
  Docker-Hub-first drop-ins (Decision 5) mean `docker run nginx` / `hello-world`
  behave as Docker users expect, at the cost of a deliberate divergence from stock
  podman resolution. A user who wants stock behavior can remove/override the acq
  drop-ins with their own `~/.config/containers/registries.conf.d/*` (user config
  wins). Docker Hub's blob CDNs (`**.production.cloudflare.docker.com`,
  `**.production.cloudfront.docker.com`) are in the balanced egress baseline, so
  the default pull path is reachable; arbitrary other registries are not
  guaranteed reachable under the default policy.
- **Security posture (SC-7 / SI-10) — improved vs. the superseded rootful design.**
  No new external services; a configuration/adapter change (CM-2/CM-6/CM-7;
  SA-8/SA-15). `ACQ_MSB_PODMAN_PKGS` is charset-guarded (`[A-Za-z0-9._+ -]`)
  before it is interpolated into the root `sh -c`, so operator config cannot
  inject shell into the elevated install (SI-10). **Containers run rootless (as
  the agent) inside the microVM** — strictly less privilege than the superseded
  rootful design, which ran containers as root. The `/dev/net/tun` and
  `/dev/fuse` group-scopes to the agent are inside the microVM only (the sandbox
  is the security boundary per `AGENTS.md`), and are narrower than the
  world-writable alternative; they do not expand the host attack surface.
- **Adds a runtime package install to provision.** First provision on a fresh
  sandbox pays an `apt-get install` cost (now `podman podman-compose fuse-overlayfs
  uidmap passt slirp4netns`); the marker makes it a one-time cost per sandbox
  (skipped on restart / re-provision). The rootless prereqs come from the same
  mirror in the same step — no additional dependency class over the engine itself.

## Alternatives considered

- **Follow the msb docker-in-docker recipe (start `dockerd`, disk-backed
  `/var/lib/docker`).** Officially blessed and gives full Docker API fidelity,
  but it is an entrypoint strategy retrofitted poorly onto an adapter that boots
  a general base and runs an agent: it needs a post-boot daemon start + socket
  poll, a daemon kept alive across restarts, and a per-sandbox disk-backed volume
  with its own teardown. Rejected as materially more complex and stateful than
  podman for no benefit in the target workflows.
- **Rootful podman via the agent's passwordless sudo (the ORIGINAL, now
  SUPERSEDED decision).** The first version of this ADR chose rootful to avoid a
  create-time download of the rootless prerequisites (`uidmap`, `passt`). We
  reversed it because:
  - The premise did not hold: the adapter already downloads `podman
    podman-compose fuse-overlayfs` from the OS mirror at provision, so the
    rootless prereqs (`uidmap`, `passt`, `slirp4netns`) are two-to-three more
    packages from the *same mirror in the same install step* — not a new
    dependency class or failure mode.
  - Rootful forced a `docker` alias that shells through `sudo -n podman` and a
    rootful/rootless probe mismatch (the engine was provisioned/verified rootful
    as root, but agents and the verifier run unprivileged), which was the source
    of a real, subtle verifier failure and general fragility.
  - Rootful ran containers **as root** inside the microVM; rootless is strictly
    less privilege for the same capability.
  Rootless does require granting the agent access to `/dev/net/tun` and
  `/dev/fuse` for its network backend and fuse-overlayfs storage, but those are
  small, group-scoped, in-VM changes. Net: rootless removes complexity *and*
  improves the security posture, so rootful was rejected.
- **Do nothing when `dockerd` is present (literal task reading).** Would leave
  the default image's dead socket / broken `docker compose` as-is. Rejected: the
  bundled engine does not actually work under msb, so "present" is not "usable."
- **Always symlink/override in a way that shadows a working custom Docker.** We
  place the wrapper in `/usr/local/bin` and never remove `/usr/bin/docker`; an
  operator who bakes a genuinely working Docker into a custom `ACQ_MSB_IMAGE` can
  set `ACQ_MSB_ENSURE_OCI=0`.
- **World-writable device nodes (`chmod 0666` on `/dev/net/tun`, `/dev/fuse`).**
  Simpler than group-scoping, but broader than necessary. We chose `chown
  root:agent` + `chmod 0660` to scope device access to the agent.
- **Leave stock podman image resolution (document a user opt-in instead).**
  Lowest surprise vs. upstream podman, but leaves `docker run hello-world`/`nginx`
  hitting quay/failing for users migrating from Docker. Rejected in favour of the
  Docker-Hub-first default (Decision 5) to minimize migration burden; the behavior
  is documented and user-overridable.
- **`short-name-mode = "permissive"` as the DEFAULT (the ORIGINAL Decision 5).**
  The first version of this ADR shipped `permissive` so ambiguous short names
  resolve without prompting. Reconsidered after PR #302 review (a 3-model
  consensus plus the reviewer recommended against it) and **rejected as the
  default**: `permissive` removes the defense against image substitution /
  typosquatting on the prompt-injectable agent path (an injected
  `docker run nginx` could silently resolve to `docker.io/<attacker>/nginx`), and
  it yields **no DX benefit** here because the single `unqualified-search-registries
  = ["docker.io"]` entry already gives deterministic Docker-Hub resolution. The
  default is now `enforcing` (fail-closed on ambiguity); `permissive`/`disabled`
  remain available as an explicit operator opt-in via `ACQ_MSB_SHORT_NAME_MODE`.
- **Disk-backed named volume for container storage (the msb dind recipe's
  approach) instead of fuse-overlayfs — DEFERRED, uncertain payoff.** The msb
  [docker-in-sandbox recipe](https://github.com/superradcompany/microsandbox/blob/main/docs/recipes/docker/docker-in-sandbox.mdx)
  mounts a `--mount-named …:/var/lib/docker:kind=disk` ext4 volume so the engine's
  storage sits on a real filesystem, letting it use the **native kernel `overlay`**
  driver instead of fuse-overlayfs. Applied to our rootless design this could give
  native-overlay performance AND drop the `/dev/fuse` grant. We deferred it because:
  - **The performance payoff is unquantified.** fuse-overlayfs adds FUSE overhead,
    but for the target agent workflows (pull/build/run) it is unmeasured whether
    native overlay is meaningfully faster here; the current path is already
    verified working end-to-end.
  - **It adds a persistent, per-sandbox stateful artifact acq must own.** A named
    volume survives `msb rm` (the recipe calls out `msb volume rm` as a separate
    cleanup), so acq would take on volume create/reuse/GC lifecycle — reintroducing
    exactly the "per-sandbox disk-backed volume" statefulness we cited as a reason
    to avoid the dind recipe in the first place.
  - **Empirical unknowns.** Rootless podman's graphroot is under `$HOME`, not
    `/var/lib/docker`; whether native kernel overlay works rootless on that ext4
    mount without `/dev/fuse`, and whether `msb create` (not just `msb run`)
    threads `--mount-named …kind=disk`, are unverified and need a host spike.
  This is recorded as a **future option with an uncertain efficiency payoff**, to
  be pursued only if fuse-overlayfs overhead is shown to matter and the
  volume-lifecycle cost is judged worth it. The disk-backed volume is orthogonal to
  the (rejected) dind *daemon* strategy — only the recipe's storage half is in
  scope here.

## Verification

- Offline: `scripts/test-acq` covers the default path — the root (`-u 0`)
  install/config block (threads `ACQ_MSB_PODMAN_PKGS` via `-e PODMAN_PKGS=`,
  writes the storage driver, the Docker-Hub-first registries drop-ins, and the
  plain `docker`→`podman` alias) AND the separate rootless verify block
  (`-u agent`), the `/dev/net/tun` + `/dev/fuse` group-scope grants, the rootless
  prereq packages (uidmap/passt/slirp4netns), marker-gated skip, the `ACQ_MSB_ENSURE_OCI=0`
  toggle-off, fail-soft on setup/verify failure (rc 0, warning, no marker), and the
  `ACQ_MSB_PODMAN_PKGS` charset-guard against injection.
- Live (verified on the assessment host / in an msb-equivalent sandbox,
  2026-08-11):
  - `podman info` FAILED with the kernel `overlay`-over-overlayfs error until
    `storage.conf` selected `vfs` (or overlay + fuse-overlayfs); afterward it
    reported the expected `graphDriverName`.
  - **Rootless as the agent user:** with `uidmap`/`passt`/`slirp4netns` installed,
    a vfs/fuse-overlayfs storage config, and `/dev/net/tun` + `/dev/fuse`
    group-scoped to the agent, `podman info` reported `rootless=true` and
    `docker run --rm docker.io/library/hello-world` printed "Hello from Docker!"
    (rc 0) — all as the unprivileged agent, no sudo.
  - **`/dev/fuse` gotcha (found on the first host run):** with only `/dev/net/tun`
    granted and the PREFERRED overlay+fuse-overlayfs driver selected, `podman info`
    (rootless) PASSED but `podman run`/`podman build` FAILED at mount time with
    `fuse: failed to open /dev/fuse: Permission denied` — because `podman info`
    does not open `/dev/fuse` but the fuse-overlayfs layer mount does. Group-scoping
    `/dev/fuse` to the agent (alongside `/dev/net/tun`) fixed it. This is why the
    grant helper covers BOTH devices and is not gated behind the `podman info`
    verify. `scripts/verify-backends` now includes a **local `docker build` (FROM
    scratch)** check that exercises exactly this layer-mount path with no registry
    egress, so the regression class is caught unambiguously (verified live: build
    succeeds with `/dev/fuse` granted, fails with it denied).
  - **Registry/egress:** the bare `hello-world` short name resolves to
    `quay.io/podman/hello`, whose blob CDN `cdn01.quay.io` is NOT in the balanced
    baseline (this was the perennial WARN). The fully-qualified
    `docker.io/library/hello-world` pulls via the balanced-allowlisted Docker Hub
    CDNs and succeeds — hence both the Docker-Hub-first default AND the verifier's
    use of the fully-qualified image.
  - Re-confirm end-to-end (plus `docker compose up` from a small
    `docker-compose.yaml`) on a KVM-capable host via `scripts/verify-backends` on
    the quarterly re-verification cadence (cannot run inside a sandbox, per
    [ADR-0011](0011-msb-backend-and-neutral-kits.md)).

## Links / tracking

- Emitter: `_acq_msb_ensure_oci` + `_acq_msb_grant_oci_devs` in
  `acq.backends/msb.sh`; wired in `acq_backend_provision` (both) and
  `acq_backend_start` (grant-oci-devs, for restart)
- Toggles: `ACQ_MSB_ENSURE_OCI` (default on), `ACQ_MSB_PODMAN_PKGS`,
  `ACQ_MSB_SHORT_NAME_MODE` (default `enforcing`)
- Related: [ADR-0011](0011-msb-backend-and-neutral-kits.md) (msb backend +
  base-image contract), [ADR-0018](0018-msb-balanced-egress-baseline.md)
  (balanced egress — the mirror hosts the install relies on),
  [ADR-0017](0017-msb-create-time-startup-script-staging.md) (restart-durability
  problem that dind would have re-introduced)
- msb evidence: docker-in-sandbox recipe requires `docker:dind` entrypoint +
  disk-backed `/var/lib/docker`
  (`docs/recipes/docker/docker-in-sandbox.mdx`); microVM init is `/init.krun`
  (no service manager); root FS is overlay-backed (observed live)
- podman evidence: daemonless run model and rootless prerequisites
  (`newuidmap`/`newgidmap` from shadow-utils, `passt`/pasta) — podman rootless
  tutorial and basic-networking guide
