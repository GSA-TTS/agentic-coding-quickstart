---
title: "Use an isolated Python prerelease channel while Bash remains the default"
description: "Approved Python preview decisions, with Bash remaining the default and publication separately authorized"
status: approved
tier: 2
date: 2026-11-25
last_updated: "2026-11-25"
decision_makers: ["Peter (repository admin)", "Bret Mogilefsky", "William Zujkowski"]
category: deployment
nist_controls: ["CM-3", "CM-5", "SA-11", "SI-7", "SR-3", "AC-6"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: []
related_files: ["docs/adr/0042m-installation-runtime-ownership-and-update-channels.md", "docs/adr/0047m-acq-coexistence-mechanism.md", "docs/adr/0048m-windows-defaults-to-the-python-implementation.md", "docs/howto/acq.md", "release-please-config.json", "installer/assets.json"]
---

# ADR-0053: Use an isolated Python prerelease channel while Bash remains the default

## Context

Python is intended to replace Bash, including on Apple Silicon Macs. We want
people to try it before making that change for everyone. M1 is the opt-in
preview; M2 is the separately approved change of default. This ADR records the
approved goals and release choices. It does not authorize publication or assert
that publishing access, authority or qualification evidence is already in place.

## Agreed Decisions

- **M1 keeps Bash as the default.** Merge the reconciled rewrite into `main`
  without silently switching existing users or ordinary installations to Python.
- **Bash releases continue independently.** Its installers, Homebrew formula,
  npm route and stable tags must keep working during the preview.
- **M2 requires a separate decision.** Merging the rewrite or publishing a
  preview does not approve making Python the default.
- **Uninstall is an M2 gate.** Before the default changes, demonstrate that users
  can install, migrate and remove Python without losing their projects,
  credentials or existing configuration. Preview users must also be able to
  return to Bash; the implementation and acceptance work is tracked separately.
- **Python's macOS support is Apple Silicon only.** Intel macOS is out of scope
  for the replacement, not a reason to disrupt existing Bash releases.

**Decision record — 2026-11-25**

Bret approved all four recommendations:

1. **Release line:** use `v5.0.0-rc.N` for Python previews, published manually
   from an accepted `main` SHA. Bash's stable 4.x line and release-please
   automation remain independent; the pending Bash release stays a Bash release.
2. **Installation:** use a Bash-default dual-channel installer, with Python in
   a separate installation root and exposed as `acq-python`. Activate Homebrew's
   `acq-python` formula and npm's `python-preview` dist-tag (never `latest`) only
   after publishing authority and package contents are verified. Installing
   another version of the same npm package replaces the global install; users
   must be told explicitly that rollback means reinstalling their recorded
   Bash version.
3. **Release gates:** merge opt-in-safe code first, then require real-host
   evidence bound to the accepted `main` SHA before Python publication. Gates
   are channel-scoped: red Python qualification blocks the preview, not Bash
   releases. The repository admin owns check policy, signing, releases and
   evidence-ledger custody. A prerelease label is neither a qualification pass
   nor permission to disable a failing check.
4. **Integration and M2:** the integration owner merges `main` into the rewrite
   within one business day of behavior-affecting `main` merges, using signed
   merges, not rebases or cherry-picks, and a reconciliation checklist. M2
   requires credential-refresh, uninstall and native backout evidence, current
   qualification and explicit approval before Python becomes the default.

These are approved human decisions, not completed implementation or release
authorization. Packaging, access verification and evidence collection remain
prerequisites; publication requires separate explicit authorization.

## Alternatives and Tradeoffs

Making Python the default immediately is simpler, but contradicts the agreed
preview period. Reusing Bash's next minor version for the preview risks mixing
the two release lines. A 5.0.0 preview makes the eventual replacement clear,
but release automation must not mistake its tags for stable Bash releases.

Publishing from the rewrite branch would avoid waiting for the main merge,
but could ship something different from the integrated code. A second
release-please setup could automate previews, but adds competing release PRs
and version updates. A manual publisher is simpler for a short preview period,
at the cost of checking versions and release contents carefully each time.

Separate commands and installation locations make returning to Bash easier,
but add packaging work. They also do not make migration reversible: Python-only
configuration changes are not automatically copied back into Bash. Users need
that limitation explained before they change configuration in the preview.

## Links / Tracking

- [Runtime ownership](0042m-installation-runtime-ownership-and-update-channels.md), [coexistence](0047m-acq-coexistence-mechanism.md) and [qualification](0044m-live-cross-platform-qualification-matrix-and-transcript.md) describe the underlying contracts.
- Implementation and acceptance: GSA-TTS/agentic-coding-quickstart#709 and its children GSA-TTS/agentic-coding-quickstart#738, GSA-TTS/agentic-coding-quickstart#739, GSA-TTS/agentic-coding-quickstart#740, GSA-TTS/agentic-coding-quickstart#741, GSA-TTS/agentic-coding-quickstart#742, GSA-TTS/agentic-coding-quickstart#743.
- Pending Bash release: GSA-TTS/agentic-coding-quickstart#684. Uninstall work: GSA-TTS/agentic-coding-quickstart#711.

AI-assisted drafting by OpenCode.
