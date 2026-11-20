---
title: "Define OpenShell as an Explicit Experimental acq Backend"
status: proposed
date: 2026-10-14
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["AC-3", "AC-6", "CM-2", "CM-3", "CM-5", "CM-6", "SC-7", "SC-8", "SI-7", "SI-10", "SI-17"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0036: Define OpenShell as an Explicit Experimental acq Backend

## Context and Problem Statement

`acq` has a backend-neutral control-plane contract for sandbox lifecycle,
workspaces, kits, images, credentials, network policy, and host-authoritative
configuration. OpenShell is a prospective additional execution backend. Its
gateway and compute-driver model can provide local and remote execution, but an
adapter must not turn a prospective backend into an implicit, broadly-supported
execution path before its security boundaries and lifecycle behavior have been
measured.

This ADR freezes the contract that an OpenShell adapter must meet before adapter
code lands. It selects OpenShell only as an **explicit experimental backend**;
it does not claim that any OpenShell CLI release, gateway deployment, compute
driver, or remote control plane is currently supported.

## Decision Drivers

- Preserve `acq`'s stable neutral interface and explicit backend selection
  ([ADR-0010](0010-acq-pluggable-backends.md)).
- Fail closed: no driver, gateway, mount, policy, or secret behavior becomes
  supported because it happens to work in an unreviewed environment.
- Maintain least privilege and default-deny network enforcement (AC-3, AC-6,
  SC-7), including for processes created by an agent rather than directly by
  `acq`.
- Keep the host authoritative over all inputs that configure or reconfigure a
  sandbox; guest state is never authority ([ADR-0035](0035-host-authoritative-sandbox-config.md)).
- Preserve the existing portable image override (`--image` / `ACQ_IMAGE`),
  clone semantics, kit role separation, and `acq` credential boundary rather
  than creating backend-specific replacements.
- Make promotion from experimental support reviewable through reproducible,
  live evidence for each compute driver.

## Considered Options

1. **Add OpenShell as an explicit experimental adapter with driver-specific
   promotion gates.** Chosen. The adapter is selected only by `--backend
   openshell` or `ACQ_BACKEND=openshell`; each driver remains unsupported until
   its gates pass.
2. **Auto-detect OpenShell or make it a normal supported backend immediately.**
   Rejected. Auto-selection would expose users to an unreviewed gateway and
   driver boundary, and a support claim without live evidence would be false.
3. **Treat OpenShell as a wrapper around existing backend adapters.** Rejected.
   It would obscure which runtime actually enforces mounts, network policy, and
   credential delivery, preventing meaningful capability and threat review.

## Decision Outcome

**Chosen: Option 1.** OpenShell may be introduced behind the explicit backend
name `openshell`, with an experimental warning on every create or attach. It
MUST NOT participate in auto-detection or be offered as the default backend.
An explicit `--backend openshell` or `ACQ_BACKEND=openshell` selection remains
valid. The warning MUST identify the selected compute driver and state that the
driver is experimental unless and until it has passed the promotion gates below.

### Compatibility floor and gateway ownership

Before an adapter is merged, its implementation MUST pin an OpenShell CLI and
gateway compatibility floor in a versioned compatibility record. The record
MUST name the tested CLI version, gateway API/version, selected driver, host OS,
and the live verification transcript. The adapter MUST reject an absent,
older, or unrecognized compatible version rather than guessing command or API
semantics.

`acq` owns the lifecycle of only the OpenShell session or sandbox resources it
creates. The gateway is a host-side control-plane dependency, not an in-guest
service: its endpoint, transport security, authentication material, and
driver-selection configuration remain host-controlled. The guest MUST NOT be
given a gateway administration credential, a writable gateway configuration, or
an arbitrary gateway endpoint. A remote gateway is not implicitly authorized by
this ADR; its endpoint and authentication model require separate approval and
review before use.

### Compute-driver promotion gates

Driver support is independent. Passing gates for one driver does not promote
another driver, even when they share an OpenShell CLI or gateway.

| Driver | Initial status | Required promotion evidence before support is claimed |
|--------|----------------|--------------------------------------------------------|
| Local | Experimental candidate | Live create, exec, attach, stop, restart, remove, port, copy, mount, clone, secret, kit, default-deny egress, cleanup, and failure-path verification on each supported host OS and pinned OpenShell/gateway pair. |
| MXC | Unsupported | All local gates plus evidence for remote gateway authentication, TLS validation, remote-state cleanup, mount or upload behavior, credential non-disclosure, and network-policy enforcement by the MXC execution boundary. |
| Kubernetes | Unsupported | All local gates plus evidence for namespace/service-account isolation, pod lifecycle and cleanup, read-only host-authoritative material, secret delivery, NetworkPolicy-equivalent default deny, port exposure, and durable audit attribution. |

The compatibility record for a promoted driver MUST capture actual observed
output and the tested version tuple. A missing runtime or control plane is
`BLOCKED`, not a passing simulation. Any behavior-affecting OpenShell or driver
upgrade reopens the applicable live gates before support is claimed again.

### Workspace, bind-mount, clone, and upload semantics

The approved primary-workspace mode is a host-selected bind mount. The adapter
MUST mount only the user-selected workspace path, at its intended absolute guest
path, with an explicit `rw` or `ro` mode. It MUST reject ambiguous paths,
symlink/path-form confusion, or a driver that cannot demonstrate the requested
mode. It MUST NOT broadly mount a host home directory, the `acq` state tree, the
gateway configuration, or the host secret store.

`--clone` and `ACQ_CLONE=1` retain the neutral contract in
[ADR-0027](0027-neutral-clone-option.md): the primary is an acq-managed,
physical `git clone --no-hardlinks` scratch copy; it is mounted at the original
workspace path; recovery is `git fetch sandbox-<name>`; and `acq rm` warns about
unrecovered commits before removing scratch state and its remote. Scratch state
is host-managed and is not a source of authority for later lifecycle decisions.
The adapter MUST provide `ACQ_WORKSPACE` and `ACQ_CLONE=1` guest markers with
the same meanings as the existing backends.

If a driver cannot provide the approved bind mount, `acq` MAY use an explicit
upload/download fallback only when the user selected it or the adapter clearly
reports that the requested driver requires it. The fallback MUST upload a
bounded workspace snapshot to driver-managed storage, record the host-side
source and destination mapping, and require an explicit `acq cp` or download
operation for return. It MUST NOT silently synchronize changes back into the
host checkout, upload host secrets or arbitrary parent paths, or claim clone
fetch-back semantics it cannot provide. A driver without either verified bind
mounts or this constrained fallback remains unsupported.

### Image, kit, provider, and secret boundaries

`--image` and `ACQ_IMAGE` remain the neutral image selection interface from
[ADR-0022](0022-neutral-image-override.md). An OpenShell-specific image setting
may be introduced only as a more-specific override with documented precedence;
it MUST NOT bypass validation, silently change the selected image, or replace
`ACQ_IMAGE`. Image selection applies at create time only.

The role split in [ADR-0030](0030-agent-kits-on-devenv-base.md) applies without
exception:

- Provider kits publish validated, static provider facts for lifecycle and
  credential plumbing. They do not render harness-specific configuration or
  own credentials.
- Agent kits install or expose the selected harness, declare its entrypoint,
  and render harness configuration from provider facts. They do not select a
  provider or define provider authority.
- Capability kits provide explicitly selected shared capabilities and cannot
  silently widen egress or credential access.

`acq` remains the sole authority for secret storage, selection, binding,
rotation, and propagation. The OpenShell gateway and compute driver receive
only the minimum scoped binding required for an approved host; agent kits,
provider kits, images, uploaded workspaces, and guest state MUST NOT contain or
become an authority for secret values. Secrets MUST NOT appear in command-line
arguments, logs, compatibility records, uploaded archives, or host-authoritative
config material. The adapter must preserve the existing `acq secret` interface;
it may not require users to configure a second, backend-owned secret store.

### Default-deny policy and agent ancestry

The adapter MUST compile the final effective egress policy before sandbox
creation from the selected provider and kit declarations. The baseline is
default deny. An allow rule must be explicit, host-validated, attributable to a
kit or user selection, limited to its approved destination and transport, and
visible in create output or equivalent inspection. Later kits cannot erase the
baseline or widen policy invisibly; egress follows the union-only, visible rule
from ADR-0030. Inbound exposure and port publication remain separately explicit
operations and MUST NOT be implied by an egress allow.

Network enforcement must cover the selected agent process and its complete
descendant process tree, including shells, package managers, git helpers,
devenv-managed processes, and agent-spawned background services. A driver that
enforces policy only on a launcher, proxy, or one process while descendants can
open unrestricted connections fails this gate. A driver that cannot demonstrate
default-deny enforcement for the configured ancestry remains unsupported.

### Host-authoritative state and lifecycle

All inputs that `acq` trusts to create, attach, heal, restart, or remove an
OpenShell sandbox MUST follow ADR-0035: held on the host and supplied at exec,
or materialized on the host and mounted read-only. This includes selected agent,
workspace mapping, clone mapping, driver/session identifier, ports, validated
kit environment, provider facts, policy compilation, and trusted startup code.
The adapter MUST NOT read any guest-generated marker, uploaded metadata, or
driver-returned mutable guest file as lifecycle authority.

The adapter contract remains responsible for explicit lifecycle, `acq cp`, port
publication/listing, kit application, secret propagation, and cleanup behavior.
It MUST clean host scratch, staged upload artifacts, host-authoritative state,
and driver resources on failed creates and `acq rm`; cleanup failures must be
reported with enough non-sensitive identifiers for an operator to remediate.

## Review and Verification

No OpenShell adapter may be marked supported, selected by default, or documented
as a production-ready backend until architecture and security review approve its
compatibility record and the applicable driver evidence. Review must specifically
confirm gateway ownership, credential data flow, TLS verification, bind-mount or
upload boundaries, policy compilation and ancestry coverage, host-authoritative
state, teardown behavior, and the exact support statement.

Implementation must include offline regression tests for backend resolution,
explicit-selection-only behavior, argument translation, image precedence,
mount/clone/upload selection, secret command shapes, policy compilation, and
host-state handling. For each driver seeking promotion, live verification must
exercise the gates in the table using the real CLI, gateway, and driver, not
mocks. Markdown linting, link validation, secret scanning, and relevant shell
checks must pass before review. The live verification transcript must mark an
unavailable host, gateway, MXC environment, or Kubernetes cluster `BLOCKED`; it
must never convert absence of evidence into a pass.

## Consequences

### Positive

- OpenShell can be explored without silently changing the default backend or
  overstating support for a driver that has not been measured.
- Existing neutral contracts for image selection, disposable workspaces, kits,
  provider facts, and `acq` secret ownership remain stable across backends.
- Default-deny policy and host-authoritative lifecycle configuration make the
  security boundary reviewable before remote execution is enabled.

### Negative / Trade-offs

- OpenShell is not a drop-in supported backend until each driver passes live
  promotion gates; experimental users must select it intentionally.
- Remote drivers may need the constrained upload/download path where equivalent
  host bind mounts are unavailable, trading convenience for explicit data flow.
- Compatibility records and repeated live verification add maintenance work on
  OpenShell, gateway, and driver upgrades.

### Compliance

- AC-3, AC-6, CM-5, and SI-17 are supported by explicit backend selection,
  least-privilege credentials, and fail-closed driver promotion.
- CM-2, CM-3, CM-6, and SI-7 are supported by versioned compatibility evidence
  and host-authoritative configuration rather than guest-controlled state.
- SC-7 and SC-8 are supported by default-deny, ancestry-complete network policy
  and reviewed gateway transport/authentication requirements.

## Links

- [ADR-0010: acq pluggable backends](0010-acq-pluggable-backends.md)
- [ADR-0022: neutral image override](0022-neutral-image-override.md)
- [ADR-0027: neutral clone option](0027-neutral-clone-option.md)
- [ADR-0030: agent kits on a devenv base](0030-agent-kits-on-devenv-base.md)
- [ADR-0035: host-authoritative sandbox configuration](0035-host-authoritative-sandbox-config.md)
- [GSA-TTS/agentic-coding-quickstart#574: define OpenShell backend contract](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/574)
