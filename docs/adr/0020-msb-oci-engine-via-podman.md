---
title: "Ensure an OCI container engine in msb sandboxes via rootful podman, not docker-in-docker"
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

# ADR-0020: Ensure an OCI container engine in msb sandboxes via rootful podman

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

So the bundled Docker is inert here, and the blessed way to make it work (the
dind recipe) is an *image/entrypoint* strategy that does not fit our adapter:
`acq` boots a general base image and launches the agent — it does not own the
sandbox entrypoint, and would have to (a) start `dockerd` itself post-boot and
poll the socket, (b) keep that daemon alive across every `msb start`/restart
(the same restart-durability problem [ADR-0017](0017-msb-create-time-startup-script-staging.md)
already wrestles with), and (c) provision a per-sandbox disk-backed
`--mount-named docker-data:/var/lib/docker:kind=disk` volume and tear it down.

## Decision

Provision **podman** (rootful) at provision time as the OCI engine, and alias
`docker` → `podman` so both `docker run …` and `docker compose …` work inside
the sandbox. Implemented as a new idempotent, marker-gated step
`_acq_msb_ensure_oci`, called from `acq_backend_provision` right after
`_acq_msb_ensure_agent_user`.

1. **podman over docker-in-docker.** podman is **daemonless** — each invocation
   forks `runc`/`crun` directly, so there is no socket to start, poll, or keep
   alive across restarts (eliminating the dind lifecycle problem entirely). It
   uses **`fuse-overlayfs`** (we have `/dev/fuse`) or `vfs` on the overlay root,
   so **no disk-backed volume** is required. It needs **no nested
   virtualization**. And it is CLI-compatible with docker for the
   run/build/compose workflows this targets.

   **Storage driver on an overlay root (added after live verification).** Rootful
   podman defaults to the **kernel `overlay`** graph driver, which **cannot stack
   on msb's overlay root** — `podman info` fails with `'overlay' is not supported
   over overlayfs, a mount_program is required`. This was the concrete reason the
   engine came up unusable in practice (the failure this branch exists to fix).
   The adapter therefore writes `/etc/containers/storage.conf` **before** the
   `podman info` verify, selecting a driver that works on an overlay root:
   - **Preferred:** `overlay` + `mount_program = fuse-overlayfs` when
     `fuse-overlayfs` is installed (fast, thin-on-disk; msb provides `/dev/fuse`).
     `fuse-overlayfs` is added to `ACQ_MSB_PODMAN_PKGS` so the apt path gets it.
   - **Fallback:** `vfs`, which works everywhere with no extra package and no
     `/dev/fuse` (correct but disk-heavy — a full copy per layer). Used when
     `fuse-overlayfs` is unavailable, and as a last-resort retry if `podman info`
     still fails with the configured driver.
   The adapter does not clobber an operator-provided `storage.conf` that already
   names a `driver`.

2. **Rootful, via the agent's passwordless sudo.** The install and engine run as
   root (`msb exec -u 0`). Rootless podman would additionally require
   `newuidmap`/`newgidmap` (the `uidmap` package) and `passt`/pasta — both
   **absent** on the default image (confirmed live) — so rootful sidesteps the
   rootless prerequisites a lean base lacks. `/etc/subuid`/`/etc/subgid` do exist
   for `agent`, so a future rootless variant remains possible if desired.

3. **Alias `docker` → `podman` (do not fix the bundled Docker).** A tiny exec
   wrapper is written to **`/usr/local/bin/docker`** (ahead of `/usr/bin` on the
   default PATH), shadowing the bundled-but-non-functional `/usr/bin/docker`. We
   never touch the base image's `/usr/bin/docker`. Because the bundled Docker CLI
   does not work here anyway (dead socket), shadowing it loses nothing and makes
   both `docker run` and `docker compose` route to the working podman engine.

   **The wrapper execs `sudo -n podman "$@"`, not a bare `podman`.** The engine is
   ROOTFUL (rung 2), but agents run as the unprivileged `agent` user, and a bare
   `podman` as that user is ROOTLESS — which FAILS on the default image
   (`newuidmap`/`passt` absent; and a root-created storage db conflicts with the
   rootless overlay default). Verified live: as the agent user, rootless
   `podman info` → rc 125, while `sudo -n podman info` (vfs storage) → rc 0. The
   agent has passwordless sudo (base-image contract), so the wrapper reaches the
   working rootful engine; `sudo -n` never prompts (fails fast if sudo were
   unavailable). This is also why the `scripts/verify-backends` OCI check probes
   `docker info` (→ rootful via the wrapper) rather than a bare rootless
   `podman info`.

4. **`docker compose`, not `docker-compose`.** The standalone `docker-compose`
   CLI is deprecated in favour of the `docker compose` subcommand. With the alias
   in place, `docker compose …` becomes `podman compose …`, which dispatches
   through the installed **`podman-compose`** provider. So we install
   `podman podman-compose` (`ACQ_MSB_PODMAN_PKGS`) and do **not** ship a separate
   `docker-compose` binary. The goal is that `docker-compose.yaml` files work,
   not that the deprecated CLI name exists.

5. **Idempotent + marker-gated + fail-soft.** The step returns early if the
   marker `/var/lib/acq/oci-ready` exists or if `podman` is already present. It
   verifies `podman info` before writing the marker. If the engine cannot be
   provisioned it **warns and returns 0** — provision continues and OCI is simply
   unavailable — mirroring the agent-install and prereq-check steps
   (§Failure Handling, `AGENTS.md`). Toggle off with `ACQ_MSB_ENSURE_OCI=0`.

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
  `ACQ_MSB_BALANCED_EGRESS=0`, or a custom base whose egress is otherwise
  narrowed, the mirror is unreachable and the step **fails soft** — chosen
  deliberately so an operator's explicit egress narrowing is respected rather
  than silently re-widened (the warning names the mirror hosts and the
  `ACQ_MSB_ENSURE_OCI=0` escape hatch).
- **Behavioral parity with Docker is high but not total.** podman's docker-CLI
  compatibility covers the run/build/compose workflows this targets; uncommon
  edge cases (Docker build-secret syntax, some compose v3 keys, `buildx`-specific
  features) may differ. Acceptable for agent workflows; the bundled Docker was
  non-functional here regardless.
- **Security posture (SC-7 / SI-10).** No new external services; a
  configuration/adapter change (CM-2/CM-6/CM-7; SA-8/SA-15). `ACQ_MSB_PODMAN_PKGS`
  is charset-guarded (`[A-Za-z0-9._+ -]`) before it is interpolated into the root
  `sh -c`, so operator config cannot inject shell into the elevated install
  (SI-10). Rootful podman runs containers as root *inside the microVM* — the
  microVM is the security boundary (the sandbox is untrusted-by-design), so this
  does not expand the host attack surface; it is consistent with the "sandbox is
  the boundary" model in `AGENTS.md`.
- **Adds a runtime package install to provision.** First provision on a fresh
  sandbox pays an `apt-get install` cost; the marker makes it a one-time cost per
  sandbox (skipped on restart / re-provision).

## Alternatives considered

- **Follow the msb docker-in-docker recipe (start `dockerd`, disk-backed
  `/var/lib/docker`).** Officially blessed and gives full Docker API fidelity,
  but it is an entrypoint strategy retrofitted poorly onto an adapter that boots
  a general base and runs an agent: it needs a post-boot daemon start + socket
  poll, a daemon kept alive across restarts, and a per-sandbox disk-backed volume
  with its own teardown. Rejected as materially more complex and stateful than
  podman for no benefit in the target workflows.
- **Rootless podman.** More defense-in-depth in principle, but requires
  `uidmap` (`newuidmap`/`newgidmap`) and `passt`/pasta, both absent on the
  default image — more packages to install, for a container that already runs
  inside an untrusted-by-design microVM. Deferred; the subuid/subgid ranges exist
  if we revisit.
- **Do nothing when `dockerd` is present (literal task reading).** Would leave
  the default image's dead socket / broken `docker compose` as-is. Rejected: the
  bundled engine does not actually work under msb, so "present" is not "usable."
- **Always symlink/override in a way that shadows a working custom Docker.** We
  place the wrapper in `/usr/local/bin` and never remove `/usr/bin/docker`; an
  operator who bakes a genuinely working Docker into a custom `ACQ_MSB_IMAGE` can
  set `ACQ_MSB_ENSURE_OCI=0`.

## Verification

- Offline: `scripts/test-acq` covers the default install path (runs as root
  `-u 0`, threads `ACQ_MSB_PODMAN_PKGS` via `-e PODMAN_PKGS=`, wires
  `/usr/local/bin/docker`, touches the marker), marker-gated skip, the
  `ACQ_MSB_ENSURE_OCI=0` toggle-off, fail-soft on setup failure (rc 0, warning,
  no marker), and the `ACQ_MSB_PODMAN_PKGS` charset-guard against injection.
- Live (verified on the assessment host inside an msb sandbox, 2026-08-11):
  rootful `podman info` FAILED with the kernel `overlay`-over-overlayfs error
  until `/etc/containers/storage.conf` selected `vfs` (or overlay +
  fuse-overlayfs), after which `podman info` reported the expected
  `graphDriverName`. This is the observation that drove the storage-driver
  selection above. A full `docker run --rm hello-world` (→ podman) end-to-end run
  additionally needs registry egress; re-confirm it plus `docker compose up` from
  a small `docker-compose.yaml` on a KVM-capable host via
  `scripts/verify-backends` on the quarterly re-verification cadence (cannot run
  inside a sandbox, per [ADR-0011](0011-msb-backend-and-neutral-kits.md)).

## Links / tracking

- Emitter: `_acq_msb_ensure_oci` in `acq.backends/msb.sh`; wired in
  `acq_backend_provision`
- Toggles: `ACQ_MSB_ENSURE_OCI` (default on), `ACQ_MSB_PODMAN_PKGS`
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
