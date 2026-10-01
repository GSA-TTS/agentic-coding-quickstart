#!/usr/bin/env bats
#
# 101-sbx-grammar-acceptance.bats — does the REAL sbx still accept the kit
# grammar acq's translator emits? (#529)
#
# This is the one assertion 100-kit-translate.bats cannot make. That file runs
# under acq_setup_stubs, which puts a FAKE sbx on PATH whose fallthrough case is
# `*) exit 0` (scripts/test-acq-lib.sh) — so `sbx kit validate` against it exits
# 0 for any input, malformed or not. Its line
#
#     assert_regex "$spec" 'schemaVersion: "2"'
#
# therefore proves acq emits the text WE expect, and nothing about whether any
# sbx accepts it. It would keep passing after the real CLI stopped accepting "2".
#
# That is not hypothetical: #298 is this exact failure already having happened.
# sbx 0.38.0 shipped Kit spec v2, acq's translator was still emitting v1, and
# every `acq create` on the sbx backend failed at kit resolve.
#
# So this file deliberately does NOT call acq_setup_stubs — it needs the real
# binary on PATH. It is opt-in by nature: when sbx is absent (every
# GitHub-hosted runner) each test SKIPS with a reason. A skip here is an
# explicit "could not measure", not a pass: these tests must never be the only
# evidence that the grammar is accepted, and nothing in this file can report
# success without having actually run sbx.
#
# `sbx kit validate` is read-only and local: it creates no sandbox, runs no
# container, makes no network request, and pushes nothing to a registry.
#
# shellcheck shell=bats

load 'helper'

# The grammar version acq's translator emits. Kept as one constant so the
# "emits" and "is accepted" assertions below cannot disagree about which
# version is under test.
ACQ_EMITS_SCHEMA_VERSION='2'

_require_sbx() {
  command -v sbx >/dev/null 2>&1 || skip "sbx not on PATH — grammar acceptance UNVERIFIED"
}

# Write a minimal neutral hybrid/v1 kit and translate it with acq's own
# translator, so what gets validated is the translator's real output rather
# than a hand-written fixture that could drift from it.
_translate_minimal_kit() {
  local src="$1" out="$2"
  mkdir -p "$src"
  cat >"$src/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: grammar-probe
displayName: Grammar Probe
description: >
  Minimal neutral kit used to check that the sbx grammar acq emits is still
  accepted by the installed sbx.
caps:
  network:
    allow:
      - api.example.com:443
commands:
  - phase: startup
    user: "1000"
    # hybrid/v1 `command` is argv-list only (schemas/kit-hybrid-v1.schema.json:
    # "argv form (list of strings). To run a shell snippet, use
    # ["sh", "-c", "..."]"). A scalar here is invalid input: the translator
    # correctly drops it, sbx then rejects the result for a missing command, and
    # this guard would fail on its own bad fixture rather than on a grammar
    # shift. Keep the argv form.
    command:
      - sh
      - -c
      - |
        true
agentContext: |
  Grammar probe context.
SPEC
  bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$src"'" "'"$out"'"' \
    >/dev/null 2>&1
}

@test "sbx grammar: the real sbx accepts acq's translator output" {
  _require_sbx

  local src="$BATS_TEST_TMPDIR/src" out="$BATS_TEST_TMPDIR/out"
  _translate_minimal_kit "$src" "$out"

  # Guard the guard: if translation produced nothing, the validate below would
  # be measuring an empty directory. Fail loudly rather than pass vacuously.
  [ -f "$out/spec.yaml" ] || fail "translator produced no spec.yaml — nothing to validate"

  # Confirm the fixture is actually the version this file claims to test, so a
  # future translator change cannot silently move the goalposts.
  run grep -c "schemaVersion: \"$ACQ_EMITS_SCHEMA_VERSION\"" "$out/spec.yaml"
  [ "$output" -ge 1 ] || fail "translator did not emit schemaVersion \"$ACQ_EMITS_SCHEMA_VERSION\" — update this guard deliberately"

  run sbx kit validate "$out"
  if [ "$status" -ne 0 ]; then
    printf 'sbx version: %s\n' "$(sbx version 2>&1 | head -n1)" >&2
    printf 'sbx kit validate output:\n%s\n' "$output" >&2
    fail "the installed sbx REJECTED acq's translator output — the emitted grammar is no longer accepted (see #529, and #298 for the last time this happened)"
  fi
}

@test "sbx grammar: the version acq emits is in sbx's supported set" {
  _require_sbx

  # sbx names its supported versions in its own rejection text, e.g.
  #   error: manifest: unsupported schemaVersion "9" (supported: [1 2])
  # Asking about a version that will never exist is a cheap, read-only way to
  # have sbx enumerate what it DOES support, without parsing --help output that
  # carries no such list.
  local probe="$BATS_TEST_TMPDIR/probe"
  mkdir -p "$probe"
  cat >"$probe/spec.yaml" <<'SPEC'
schemaVersion: "999"
kind: mixin
name: unsupported-probe
displayName: Unsupported Probe
description: Deliberately unsupported version, to make sbx list what it supports.
SPEC

  run sbx kit validate "$probe"
  [ "$status" -ne 0 ] || fail "sbx accepted schemaVersion \"999\" — this probe no longer enumerates the supported set"

  # If the message shape changed, say so instead of silently concluding nothing.
  case "$output" in
    *"supported: ["*) : ;;
    *) skip "sbx no longer prints a 'supported: [...]' list — supported set UNVERIFIED (output: $output)" ;;
  esac

  local supported
  supported=$(printf '%s\n' "$output" | sed -n 's/.*supported: \[\([^]]*\)\].*/\1/p' | head -n1)
  [ -n "$supported" ] || fail "could not parse the supported-version list from: $output"

  case " $supported " in
    *" $ACQ_EMITS_SCHEMA_VERSION "*) : ;;
    *)
      fail "acq emits schemaVersion \"$ACQ_EMITS_SCHEMA_VERSION\" but the installed sbx supports [$supported] — translator and CLI have diverged (#529)"
      ;;
  esac
}

# The minimal fixture above covers the common path. The built-in kits exercise
# considerably more of the vocabulary, and they are NOT vendored here — acq
# fetches them from agentic-coding-patterns at a pinned ref (common.sh
# PATTERNS_KIT_REF), over git+https. Fetching inside this suite would make it
# network-dependent, which the offline contract forbids, so this fixture instead
# reproduces the widest shape a shipped kit uses locally: every optional
# hybrid/v1 block that reaches a different part of the sbx spec.
#
# Verified against the real thing when written: translating the shipped `paseo`
# kit (the broadest, with environment + publishedPorts) and `usai-provider` (the
# only one with a provenance block) both produced specs the installed sbx
# accepted, and the translated paseo spec carried agentInstructions, environment,
# permissions.network, ports, and both setup phases. This fixture targets that
# same set.
@test "sbx grammar: the real sbx accepts a translated kit using every optional block" {
  _require_sbx

  local src="$BATS_TEST_TMPDIR/wide" out="$BATS_TEST_TMPDIR/wideout"
  mkdir -p "$src/files/home/tool"
  printf 'payload\n' >"$src/files/home/tool/config"
  cat >"$src/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: wide-probe
displayName: Wide Probe
description: >
  Exercises every optional hybrid/v1 block that reaches a distinct part of the
  translated sbx spec, so a grammar change in any of them is caught here rather
  than at a developer's next `acq create`.
caps:
  network:
    tier: strict
    allow:
      - api.example.com:443
      - "*.example.com"
environment:
  TOOL_MODE: verbose
files:
  - path: /home/agent/tool/config
    mode: "0644"
    source: files/home/tool/config
publishedPorts:
  - guest: 3000
    host: 3000
    protocol: tcp
    name: web-ui
commands:
  - phase: install
    user: "0"
    command:
      - sh
      - -c
      - |
        true
  - phase: startup
    user: "1000"
    background: true
    command:
      - sh
      - -c
      - |
        true
agentContext: |
  Wide probe context.
SPEC

  bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$src"'" "'"$out"'"' \
    >/dev/null 2>&1

  [ -f "$out/spec.yaml" ] || fail "translator produced no spec.yaml — nothing to validate"

  # Assert the translation actually populated the blocks this test exists to
  # cover. Without this, a translator that silently dropped them would still
  # reach a VALID verdict below and the test would claim coverage it does not
  # have — the same defect as validating against the stub.
  local spec; spec=$(cat "$out/spec.yaml")
  local block
  for block in 'permissions:' 'environment:' 'ports:' 'setup:' '  install:' '  startup:' 'agentInstructions:'; do
    case "$spec" in
      *"$block"*) : ;;
      *) fail "translated spec is missing '$block' — this guard is no longer covering it" ;;
    esac
  done

  run sbx kit validate "$out"
  if [ "$status" -ne 0 ]; then
    printf 'sbx version: %s\n' "$(sbx version 2>&1 | head -n1)" >&2
    printf 'translated spec:\n%s\n' "$spec" >&2
    printf 'sbx kit validate output:\n%s\n' "$output" >&2
    fail "the installed sbx REJECTED a translated kit using the full optional vocabulary (see #529, and #298 for the last time this happened)"
  fi
}
