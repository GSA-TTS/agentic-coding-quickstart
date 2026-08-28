#!/usr/bin/env bats
#
# 100-kit-translate.bats — bats port of scripts/test-acq.d/100-kit-translate.sh
# (ADR-0025)
#
# kit-translate: neutral hybrid/v1 -> sbx-v2 synthesis (offline). Translates
# local neutral kits and asserts the synthesized sbx-v2 spec; also the
# non-interactive git+https fetch hardening (#207) and the environment
# vocabulary. Helpers run in isolated subshells.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "translate: neutral hybrid/v1 synthesizes a complete sbx-v2 spec" {
  local tkit="$STUBDIR/tkit" tout="$STUBDIR/tout"
  mkdir -p "$tkit/files/home/tool"
  printf 'payload\n' > "$tkit/files/home/tool/config"
  cat >"$tkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: translate-kit
displayName: Translate Kit
description: >
  A kit exercising the neutral->sbx-v2 translation, including a multi-line
  literal block command and a colon: inside the description.
caps:
  network:
    allow:
      - api.example.com:443
      - "*.example.com"
files:
  - path: /home/agent/tool/config
    mode: "0644"
    source: files/home/tool/config
commands:
  - phase: install
    user: "0"
    command:
      - sh
      - -c
      - |
        set -eu
        echo "line one"
        echo "line two"
  - phase: startup
    user: "1000"
    command:
      - node
      - /home/agent/tool/run.mjs
publishedPorts:
  - guest: 3000
    host: 3000
    protocol: tcp
    name: web-ui
  - guest: 4096
    protocol: tcp
    name: api
agentContext: |
  Translate kit context.
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$tkit"'" "'"$tout"'" >/dev/null 2>&1'
  local spec; spec=$(cat "$tout/spec.yaml")
  assert_regex "$spec" 'schemaVersion: "2"'
  assert_regex "$spec" 'permissions:'
  assert_regex "$spec" 'api\.example\.com:443'
  refute_regex "$spec" 'caps:'
  refute_regex "$spec" 'commands:'
  assert_regex "$spec" 'setup:'
  assert_regex "$spec" '  install:'
  assert_regex "$spec" '  startup:'
  assert_regex "$spec" 'line two'
  assert_regex "$spec" 'agentInstructions:'
  assert_regex "$spec" 'Translate kit context\.'
  # #220: wildcard + host:port allow entries must be YAML-quoted.
  assert_regex "$spec" "- '\*\.example\.com'"
  assert_regex "$spec" "- 'api\.example\.com:443'"
  # #224: neutral publishedPorts -> sbx-v2 ports (keyed on container).
  assert_regex "$spec" 'ports:'
  refute_regex "$spec" 'publishedPorts:'
  assert_regex "$spec" '- container: 3000'
  assert_regex "$spec" '- container: 4096'
  assert_regex "$spec" 'protocol: tcp'
  assert_regex "$spec" 'name: web-ui'
  assert [ -f "$tout/files/home/tool/config" ]
}

@test "translate: an sh -c startup command emits under setup.startup argv" {
  local shkit="$STUBDIR/shkit" shout="$STUBDIR/shout"
  mkdir -p "$shkit"
  cat >"$shkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: sh-startup-kit
displayName: Sh Startup Kit
description: startup uses sh -c
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - |
        set -eu
        echo hello
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$shkit"'" "'"$shout"'" >/dev/null 2>&1'
  local spec; spec=$(cat "$shout/spec.yaml")
  refute_regex "$spec" 'commands:'
  assert_regex "$spec" 'setup:'
  assert_regex "$spec" '  startup:'
  assert_regex "$spec" '        - sh'
  assert_regex "$spec" 'echo hello'
}

@test "#381: home-staged mode fields synthesize ONE combined setup.install chmod step" {
  local mkit="$STUBDIR/mkit" mout="$STUBDIR/mout"
  mkdir -p "$mkit/files/home/tool"
  printf '#!/bin/sh\necho hi\n' > "$mkit/files/home/tool/run.sh"
  printf 'cfg\n' > "$mkit/files/home/tool/config"
  cat >"$mkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: mode-kit
displayName: Mode Kit
description: kit with declared file modes
files:
  - path: /home/agent/tool/run.sh
    mode: "0755"
    source: files/home/tool/run.sh
  - path: /home/agent/tool/config
    mode: "0644"
    source: files/home/tool/config
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$mkit"'" "'"$mout"'" >/dev/null 2>&1'
  local spec; spec=$(cat "$mout/spec.yaml")
  assert_regex "$spec" 'setup:'
  assert_regex "$spec" '  install:'
  assert_regex "$spec" "chmod 0755 '/home/agent/tool/run\.sh'"
  assert_regex "$spec" "chmod 0644 '/home/agent/tool/config'"
  assert_regex "$spec" 'user: "0"'
  assert_regex "$spec" 'description: .*sbx pins files/ payloads to 0644'
  # ONE combined install entry, not one per file.
  assert_equal "$(grep -c '    - command:' "$mout/spec.yaml")" "1"
}

@test "#381: the chmod install step is emitted BEFORE the kit's own install commands" {
  local okit="$STUBDIR/okit" oout="$STUBDIR/oout"
  mkdir -p "$okit/files/home"
  printf '#!/bin/sh\n' > "$okit/files/home/tool.sh"
  cat >"$okit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: order-kit
displayName: Order Kit
description: chmod must precede kit install commands
files:
  - path: /home/agent/tool.sh
    mode: "0755"
    source: files/home/tool.sh
commands:
  - phase: install
    user: "0"
    command:
      - sh
      - -c
      - |
        /home/agent/tool.sh
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$okit"'" "'"$oout"'" >/dev/null 2>&1'
  local chmod_line install_line
  chmod_line=$(grep -n "chmod 0755" "$oout/spec.yaml" | head -1 | cut -d: -f1)
  install_line=$(grep -n '/home/agent/tool\.sh$' "$oout/spec.yaml" | tail -1 | cut -d: -f1)
  assert [ -n "$chmod_line" ]
  assert [ -n "$install_line" ]
  assert [ "$chmod_line" -lt "$install_line" ]
}

@test "#381: a mode-less kit emits no chmod step (output unchanged)" {
  local nkit="$STUBDIR/nkit" nout="$STUBDIR/nout"
  mkdir -p "$nkit/files/home"
  printf 'x\n' > "$nkit/files/home/f"
  cat >"$nkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: nomode-kit
displayName: Nomode Kit
description: kit with no file modes
files:
  - path: /home/agent/f
    source: files/home/f
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$nkit"'" "'"$nout"'" >/dev/null 2>&1'
  local spec; spec=$(cat "$nout/spec.yaml")
  refute_regex "$spec" 'chmod'
  refute_regex "$spec" 'setup:'
}

@test "#381: a workspace-targeted mode warns and gets no chmod" {
  local wkit="$STUBDIR/wkit" wout="$STUBDIR/wout"
  mkdir -p "$wkit/files/home" "$wkit/files/workspace"
  printf '#!/bin/sh\n' > "$wkit/files/home/h.sh"
  printf '#!/bin/sh\n' > "$wkit/files/workspace/w.sh"
  cat >"$wkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: wsmode-kit
displayName: Wsmode Kit
description: workspace-targeted modes cannot be applied on sbx
files:
  - path: /home/agent/h.sh
    mode: "0755"
    source: files/home/h.sh
  - path: /workspace/w.sh
    mode: "0755"
    source: files/workspace/w.sh
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$wkit"'" "'"$wout"'" 2>&1 >/dev/null'
  assert_output --partial 'mode'
  assert_output --partial '/workspace/w.sh'
  local spec; spec=$(cat "$wout/spec.yaml")
  assert_regex "$spec" "chmod 0755 '/home/agent/h\.sh'"
  refute_regex "$spec" "chmod 0755 '/workspace/w\.sh'"
}

@test "#207: a git+https kit fetch is non-interactive and neutralizes credentials" {
  local gitlog="$STUBDIR/git-invocations.log"; : >"$gitlog"
  cat >"$STUBDIR/git" <<GITSTUB
#!/usr/bin/env bash
printf 'PROMPT=%s ARGS=%s\n' "\${GIT_TERMINAL_PROMPT:-UNSET}" "\$*" >>"$gitlog"
case "\$*" in
  *fetch*) exit 0 ;;
  *checkout*) mkdir -p "integrations/isolation/acq-kits/usai-provider"; exit 0 ;;
  *) exit 0 ;;
esac
GITSTUB
  chmod +x "$STUBDIR/git"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    kit_translate_fetch "git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=integrations/isolation/acq-kits/usai-provider" "'"$STUBDIR"'/kitdest"
  ' >/dev/null 2>&1 || true
  local fetchline anonline
  fetchline=$(grep 'fetch' "$gitlog" | head -1)
  assert_regex "$fetchline" 'PROMPT=0'
  anonline=$(grep -m1 'credential.helper=' "$gitlog" || true)
  assert_regex "$anonline" 'credential\.helper='
  assert_regex "$anonline" 'insteadOf='
}

@test "#207: a hostile dir= (path traversal) is rejected before any git call" {
  : >"$STUBDIR/git-invocations.log"
  cat >"$STUBDIR/git" <<'GITSTUB'
#!/usr/bin/env bash
printf 'CALLED\n' >>"$STUBDIR/git-invocations.log"
exit 0
GITSTUB
  chmod +x "$STUBDIR/git"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    kit_translate_fetch "git+https://github.com/x/y.git#ref=deadbeef&dir=../../etc" "'"$STUBDIR"'/travdest" 2>&1
  '
  assert_output --partial 'unsafe kit dir'
  assert_equal "$(cat "$STUBDIR/git-invocations.log" 2>/dev/null || true)" ""
}

@test "env: kit_spec_env parses valid pairs, drops an unsafe name, sbx-v2 emits environment.variables" {
  local ekit="$STUBDIR/ekit" eout="$STUBDIR/eout"
  mkdir -p "$ekit"
  cat >"$ekit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: env-kit
displayName: Env Kit
description: exercises the environment vocabulary
environment:
  OPENCODE_CONFIG: /home/agent/usai-config/opencode.jsonc
  GITLAB_HOST: gitlab.example.gov
  "1BAD": should-be-dropped
commands:
  - phase: startup
    user: "1000"
    command:
      - node
      - /home/agent/run.mjs
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_env "'"$ekit"'/spec.yaml" 2>/dev/null'
  assert_output --partial 'OPENCODE_CONFIG'
  assert_output --partial 'gitlab.example.gov'
  refute_output --partial '1BAD'

  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_env "'"$ekit"'/spec.yaml" 2>&1 >/dev/null'
  assert_output --partial 'unsafe name: 1BAD'

  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$ekit"'" "'"$eout"'" >/dev/null 2>&1'
  local spec; spec=$(cat "$eout/spec.yaml")
  assert_regex "$spec" 'environment:'
  assert_regex "$spec" '  variables:'
  assert_regex "$spec" 'OPENCODE_CONFIG: /home/agent/usai-config/opencode\.jsonc'
  refute_regex "$spec" '1BAD'
}

@test "env: a block-scalar environment value is dropped with a warning, not mangled" {
  # environment[] values are single-line string scalars only. A YAML block
  # scalar used to come out mangled (the value became a literal `|`/`>`), and
  # its indented continuation lines containing a colon parsed as BOGUS extra
  # env entries. The parser must drop the entry, warn, and skip the block body.
  local bkit="$STUBDIR/blockenv-kit"
  mkdir -p "$bkit"
  cat >"$bkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: blockenv-kit
displayName: BlockEnv Kit
description: block scalar env values must be rejected
environment:
  GOOD_VAR: single-line-ok
  MULTI_VAR: |
    first line
    looks_like: an-entry
  FOLDED_VAR: >-
    folded text
  AFTER_VAR: still-parsed
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_env "'"$bkit"'/spec.yaml" 2>/dev/null'
  assert_output --partial 'GOOD_VAR'
  assert_output --partial 'AFTER_VAR'
  refute_output --partial 'MULTI_VAR'
  refute_output --partial 'FOLDED_VAR'
  refute_output --partial 'looks_like'

  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_env "'"$bkit"'/spec.yaml" 2>&1 >/dev/null'
  assert_output --partial 'MULTI_VAR'
  assert_output --partial 'FOLDED_VAR'
  assert_output --partial 'block scalar'
}

@test "env: kit validate reports a block-scalar environment value as an error" {
  local bkit="$STUBDIR/blockenv-vkit"
  mkdir -p "$bkit"
  cat >"$bkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: blockenv-vkit
displayName: BlockEnv VKit
description: validate flags block scalar env values
environment:
  OK_VAR: fine
  MULTI_VAR: |
    first line
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_validate "'"$bkit"'" 2>&1'
  assert_failure
  assert_output --partial 'MULTI_VAR'
  assert_output --partial 'single-line'
}

# Regression guard: the files[].mode validators must NOT use a brace-interval
# quantifier (/^[0-7]{3,4}$/ or /^0[0-7]{3}$/). mawk — the default awk on
# Debian/Ubuntu — has no interval-expression support, so that form matches
# NOTHING under mawk and every kit's files are silently dropped (parser site)
# or every valid mode is reported invalid (kit_validate raw-scan site, whose
# stricter leading-zero pattern is /^0[0-7][0-7][0-7]$/ — #381). All mode
# validator sites must stay longhand. This source-level check catches a
# regression regardless of which awk the test runner ships (gawk/BSD-awk would
# not reproduce the failure at runtime).
@test "kit-translate: mode validator uses no {n,m} interval regex (mawk-safe)" {
  run grep -nE '(cur_mode|v) !~ /\^0?\[0-7\]\{' "$REPO_ROOT/acq.backends/kit-translate.sh"
  assert_failure   # no match -> exit 1 -> the interval form is absent
}

# The longhand octal pattern accepts 3- and 4-digit octal modes and rejects
# non-octal / over-long values, portably across awk implementations.
@test "kit-translate: longhand octal mode pattern accepts valid, rejects junk" {
  run bash -c 'printf "0755\n755\nabc\n07555\n" | awk "\$0 ~ /^[0-7][0-7][0-7][0-7]?\$/ {print}"'
  assert_output $'0755\n755'
}
