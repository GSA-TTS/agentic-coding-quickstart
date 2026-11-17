# Architecture decision records

All recorded decisions, including retained fork identifiers. Status is recorded
in each ADR; corrections and amendments are part of the record.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-sbx-usai-agent-execution-architecture.md) | Use Docker SBX as Isolation Layer for USAi Agent Execution | accepted |
| [0002](0002-version-management-and-release-automation.md) | Adopt Semantic Versioning, Conventional Commits, and release-please for Release Automation | accepted |
| [0003](0003-usai-model-sync-and-default-selection.md) | Automate USAI Model Sync and Default Selection for OpenCode Templates | superseded |
| [0004](0004-playbook-submodule-shared-config.md) | Vendor the Playbook as a Submodule and Symlink Shared Config into the Sandbox Home | superseded |
| [0005](0005-kits-from-patterns-and-agent-trust-model.md) | Deliver Kits from agentic-coding-patterns by Pinned Reference; New Agent Trust Model | accepted |
| [0006](0006-git-ssh-sign-kit.md) | Apply the git-ssh-sign Kit by Default for SSH Commit Signing | accepted |
| [0007](0007-commit-verification-identity-guidance.md) | Commit Verification: Guide Identity Setup, Warn on Missing Identity | accepted |
| [0008](0008-usai-placeholder-recovery.md) | USAi Placeholder Recovery: Offer Session-Preserving Recreate, Then Non-Destructive Rebind | accepted |
| [0009](0009-require-sbx-0.35.0-in-place-kit-healing.md) | Require sbx >= 0.35.0 and Heal Pre-Kit Sandboxes In Place with sbx kit add | accepted |
| [0010](0010-acq-pluggable-backends.md) | Introduce acq Pluggable-Backend Wrapper and Deprecate qsbx | accepted |
| [0011](0011-msb-backend-and-neutral-kits.md) | Add msb (microsandbox) Backend and Neutral hybrid/v1 Kit Translation | accepted |
| [0012](0012-backend-neutral-key-rotation.md) | Make USAi Key Rotation Backend-Neutral via acq_backend_rotate_key | accepted |
| [0013](0013-per-sandbox-github-token-downscoping.md) | Constrain the GitHub Token Per-Sandbox to the Mounted Repositories | accepted |
| [0014](0014-neutral-port-publish-and-background-vocab.md) | Neutral Port-Publish and Background-Command Kit Vocabulary | accepted |
| [0015](0015-msb-post-hoc-port-publish-via-ssh.md) | Post-Hoc Port Publish on msb via SSH serve + Local Forwarding | accepted |
| [0016](0016-kit-bundle-provenance-and-stale-refresh.md) | Record Kit-Bundle Provenance and Offer a Safe Stale-Sandbox Refresh | accepted |
| [0017](0017-msb-create-time-startup-script-staging.md) | Stage msb kit startup commands as a create-time script for restart durability | accepted |
| [0018](0018-msb-balanced-egress-baseline.md) | Mirror the sbx "balanced" network policy as the msb default egress baseline | accepted |
| [0019](0019-msb-balanced-egress-is-egress-only.md) | Scope the msb balanced-egress deny-default to egress only (keep ingress default-allow) | accepted |
| [0020](0020-msb-oci-engine-via-podman.md) | Ensure an OCI container engine in msb sandboxes via rootless podman, not docker-in-docker | superseded |
| [0021](0021-msb-host-ssh-agent-forwarding-via-vsock.md) | Forward the Host ssh-agent into an msb Guest via --vsock | accepted |
| [0022](0022-neutral-image-override.md) | Backend-Neutral Custom Base Image (--image / ACQ_IMAGE) | accepted |
| [0023](0023-neutral-volumes-kit-vocabulary.md) | Neutral Volumes Kit Vocabulary | accepted |
| [0024](0024-neutral-user-facing-docs-vs-backend-specific.md) | Keep neutral user-facing docs in the quickstart repo; backend deep-dives stay symmetric | accepted |
| [0025](0025-adopt-bats-core-for-test-suite.md) | Adopt bats-core for the acq offline unit suite | accepted |
| [0026](0026-installation-and-distribution.md) | Installation and Distribution of acq for Non-Technical Users | accepted |
| [0027](0027-neutral-clone-option.md) | Backend-Neutral Disposable Primary Workspace (--clone) | accepted |
| [0028](0028-windows-native-secret-storage.md) | Windows-Native Secret Storage for acq | accepted |
| [0029](0029-windows-host-guest-path-forms.md) | Windows Host/Guest Path Forms and msb Argument Passthrough (MSYS) | accepted |
| [0030](0030-agent-kits-on-devenv-base.md) | Use Agent Kits on a Devenv-Enabled Agent-Less Base Image | accepted |
| [0031](0031-interactive-acq-configure.md) | Interactive `acq configure` for extra kits and token-scoping defaults | accepted |
| [0032](0032-msb-version-policy-and-migration-recovery.md) | msb Version Policy and Sandbox-State Migration Recovery | accepted |
| [0033](0033-msb-kit-env-is-guest-wide-for-lifecycle-commands.md) | msb kit environment[] is guest-wide for kit lifecycle commands | accepted |
| [0034](0034-host-port-selection-and-publish-override.md) | Per-Sandbox Host Port Selection and the --publish Override | accepted |
| [0035](0035-host-authoritative-sandbox-config.md) | Host-Authoritative Sandbox Configuration (no trust in guest-generated state) | accepted |
| [0036](0036-msb-foreground-node-invocation.md) | Use a fixed shell for foreground MSB Node kit commands | proposed |
| [0037](0037-sbx-trusted-startup-parity.md) | SBX Trusted-Startup Parity (read-only host mount vs native replay vs exec-time injection) | proposed |
| [0038](0038-local-bash32-test-runner.md) | Local Bash 3.2.57 test runner and its provisioning | accepted |
| [0038m](0038m-portable-acq-v1-compatibility-contract.md) | Portable acq v1 compatibility contract | accepted |
| [0039](0039-bash32-ci-shard-matrix-and-interpreter-handoff.md) | Shard the bash 3.2 CI suite and hand the interpreter to the shards | accepted |
| [0039m](0039m-rewrite-verification-and-test-retirement-strategy.md) | Rewrite verification and test-retirement strategy | accepted |
| [0040m](0040m-backend-adapter-capability-contract.md) | Backend adapter capability contract | accepted |
| [0041m](0041m-configuration-and-state-migration-behavior.md) | Configuration and state migration behavior | accepted |
| [0042m](0042m-installation-runtime-ownership-and-update-channels.md) | v1 installation, runtime ownership, and update channels | accepted |
| [0043m](0043m-language-neutral-test-vector-format-and-runners.md) | Language-neutral test-vector format and runners | accepted |
| [0044m](0044m-live-cross-platform-qualification-matrix-and-transcript.md) | Live cross-platform qualification matrix and transcript | accepted |
| [0045m](0045m-home-agent-handoff-and-bounded-autonomy-contract.md) | Home-agent handoff and bounded autonomy contract | accepted |
| [0046m](0046m-cli-dispatch-and-command-modules.md) | CLI dispatch layer and command modules | accepted |
| [0047m](0047m-acq-coexistence-mechanism.md) | acq coexistence mechanism (ACQ_IMPL runtime switch and --channel installer seam) | accepted |
| [0048m](0048m-windows-defaults-to-the-python-implementation.md) | Windows defaults to the Python implementation with acq's managed runtime | accepted |
| [0049m](0049m-ci-only-python-quality-tools.md) | CI-only Python quality tools, pinned with hashes | accepted |
| [0050m](0050m-release-signing-scaffolding.md) | Release signing scaffolding | accepted |
| [0051m](0051m-sbx-base-kit-is-acq-owned.md) | acq supplies the sbx sandbox base kit instead of a built-in agent | accepted |
| [0052m](0052m-msb-base-image-is-acq-owned.md) | msb's shell agent and the ro-mount canary use acq's base image | accepted |
