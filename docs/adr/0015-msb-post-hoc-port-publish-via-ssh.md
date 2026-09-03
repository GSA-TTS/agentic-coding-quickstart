---
title: "Post-Hoc Port Publish on msb via SSH serve + Local Forwarding"
status: accepted
date: 2026-07-29
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["AC-6", "AC-17", "CM-6", "SA-8", "SA-15", "SC-7", "SC-8", "SI-10"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0015: Post-Hoc Port Publish on msb via SSH serve + Local Forwarding

## Context and Problem Statement

[ADR-0014](0014-neutral-port-publish-and-background-vocab.md) wires **create/run-time**
port publishing on msb (`msb -p HOST:GUEST`) so a neutral kit can expose a guest
port. It explicitly leaves **post-hoc** publishing — exposing a port on an
*already-running* sandbox — out of scope, because msb has no post-hoc `-p`
equivalent and the `acq ports` verb is disabled on msb
(`ACQ_BACKEND_SUPPORTS_PORT_FORWARD=0`).

Confirming the CLI surface against a live `msb --tree` (msb 0.6.7) showed msb
*does* have a post-hoc path, just not a NAT one: `msb ssh serve <sandbox>` opens
a host-side SSH listener against a running sandbox, and standard OpenSSH local
(`-L`) and dynamic (`-D`) forwarding then tunnel a guest port to the host with no
sandbox restart. This closes the last real gap between sbx (`sbx ports … --publish`,
post-hoc) and msb, so `acq ports <sandbox> --publish H:G` can finally do
something on msb instead of printing "re-create the sandbox."

## Decision Drivers

- **Parity with sbx's post-hoc `acq ports`** — the one remaining port capability
  sbx has and msb lacks; this is gap **K** in the parity epic (#234).
- **No sandbox restart** — the whole point of post-hoc publish is to expose a
  port without tearing down running state (which `msb -p` would require).
- **Least privilege / auditable exposure (AC-6, SC-7)** — a tunnel opens a host
  listener and an authorized key; both must be explicit and revertible.
- **Incremental on ADR-0014** — reuse the neutral `publishedPorts` vocabulary;
  add a mechanism, not a new kit field.
- **Fail closed on untrusted input (SI-10)** — ports and bind address reach an
  `ssh -L` argv and a listener bind, so they are validated like ADR-0014's fields.

## Considered Options

1. **`msb ssh serve` + OpenSSH `-L` local forwarding, managed by `acq ports`.**
   Chosen. `acq ports <sandbox> --publish H:G` authorizes a per-sandbox key
   (once), starts `msb ssh serve` on a loopback listener, and opens an `ssh -L`
   tunnel for each mapping.
2. **`msb ssh serve --stdio` + `ProxyCommand`.** Rejected as the primary path:
   great for one-off SSH tooling, but awkward as a long-lived published port and
   still needs a forwarding client on top.
3. **Require re-create with `-p` (status quo).** Rejected: destroys running
   state, which defeats "post-hoc," and leaves `acq ports` inert on msb.

## Decision Outcome

**Chosen: Option 1.** Wire `acq_backend_ports` on msb to the SSH-tunnel path and
flip `ACQ_BACKEND_SUPPORTS_PORT_FORWARD=1`. Sketch:

- **Key authorization (self-healing).** `msb ssh authorize` seats a public key
  in `<MSB_HOME>/ssh/authorized_keys`. acq uses a dedicated, non-interactive
  key it manages under its own state dir (not the user's personal key), created
  on first use. acq refreshes authorization on each publish because msb's
  host-scoped `authorized_keys` can disappear independently of acq state (for
  example, after an msb data reset/reinstall), and re-authorizing an existing key
  is harmless.
- **Serve + forward.** For `acq ports <sandbox> --publish H:G`, acq starts
  `msb ssh serve <sandbox> --host 127.0.0.1 --port <ephemeral>` and then
  `ssh -p <ephemeral> -L 127.0.0.1:H:127.0.0.1:G <sandbox-host>`, backgrounded.
- **Caveats carried from the tree.** Forwarded connections originate **inside**
  the guest, so `127.0.0.1` in the `-L` destination is the *sandbox's* loopback,
  not the host's; sandbox network policy still applies; **reverse (`-R`) and
  stream-local forwarding are unsupported**. The default listener binds loopback
  — binding beyond `127.0.0.1` is opt-in and out of scope here.

### Relationship to ADR-0014

ADR-0014 stays the create-time story and is unchanged. This ADR only adds the
post-hoc mechanism and is safe to land after ADR-0014's `publishedPorts` consumer
exists. No neutral kit-schema change: a kit still declares `publishedPorts`; the
difference is whether acq publishes at create-time (`-p`) or post-hoc (tunnel).

### Validation (SI-10)

- Reuse ADR-0014's port validation (`1..65535`, integer) for the `--publish H:G`
  argument before it reaches `ssh -L`.
- The managed key is generated with `0600`/`0700` perms; acq never authorizes
  the user's personal key implicitly.

### Listing published ports (`acq ports <sandbox>`, no `--publish`)

`acq ports <sandbox>` with no `--publish` is a **query** and lists both
create-time `-p` NAT mappings and acq-recorded post-hoc tunnels. The create-time
half reads `msb inspect <sandbox> --format json`, whose port shape is
**canonical, not guessed** — it is the serialized `PublishedPort` struct from the
microsandbox source:

```jsonc
// msb inspect --format json →
//   .active_config.network.ports[]   (active/running config)
//   .config.network.ports[]          (requested config, mirror)
{
  "host_port":  3000,          // u16
  "guest_port": 3000,          // u16
  "protocol":   "tcp",         // "tcp" | "udp"  (default "tcp")
  "host_bind":  "127.0.0.1"    // IpAddr, defaults to loopback
}
```

Source of truth (pinned to msb 0.6.7):
[`crates/network/lib/config/types.rs` → `struct PublishedPort`](https://github.com/superradcompany/microsandbox/blob/main/crates/network/lib/config/types.rs)
and the `--format json` assembly in
[`crates/cli/lib/commands/inspect.rs`](https://github.com/superradcompany/microsandbox/blob/main/crates/cli/lib/commands/inspect.rs).
The parser (`_acq_msb_ports_from_inspect`) keys on the explicit `host_port` /
`guest_port` fields and deliberately ignores `host_bind` so its dotted IP is
never mistaken for port digits. This matters because `host_bind` can serialize
with a trailing `:port` (a `SocketAddr`-style form): the earlier
numeric-pairing parser split that colon and emitted junk ports (e.g.
`guest 9 -> host 127.0.0.1:1`); keying on `*_port` field names removes that
failure mode entirely.

## Consequences

- **Better:** `acq ports … --publish` works on msb; sbx↔msb port parity is
  complete; `SUPPORTS_PORT_FORWARD` becomes truthful.
- **Tradeoff:** a background `msb ssh serve` + `ssh` process pair per published
  port; acq must track and tear these down on `acq rm`/stop. An authorized key
  is seated in msb's global authorized_keys (host-scoped, documented).
- **Liveness reporting (best-effort):** after backgrounding each of the serve
  listener and the `ssh -L` forward, acq waits a short settle window and probes
  the process with `kill -0` before reporting the publish as succeeded (and
  before recording its teardown PID). This catches the common fast-failure modes
  (serve cannot bind, `ExitOnForwardFailure` fires) so a dead tunnel is not
  reported as published. It is **not** a durable health guarantee: a tunnel that
  dies *after* the settle window is still reported as published, and teardown
  later kills an already-dead PID (harmless). A future enhancement could add a
  host-port probe or a supervisor; out of scope here.
- **Security (AC-6/AC-17/SC-7):** exposure is loopback by default and gated on an
  acq-managed key; no remote bind without explicit opt-in. Tunnels obey the
  sandbox's egress/ingress policy.
- **Compliance:** no new external service or data-classification change; the
  mechanism is host-local SSH forwarding (SC-8 in transit).

## Validation

- `bash -n acq acq.backends/*.sh` clean.
- `scripts/test-acq` gains cases (stubbed `msb`/`ssh`): `acq ports --publish H:G`
  authorizes once, serves, and opens `-L`; invalid ports are rejected before argv;
  a serve/forward that dies within the settle window fails the publish closed
  (no false success, no recorded state); and LIST mode exits 0 under
  `set -euo pipefail` even with no ports (a query must never hard-fail).
- Live end-to-end is covered by `scripts/verify-ports-live` (a KVM-capable host,
  per ADR-0011): it stands up a throwaway msb sandbox + guest listener, then
  asserts the happy-path publish (host reaches guest through the tunnel), LIST,
  the fail-closed negative (host port already in use), and teardown. This is the
  path `scripts/verify-backends` does not exercise.

## Links

- Builds on: [ADR-0014](0014-neutral-port-publish-and-background-vocab.md)
  (create-time `publishedPorts` vocabulary + msb `-p` consumer)
- Adapter contract: [ADR-0010](0010-acq-pluggable-backends.md)
- Parity tracking: [sbx↔msb backend parity epic (#234)](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/234)
  (gap K)
- Implementation: [#238](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/238)
- msb `inspect --format json` port shape (canonical):
  [`crates/network/lib/config/types.rs`](https://github.com/superradcompany/microsandbox/blob/main/crates/network/lib/config/types.rs)
  (`struct PublishedPort`) and
  [`crates/cli/lib/commands/inspect.rs`](https://github.com/superradcompany/microsandbox/blob/main/crates/cli/lib/commands/inspect.rs)
