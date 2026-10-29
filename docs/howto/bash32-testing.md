---
title: "Run the acq suite under Bash 3.2 locally"
description: "How to catch Bash 3.2.57 (macOS system bash) incompatibilities before CI, with scripts/test-acq-bash32"
status: canonical
tier: 2
last_updated: "2026-10-29"
audience: "developers"
keywords: ["bash 3.2", "macos", "bats", "test-acq-bash32", "compatibility", "sandbox"]
related_files: ["scripts/test-acq-bash32", "scripts/scan-heredoc-subst.py", "scripts/fetch-bash32-oci.py", "test/bats/152-bash32-runner.bats", "docs/adr/0038-local-bash32-test-runner.md", "CONTRIBUTING.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# Run the acq suite under Bash 3.2 locally

macOS ships GNU Bash 3.2.57, so `acq` and its adapters must run on it. Newer bash
accepts code that 3.2 rejects, so the problem normally shows up only in the CI
gate ("acq offline suite under bash 3.2", built from source, 9 to 16 minutes per
round trip). `scripts/test-acq-bash32` gives the same interpreter locally.

## Commands

```sh
scripts/test-acq-bash32 --syntax                              # seconds: bash 3.2 -n + heredoc scan
scripts/test-acq-bash32 test/bats/72-msb-agent-user.bats      # focused bats under bash 3.2
scripts/test-acq-bash32                                       # full offline suite under bash 3.2
scripts/test-acq-bash32 --which                               # show the resolved interpreter
scripts/test-acq-bash32 --lint [FILE...]                      # heredoc scan only; works with any bash
```

Arguments after the script name go straight to `scripts/test-acq-bats`, so file
arguments, `ACQ_BATS_JOBS` and `ACQ_BATS_TIMING` behave as documented there.

The interpreter is exposed as `bash` on a private `PATH` directory for the run, so
bats and nested `#!/usr/bin/env bash` scripts also use 3.2. If the interpreter does
not report exactly `3.2.57`, the command exits 2 and runs nothing.

## Get a Bash 3.2.57

Resolution order (first match wins; each must report `BASH_VERSION` exactly `3.2.57`):

1. `ACQ_BASH32=/path/to/bash`. An explicit override that fails the check is fatal.
2. The cache install at `~/.cache/acq/bash-3.2.57` (`ACQ_BASH32_PREFIX` overrides).
3. `/bin/bash` on macOS.
4. `/opt/bash32/bin/bash` (the CI location).

If none exists, install one:

| Situation | Command |
| --- | --- |
| macOS | nothing to do; `/bin/bash` is 3.2.57 |
| Linux with a compiler and GNU mirrors reachable | `scripts/test-acq-bash32 --install` |
| Linux sandbox without a compiler or GNU mirrors, Docker Hub reachable (all but one test file) | `scripts/test-acq-bash32 --install-oci` |
| You already have one (Nix, a container, CI) | `export ACQ_BASH32=/path/to/bash` |

`--install` downloads `bash-3.2.57.tar.gz` and its detached signature from GNU
mirrors, imports the vendored release key
(`.github/keys/chet-ramey-bash-release-signing-key.asc`), requires its fingerprint
to equal the one the CI job pins, verifies the signature, and only then builds.
It is the same authentication as the CI gate and fails closed.

`--install-oci` downloads the official Docker Hub `bash:3.2.57` image's layers
over HTTPS without Docker, checks the manifest and every layer against pinned
sha256 digests, extracts three files, and runs them through the image's own musl
loader. This is content-pinned but not signer-authenticated, and the musl build is
not the glibc build CI uses; treat it as a convenience and let CI be the judge.
Nothing is piped into a shell. Limitation: because the binary runs through a loader,
`$BASH` points at the raw binary, so the one test that re-executes `"$BASH"`
directly (`103-kit-fetch-lifecycle.bats`) fails under this route; judge that file
with a source-built interpreter or CI.

Both install routes reach the network (GNU mirrors, or `auth.docker.io` and
`registry-1.docker.io`). In an agent session these are outside the project's
authorized endpoints, so ask the user before running them.

## What each level proves

| Level | Command | Catches |
| --- | --- | --- |
| Heredoc scan | `--lint` | A here-document inside `$( )` or `<( )` whose body has an odd `'` or `"`, an unpaired backtick, or unbalanced parentheses. 3.2 fails at parse time; newer bash does not. |
| Syntax | `--syntax` | Anything bash 3.2 cannot parse (for example `;&` in `case`), in `acq`, `acq.backends/*.sh`, `install.sh`, bash/sh scripts under `scripts/`, and `test/bats/helper.bash`. |
| Focused or full bats | file args or none | Runtime differences, such as expanding an empty array under `set -u` (`"${arr[@]}"`), which 3.2 treats as unbound. |
| CI gate | pull request | The authoritative, source-authenticated check. |

The heredoc scan is a best-effort line-based heuristic, not a shell parser. It can
miss exotic layouts and can report a false positive; `--syntax FILE` asks the real
3.2 parser and is the authority. `--lint` also scans `test/bats/*.bats`. `--syntax` cannot see runtime-only
differences; run the bats levels for those.

## Limits

This validates the Bash interpreter only. It does not reproduce BSD/macOS utility
behavior (`sed`, `find`, `stat`, `xargs`, `date`, filesystem semantics), because the
tools around bash are still the Linux ones. Nothing here is needed to use `acq`; it
is development tooling only. Design and the options considered are in
[ADR-0038](../adr/0038-local-bash32-test-runner.md).
