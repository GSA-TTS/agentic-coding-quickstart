---
title: "Scope the msb balanced-egress deny-default to egress only (keep ingress default-allow)"
status: accepted
date: 2026-08-07
decision_makers: ["Bret Mogilefsky"]
category: security
nist_controls: ["SC-7", "AC-4", "CM-6", "CM-7", "SA-8", "SA-15"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
supersedes: []
---

# ADR-0019: Scope the msb balanced-egress deny-default to egress only

## Context

[ADR-0018](0018-msb-balanced-egress-baseline.md) gives every msb sandbox the sbx
"balanced" egress set by emitting a deny-by-default plus an `allow@…` rule per
vendored host. It originally emitted the **symmetric** `--net-default deny` flag.

[ADR-0014](0014-neutral-port-publish-and-background-vocab.md) publishes kit ports
at create time as `msb -p HOST:GUEST` (e.g. the `openchamber` kit exposes the
OpenChamber UI and the OpenCode server). These two features shipped
independently and their interaction was never reconciled.

They conflict. In microsandbox (verified against the source at
`crates/cli/lib/net_rule.rs`, `crates/cli/lib/commands/common.rs`, and
`crates/network/lib/policy/…` on msb 0.6.8):

- **`--net-default` is symmetric.** Its `--help` reads *"Default action for
  traffic in both directions … Sets egress and ingress symmetrically."* In
  `build_network_policy` a `--net-default` value is assigned to **both**
  `default_egress` and `default_ingress`.
- **A published port has no implicit ingress-allow.** The publisher evaluates
  every accepted connection with `policy.evaluate_ingress(...)`, which falls
  through to `default_ingress` when no ingress rule matches. `-p HOST:GUEST`
  only spawns a host listener; it installs no ingress rule. "Unfiltered
  published ports" work **only** because the profile/baseline `default_ingress`
  is `Allow`.
- Therefore `--net-default deny` sets `default_ingress = Deny`, and inbound to a
  published port is **RST-rejected**. The observable symptom on the host: the TCP
  handshake completes (msb's host-side proxy accepts) and then the connection is
  reset as data flows — `curl: (56) Recv failure: Connection reset by peer`, or
  `ERR_CONNECTION_RESET` in a browser — even though the guest service is healthy
  and listening on `0.0.0.0`.

msb exposes per-direction defaults both in the policy struct (`default_egress`,
`default_ingress`) and on the CLI (`--net-default-egress`, `--net-default-ingress`,
each mutually exclusive with the symmetric `--net-default`). The balanced
baseline only ever wanted to restrict **egress** ("balanced *egress* baseline");
denying ingress was never part of that story.

## Decision

Emit **`--net-default-egress deny`** (not the symmetric `--net-default deny`) in
the balanced-egress baseline. Egress stays deny-by-default + allowlist — exactly
ADR-0018's intent — while `default_ingress` keeps msb's baseline `Allow`, so
create-time `-p HOST:GUEST` published ports are reachable from the host with no
per-port ingress rule.

- The DNS grant (`allow@host:udp:53` + `allow@host:tcp:53`) and every balanced /
  kit / npm / secret `allow@…` rule are **egress** rules and are unchanged; they
  compose under the egress deny-default exactly as before.
- **No per-port ingress rule is emitted.** Relying on the ingress default is
  simpler than synthesizing an `allow:ingress@…` per published port and leaves
  clean headroom for a future strict profile to add specific ingress denies.
- **Strict-profile hook.** A future opt-in "strict" profile (not this change) can
  set `--net-default-ingress deny` and then emit an explicit
  `allow:ingress@any:tcp:<guest_port>` (grammar confirmed in `net_rule.rs`:
  `<action>[:<direction>]@<target>[:<proto>[:<ports>]]`, `Destination::Any`, TCP)
  per published port. That is deliberately out of scope for the balanced default.

`ACQ_MSB_BALANCED_EGRESS=0` is unchanged: no deny-default of either kind is
emitted (kit-only egress).

## Consequences

- **Better:** create-time published ports (openchamber UI on 3000, OpenCode
  server on 4096, and any future `publishedPorts` kit) are reachable out of the
  box on msb; the `ERR_CONNECTION_RESET` failure mode is eliminated at the source.
- **Security posture (SC-7 / AC-4):** unchanged for egress — still deny-by-default
  + balanced allowlist. Ingress default-allow matches msb's own profile baseline
  (`NetworkPolicy::from_profiles` sets `default_egress: Deny, default_ingress:
  Allow`) and the pre-ADR-0018 behavior; it does not widen egress. Inbound
  reachability is still bounded by which ports are actually published (`-p`) and
  by the guest's own loopback/`0.0.0.0` bind — msb has no NAT ingress for
  unpublished ports.
- **Post-hoc `acq ports --publish` (ADR-0015) was unaffected** by the bug because
  its `ssh -L` forward originates **inside** the guest (guest loopback), so the
  connection is not evaluated as ingress — which is why it kept working while
  create-time `-p` did not. No change needed there.
- **Version floor:** requires the `--net-default-egress` / `--net-default-ingress`
  split, first present in **msb 0.6.8** (confirmed on msb 0.6.8 `msb create
  --help`). Because the balanced-egress baseline is ON by default, `acq` raises
  its floor to `MIN_MSB_VERSION = 0.6.8` and `acq_backend_prepare` fails closed
  with a clear version message on any older binary — otherwise a plain
  `acq create` would pass an unknown flag to a 0.6.0-0.6.7 `msb` and clap would
  hard-error mid-create. `scripts/test-acq` asserts the sub-0.6.8 rejection.

## Alternatives considered

- **Emit `allow:ingress@any` (or per-port `allow:ingress@…:tcp:<port>`) alongside
  the symmetric `--net-default deny`.** Works, but a broad catch-all ingress
  allow shadows any later ingress deny (first-match-wins), and per-port rules add
  bookkeeping. The per-direction default flag is cleaner and is msb's intended
  mechanism. Rejected in favor of `--net-default-egress deny`.
- **Leave the symmetric deny and require `acq ports --publish` post-hoc.** Rejected:
  defeats create-time `publishedPorts`, and forces a manual step for every kit
  that exposes a UI.

## Verification

- Offline: `scripts/test-acq` asserts the balanced block emits
  `--net-default-egress deny` (and NOT a bare `--net-default deny`, nor
  `--net-default-ingress deny`), that create-time `-p HOST:GUEST` is still
  emitted, and that `ACQ_MSB_BALANCED_EGRESS=0` emits no deny-default.
- Live (deferred; requires a KVM-capable host, per ADR-0011): create an msb
  sandbox with a published port and confirm the host reaches the guest service
  with NO `acq ports --publish`, while an unlisted egress host is still refused.
  Covered by `scripts/verify-ports-live` / `scripts/verify-backends`.

## Links / tracking

- Amends: [ADR-0018](0018-msb-balanced-egress-baseline.md) (balanced egress baseline)
- Interacts with: [ADR-0014](0014-neutral-port-publish-and-background-vocab.md)
  (create-time `-p` publish), [ADR-0015](0015-msb-post-hoc-port-publish-via-ssh.md)
  (post-hoc publish, unaffected)
- Emitter: the balanced-egress block in `acq.backends/msb.sh`
- msb evidence: `--net-default` symmetry + `--net-default-egress`/`-ingress` split
  (`crates/cli/lib/commands/common.rs`), no implicit ingress-allow for published
  ports (`crates/network/lib/publisher.rs` → `evaluate_ingress`), rule grammar
  and `Destination::Any` (`crates/cli/lib/net_rule.rs`)
