---
title: "Forward the Host ssh-agent into an msb Guest via --vsock"
status: accepted
date: 2026-08-17
decision_makers: ["Bret Mogilefsky"]
category: security
nist_controls: ["AC-6", "AC-17", "CM-6", "CM-7", "SA-8", "SA-15", "SC-7", "SC-8", "SI-10", "IA-5"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
supersedes: []
---

# ADR-0021: Forward the Host ssh-agent into an msb Guest via --vsock

## Context and Problem Statement

The `git-ssh-sign` kit signs guest commits with the **host's** SSH agent so no
private key material ever enters the sandbox. On **sbx** this "just works": the
sbx CLI forwards the host ssh-agent into the sandbox **implicitly whenever the
host `SSH_AUTH_SOCK` env var is set**, and in-guest `git`/`ssh` reach it over a
unix socket. On **msb** there was previously **no equivalent**: a plain microVM
guest has no path to the host's agent socket, so `git-ssh-sign` was
non-functional and every signed-commit workflow that works on sbx failed on msb.
This is a concrete sbx↔msb parity gap — the last one blocking `git-ssh-sign`.

The blocker was upstream. Earlier msb releases (through 0.6.8) offered no
host-socket forwarding primitive: virtiofs services `connect()` locally in the
guest, `msb ssh` reports no agent, and `ssh -R` (remote/stream-local forwarding)
is rejected — all proven dead ends. **msb 0.6.9** (released 2026-08-15) added
`--vsock HOST_PATH:PORT[/stream|/dgram]`, which exposes a **host** unix socket at
guest `AF_VSOCK` CID 2:PORT (guest→host virtio-vsock, no agentd proxy, no TSI, no
guest IP). The `--vsock` surface was confirmed live against `msb --tree` on
msb 0.6.9. The upstream merge that introduced it (see Links) is an ancestor of
the v0.6.9 tag. That primitive is what closes the gap.

## Decision Drivers

- **Parity with sbx `git-ssh-sign`** — the one remaining signing capability sbx
  has and msb lacks; forwarding the host agent is the mechanism sbx uses.
- **No private key in the guest (SC-8, IA-5)** — only agent *operations* traverse
  the socket; the key material stays on the host, matching the sbx posture.
- **Same opt-in signal as sbx (AC-6, CM-7)** — sbx triggers forwarding purely off
  `SSH_AUTH_SOCK`; adding a separate flag on msb would break behavioral parity.
- **Least privilege / auditable trust boundary (AC-6, SC-7)** — forwarding an
  agent widens the host↔microVM trust boundary; it must be opt-in and reversible.
- **Fail closed on untrusted input (SI-10)** — a host socket path and a vsock port
  reach the `msb create` argv, so both are validated host-side before use.
- **Fail soft on capability gaps** — forwarding is opt-in convenience, not core;
  an older msb or a guest without `socat` must warn and skip, not abort a run.

## Considered Options

1. **`--vsock` + an in-guest `socat` bridge, triggered by `SSH_AUTH_SOCK`.**
   Chosen. When the host `SSH_AUTH_SOCK` is set, acq passes
   `--vsock $SSH_AUTH_SOCK:3552/stream` at create, then starts an in-guest
   `socat UNIX-LISTEN:<sock>,fork,reuseaddr VSOCK-CONNECT:2:3552` bridge that
   re-exposes the vsock route as a unix socket at
   `/home/agent/.acq/ssh-agent.sock`, exported as `SSH_AUTH_SOCK` in the guest.
2. **A separate explicit `--forward-ssh-agent` opt-in flag.** Rejected:
   `SSH_AUTH_SOCK` is already the opt-in signal sbx uses; adding a flag breaks
   parity and adds a moving part. The env var *is* the opt-in (unsetting it is the
   opt-out), per the decision-maker.
3. **Bind-mount the agent socket, or `msb ssh` native agent forwarding.**
   Rejected: proven dead ends on 0.6.8 — virtiofs services `connect()` locally in
   the guest, `msb ssh` reports no agent, and `ssh -R` is rejected.
4. **Stay blocked** (leave `git-ssh-sign` non-functional on msb). Rejected: it
   leaves a real, now-closable parity gap open.

## Decision Outcome

**Chosen: Option 1.** Forward the host ssh-agent into an msb guest with
`--vsock $SSH_AUTH_SOCK:3552/stream`, **automatically whenever the host
`SSH_AUTH_SOCK` is set** (mirroring sbx — the env var is the opt-in signal;
unsetting it is the opt-out, not a separate flag). Because guest `git`/`ssh` speak
a unix socket path (not a vsock CID), an in-guest `socat` bridge translates the
vsock route back to a unix socket the agent can point `SSH_AUTH_SOCK` at.

A neutral, general host-socket forwarding vocabulary also exists (env
`ACQ_FORWARD_HOST_SOCKETS="PATH:PORT[/stream|/dgram][,...]"`), with the ssh-agent
forward as the automatic special case built on top of it.

### New modules

- **`acq.backends/common.sh`** — neutral helper `acq_host_socket_forwards`
  (enumerates the requested host-socket forwards, ssh-agent special case plus any
  `ACQ_FORWARD_HOST_SOCKETS` entries) and `_acq_valid_vsock_port` (SI-10 port
  validation). Backend-agnostic so a future backend can consume the same vocab.
- **`acq.backends/msb.sh`** — the msb consumer:
  - `_acq_msb_vsock_flags_into` — emits one `--vsock HOST_PATH:PORT/stream` per
    requested forward onto the `msb create` argv (SI-10-validated first);
  - `_acq_msb_check_socat` — prereq-checks that `socat` is present in the guest
    image, warning (not aborting) if missing;
  - `_acq_msb_start_ssh_agent_bridge` — starts the in-guest
    `socat UNIX-LISTEN:<sock>,fork,reuseaddr VSOCK-CONNECT:2:3552` bridge;
  - `_acq_msb_ssh_auth_sock_for` — resolves the guest `SSH_AUTH_SOCK` value
    injected on attach, `acq exec`, and kit commands.
  - Constants: `ACQ_MSB_SSH_AGENT_VSOCK_PORT` (default `3552`),
    `ACQ_MSB_SSH_AGENT_GUEST_SOCK` (default `/home/agent/.acq/ssh-agent.sock`).

### Fixed guest vsock port (3552)

The guest vsock port is fixed at **3552** (constant
`ACQ_MSB_SSH_AGENT_VSOCK_PORT`). A fixed port keeps the create argv and the
in-guest bridge deterministic and re-derivable on resume without recording extra
state. **3552 deliberately avoids msb's reserved port 123**; SI-10 validation
rejects 123 as well as out-of-range values (see Validation).

### The socat bridge and SSH_AUTH_SOCK export points

`--vsock` exposes the host agent at guest `AF_VSOCK` CID `2:3552`, but guest
`git`/`ssh` only speak a unix socket **path**. The in-guest bridge
`socat UNIX-LISTEN:/home/agent/.acq/ssh-agent.sock,fork,reuseaddr VSOCK-CONNECT:2:3552`
translates the vsock route to that unix socket, and acq exports
`SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock` in the guest at every entry
point: **attach**, **`acq exec`**, and **kit commands** — so `git-ssh-sign` and
any interactive `git`/`ssh` see the agent.

The `--vsock` route persists across `msb stop`/`start` (it is part of the sandbox
config), but the `socat` bridge **process** dies on stop. So the bridge is
re-started in `acq_backend_start`, the same way the OCI device-node re-grant is
re-applied on resume.

### Version gate (MIN_MSB_VERSION stays 0.6.8)

`--vsock` first appears in **msb 0.6.9**. The global `MIN_MSB_VERSION` floor stays
**0.6.8** (unchanged — the balanced-egress `--net-default-egress` floor). The
forwarding feature is gated separately on `MIN_MSB_VSOCK_VERSION` (0.6.9): on an
older msb, acq **warns and skips** the forward (fail-soft) rather than passing an
unknown flag to `msb create`, because forwarding is opt-in convenience, not core.

`socat` must be present **in the guest image** for the bridge to run. It is
prereq-checked and warned-on-missing, but **not auto-installed** — guest egress is
locked by the balanced-egress baseline, so a package mirror is unreachable during
provision. The default image `docker/sandbox-templates:shell-docker` is assumed to
provide it.

### Live verification

End-to-end verification — a hermetic throwaway ssh-agent on the host, forwarded
into the guest, with in-guest `ssh-add -L` exposing that exact ephemeral key —
requires a **KVM-capable host** and cannot run in CI or inside a sandbox (no
nested sandboxes). It was **verified on a macOS/HVF host on 2026-08-17** via
`scripts/verify-backends`:

```
ok    msb: guest session has SSH_AUTH_SOCK exported (ssh-agent forward wired)
ok    msb: guest ssh-add -L exposes the ephemeral host key (vsock + socat
      forward reaches the host agent)
```

`scripts/verify-backends` spins up its own throwaway agent (one throwaway key),
lets acq forward it via `--vsock`, and asserts the guest's forwarded agent holds
that exact public-key body — proving the vsock route + socat bridge reach the
host agent. Re-run it on the ADR-0011 periodic-validation cadence.

## Security / Trust Boundary

Forwarding the host ssh-agent into the guest **widens the host↔microVM trust
boundary**: any code running in the guest can exercise **every key the host agent
holds** for as long as the socket is reachable. This is the same exposure sbx
accepts, and it is the reason the forward is **opt-in**, driven by
`SSH_AUTH_SOCK` (unset it, and nothing is forwarded).

microsandbox's own docs warn: *"A route gives sandbox processes access to
whatever the host service allows. Avoid exposing powerful services such as … an
SSH agent unless the service has its own authentication and narrow permissions."*
Accordingly, where the host agent supports it, we recommend **agent-side
confirmation and constraints** — `ssh-add -c` (confirm each use) and/or `ssh-add
-h` (host-scoped constraints) — so a compromised guest cannot silently sign or
authenticate arbitrarily.

Crucially, **private key material never enters the guest**: only agent
*operations* (sign/list) traverse the vsock→unix socket. This preserves the sbx
property that the sandbox holds no key it could exfiltrate (SC-8, IA-5).

## Consequences

- **Positive:** `git-ssh-sign` works on msb at parity with sbx; the same
  `SSH_AUTH_SOCK`-driven, key-never-enters-guest posture applies to both backends;
  the neutral `ACQ_FORWARD_HOST_SOCKETS` vocabulary lets a future backend or use
  case reuse the same forwarding path.
- **Tradeoff:** an in-guest `socat` bridge process per sandbox that must be
  re-started on resume (handled in `acq_backend_start`); a hard dependency on
  `socat` being present in the guest image; and a feature gated on msb >= 0.6.9
  while `MIN_MSB_VERSION` stays 0.6.8 (older msb warns and skips).
- **Security (AC-6/AC-17/SC-7/SC-8/IA-5):** the forward widens the trust boundary
  but is opt-in, reversible (unset `SSH_AUTH_SOCK`), and never carries key material
  into the guest; `ssh-add -c`/`-h` are recommended to narrow it further.
- **Compliance (CM-6/CM-7/SA-8/SA-15):** no new external service or
  data-classification change; the mechanism is a host-local vsock route plus an
  in-guest socket bridge, configured host-side and validated before use (SI-10).

## Validation

- Offline unit coverage in `scripts/test-acq` (stubbed `msb`/`socat`, no Docker or
  network), cases **10c1–10c14**: the version gate (warn+skip on msb < 0.6.9),
  `--vsock` flag emission when `SSH_AUTH_SOCK` is set, the `socat` prereq check,
  bridge start on **provision** and on **start** (resume), `SSH_AUTH_SOCK`
  injection on attach/`acq exec`/kit commands, and SI-10 validation of the host
  socket path (absolute + existing socket) and the vsock port (integer in
  `1..4294967294`, `!= 123`) — invalid values are rejected before reaching
  `msb create`.
- **Live end-to-end VERIFIED** on a macOS/HVF host (2026-08-17) via
  `scripts/verify-backends`, which forwards a hermetic throwaway agent and
  confirms the guest's forwarded agent exposes that exact ephemeral key
  (`guest ssh-add -L exposes the ephemeral host key`). Re-run on the ADR-0011
  periodic-validation cadence (it cannot run in CI / inside a sandbox — no nested
  sandboxes).

## Links

- Commit signing decisions: [ADR-0006](0006-git-ssh-sign-kit.md) (the
  `git-ssh-sign` kit) and [ADR-0007](0007-commit-verification-identity-guidance.md)
  (verification/identity guidance)
- msb backend + neutral kits: [ADR-0011](0011-msb-backend-and-neutral-kits.md)
  (also the live-verification cadence this change defers to)
- msb SSH machinery: [ADR-0015](0015-msb-post-hoc-port-publish-via-ssh.md)
  (`msb ssh serve` + `ssh -L` port publishing)
- Parity tracking: [sbx↔msb backend parity epic](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/234)
  (`GSA-TTS/agentic-coding-quickstart#234`)
- This change is tracked in
  [`GSA-TTS/agentic-coding-quickstart#303`](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/303)
- Upstream primitive: microsandbox `--vsock`, introduced by merge commit
  `e0c0f9ba` in
  [superradcompany/microsandbox#1297](https://github.com/superradcompany/microsandbox/pull/1297)
  (closing [superradcompany/microsandbox#663](https://github.com/superradcompany/microsandbox/issues/663);
  [superradcompany/microsandbox#1290](https://github.com/superradcompany/microsandbox/issues/1290)
  closed in favor of `superradcompany/microsandbox#663`;
  [superradcompany/microsandbox#1304](https://github.com/superradcompany/microsandbox/issues/1304)
  folded into `superradcompany/microsandbox#1297`), landed in the
  [v0.6.9 tag](https://github.com/superradcompany/microsandbox/releases/tag/v0.6.9)
