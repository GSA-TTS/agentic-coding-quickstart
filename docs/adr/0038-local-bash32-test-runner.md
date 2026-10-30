---
title: "Local Bash 3.2.57 test runner and its provisioning"
description: "Why scripts/test-acq-bash32 resolves a verified interpreter via an override, a signature-verified source build, or a digest-pinned OCI fetch, instead of requiring Nix or mise"
status: proposed
tier: 2
date: 2026-10-29
last_updated: "2026-10-29"
decision_makers: ["Bret Mogilefsky"]
category: development-process
nist_controls: ["SA-11", "SA-15", "SR-3", "CM-2"]
impact_level: low
ato_relevance: no
risk_treatment: n/a
supersedes: []
related_files: ["scripts/test-acq-bash32", "scripts/fetch-bash32-oci.py", "scripts/scan-heredoc-subst.py", "docs/howto/bash32-testing.md", "test/bats/152-bash32-runner.bats"]
---

# ADR-0038: Local Bash 3.2.57 test runner and its provisioning

## Context and Problem Statement

macOS ships GNU Bash 3.2.57, so acq must run on it. The only Bash 3.2 gate is the
CI job, which costs 9 to 16 minutes per round trip. In one day it caught several
failures that newer bash accepts: expanding an empty array under `set -u`, and a
here-document inside a process substitution whose body contained an apostrophe,
backtick or parenthesis (3.2 mis-parses the body at parse time). Developers,
including agents in Linux sandboxes, need the same interpreter locally. The
runner must not make ordinary `acq run` depend on any of this.

## Decision

Add `scripts/test-acq-bash32`, which resolves an interpreter, **requires
`BASH_VERSION` to be exactly `3.2.57`** (fail closed, exit 2), exposes it as `bash`
on a private PATH directory, then runs `scripts/test-acq-bats` with the caller's
arguments, or `--syntax` (`bash -n` over the host-side shell files plus a
heredoc scan). Resolution order: `ACQ_BASH32` (an explicit override that fails
the check is fatal, never skipped), the cache install, macOS `/bin/bash`, the CI
path. Provisioning is a plain command, not a prerequisite:

- `--install`: the CI job's approach. Download the tarball and detached signature
  from the same mirror list, import the vendored key, require its fingerprint to
  equal the one pinned in the workflow (a bats test asserts both copies match),
  verify the signature, build. Signer-authenticated.
- `--install-oci`: for sandboxes where GNU mirrors are blocked and there is no
  compiler. Fetch the official `bash:3.2.57` image layers from Docker Hub over
  HTTPS without Docker, verify the pinned per-architecture manifest digest and
  each layer digest, extract three files, run them via the image's musl loader.
  Content-pinned, not signer-authenticated; musl rather than glibc.

The heredoc scan (`scripts/scan-heredoc-subst.py`) is a best-effort line-based
heuristic; the real parser (`bash-3.2 -n`) is the authority. Its hazard rules (odd
quotes, unpaired backtick, unbalanced parentheses in a heredoc body inside `$( )`
or `<( )`) are the single definition; any other scanner for the same hazard should
be folded into this one rather than kept in parallel.

## Options considered

Tried for real in an offline-restricted aarch64 Linux sandbox (no compiler, no
sudo, GNU mirrors and `cache.nixos.org` blocked, GitHub, PyPI, npm, Debian and
Docker Hub reachable, Nix 2.24 installed, mise absent, Docker client without a
daemon):

| Option | Result here | Verdict |
| --- | --- | --- |
| devenv / Nix pinned bash 3.2 | Nix is present, but the binary cache and flake registry are unreachable, and bash 3.2 would have to build from source without a compiler in the store. Needs flake input pinning and a new tool for contributors. | Not implemented. Reasonable later on hosts with Nix and a cache; the override already accepts its output. |
| mise as launcher | Not installed; mise has no bash 3.2 backend of its own, so it would only wrap the Nix/devenv option. | Not implemented. |
| `ACQ_BASH32=/path` override | Works anywhere a 3.2.57 exists (macOS system bash, CI, any container). | Implemented. Primary interface. |
| Source build with signature check | Mirrors blocked and no compiler here; it is the stronger route elsewhere. | Implemented as `--install`. |
| Docker Hub OCI fetch | Worked: pinned digests verified, interpreter reports 3.2.57(1)-release. | Implemented as `--install-oci`; documented as weaker authentication. |

## Consequences

- Feedback drops from a CI round trip to seconds or minutes. Measured on a 2-core
  aarch64 Linux sandbox with the OCI interpreter: `--syntax` over 32 files 0.4 s;
  one small bats file about 3 s; the full suite about 15 minutes (883 s), roughly
  the CI cost, so use focused files while iterating.
- Validates the interpreter only, not BSD/macOS utilities (`sed`, `find`, `stat`,
  `xargs`); the CI gate stays authoritative and is unchanged.
- The musl build differs from the CI glibc build in libc behavior; an OCI-fetched
  pass is a strong hint, not proof. Because it runs through a loader, `$BASH` is
  the raw binary, so `103-kit-fetch-lifecycle.bats` (which re-executes `"$BASH"`)
  fails under that route.
- Risk: the pinned OCI digests could be withdrawn from Docker Hub; the failure is
  loud (digest or HTTP error) and the other routes remain.
