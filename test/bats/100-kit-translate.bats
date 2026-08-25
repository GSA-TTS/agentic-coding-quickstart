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
