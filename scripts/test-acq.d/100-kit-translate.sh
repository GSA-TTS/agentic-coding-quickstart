#!/usr/bin/env bash
#
# 100-kit-translate — neutral hybrid/v1 -> sbx-v2 synthesis
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 10. kit-translate: neutral hybrid/v1 -> sbx-v2 synthesis (offline)
# ===========================================================================

make_stubs; load_acq
# Build a local neutral kit and translate it to an sbx-v2 kit dir; assert the
# synthesized spec is sbx schemaVersion "2" and carries only fields current sbx
# accepts.
tkit="$STUBDIR/tkit"
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
tout="$STUBDIR/tout"
( . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  kit_translate_to_sbx "$tkit" "$tout" >/dev/null ) 2>/dev/null
sbxspec=$(cat "$tout/spec.yaml" 2>/dev/null || true)
assert_contains "translate: emits sbx schemaVersion 2" "$sbxspec" 'schemaVersion: "2"'
assert_contains "translate: emits permissions block" "$sbxspec" "permissions:"
assert_contains "translate: carries permissions.network.allow" "$sbxspec" "api.example.com:443"
assert_not_contains "translate: omits unsupported caps field" "$sbxspec" "caps:"
assert_not_contains "translate: omits unsupported commands field" "$sbxspec" "commands:"
assert_contains "translate: emits setup block" "$sbxspec" "setup:"
assert_contains "translate: emits setup install phase" "$sbxspec" "  install:"
assert_contains "translate: emits setup startup phase" "$sbxspec" "  startup:"
assert_contains "translate: preserves multi-line command body" "$sbxspec" "line two"
assert_contains "translate: emits agentInstructions block" "$sbxspec" "agentInstructions:"
assert_contains "translate: carries agent context" "$sbxspec" "Translate kit context."
# Regression: a wildcard-subdomain allow host (leading `*`) MUST be
# quoted, or YAML parses the `*` as an alias and the sbx spec is invalid. The
# host:port form also contains a `:` and must survive. Assert both are quoted.
assert_contains "translate: quotes wildcard allow host (#220)" "$sbxspec" "- '*.example.com'"
assert_contains "translate: quotes host:port allow entry (#220)" "$sbxspec" "- 'api.example.com:443'"
# ADR-0014: the NEUTRAL top-level publishedPorts MUST synthesize the sbx-v2
# ports block (keyed on `container` = the guest port).
assert_contains "translate: emits ports block (#224)" "$sbxspec" "ports:"
assert_not_contains "translate: omits unsupported publishedPorts block (#224)" "$sbxspec" "publishedPorts:"
assert_contains "translate: neutral publishedPorts carries container 3000 (#224)" "$sbxspec" "- container: 3000"
assert_contains "translate: neutral publishedPorts carries container 4096 (#224)" "$sbxspec" "- container: 4096"
assert_contains "translate: publishedPorts carries protocol (#224)" "$sbxspec" "protocol: tcp"
assert_contains "translate: publishedPorts carries name (#224)" "$sbxspec" "name: web-ui"
# The static payload file is copied under files/.
if [ -f "$tout/files/home/tool/config" ]; then
  pass "translate: copies files/ payload tree"
else
  fail "translate: copies files/ payload tree" "missing $tout/files/home/tool/config"
fi
cleanup_stubs

# 10a2. A `sh -c` STARTUP command (zscaler/playbook shape) emits under the v2
#       setup.startup argv list.
make_stubs; load_acq
shkit="$STUBDIR/shkit"; mkdir -p "$shkit"
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
shout="$STUBDIR/shout"
( . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  kit_translate_to_sbx "$shkit" "$shout" >/dev/null ) 2>/dev/null
shspec=$(cat "$shout/spec.yaml" 2>/dev/null || true)
assert_not_contains "translate: sh -c startup omits unsupported commands key" "$shspec" "commands:"
assert_contains "translate: sh -c startup emits setup" "$shspec" "setup:"
assert_contains "translate: sh -c startup emits startup phase" "$shspec" "  startup:"
assert_contains "translate: sh -c startup emits argv seq (- sh)" "$shspec" "        - sh"
assert_contains "translate: sh -c body emitted under setup.startup" "$shspec" "echo hello"
cleanup_stubs

# 10a2b. A git+https kit fetch MUST be NON-INTERACTIVE. Stub `git` to
#        record its env + args; drive _resolve_kit against a git+https ref and
#        assert the fetch ran with GIT_TERMINAL_PROMPT=0 and the anonymous
#        credential-neutralizing -c flags — i.e. it can never hang on a
#        "Username for 'https://github.com'" prompt.
make_stubs; load_acq
gitlog="$STUBDIR/git-invocations.log"
: >"$gitlog"
cat >"$STUBDIR/git" <<GITSTUB
#!/usr/bin/env bash
# Record the terminal-prompt env + the full argv for every git call.
printf 'PROMPT=%s ARGS=%s\n' "\${GIT_TERMINAL_PROMPT:-UNSET}" "\$*" >>"$gitlog"
# Make the anonymous 'fetch' SUCCEED so we exercise the happy path + populate
# the sparse dir so checkout has something.
case "\$*" in
  *fetch*) exit 0 ;;
  *checkout*) mkdir -p "integrations/isolation/acq-kits/usai-provider"; exit 0 ;;
  *) exit 0 ;;
esac
GITSTUB
chmod +x "$STUBDIR/git"
(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  kit_translate_fetch "git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=integrations/isolation/acq-kits/usai-provider" "$STUBDIR/kitdest"
) >/dev/null 2>&1 || true
fetchline=$(grep 'fetch' "$gitlog" | head -1)
assert_contains "#207: kit fetch disables interactive prompt" "$fetchline" "PROMPT=0"
# The first (anonymous) attempt neutralizes any inherited credential helper +
# github insteadOf rewrite so a public fetch never authenticates.
anonline=$(grep -m1 'credential.helper=' "$gitlog" || true)
assert_contains "#207: anon fetch neutralizes credential.helper" "$anonline" "credential.helper="
assert_contains "#207: anon fetch neutralizes github insteadOf" "$anonline" "insteadOf="
cleanup_stubs

# 10a2c. Hardening: a hostile dir= (path traversal) must be rejected before
#        any git call — no absolute paths, no '..', safe charset only.
make_stubs; load_acq
: >"$STUBDIR/git-invocations.log"
cat >"$STUBDIR/git" <<'GITSTUB'
#!/usr/bin/env bash
printf 'CALLED\n' >>"$STUBDIR/git-invocations.log"
exit 0
GITSTUB
chmod +x "$STUBDIR/git"
trav_out=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  kit_translate_fetch "git+https://github.com/x/y.git#ref=deadbeef&dir=../../etc" "$STUBDIR/travdest" 2>&1
) || true
assert_contains "#207: traversal dir= is rejected" "$trav_out" "unsafe kit dir"
git_called=$(cat "$STUBDIR/git-invocations.log" 2>/dev/null || true)
assert_eq "#207: no git call on rejected dir=" "" "$git_called"
cleanup_stubs

# 10a3. environment vocabulary: kit_spec_env parses NAME/value pairs, DROPS an
#       unsafe env var name (with a stderr warning), and kit_translate_to_sbx
#       emits an sbx-v2 `environment.variables` block for the valid entries.
make_stubs; load_acq
ekit="$STUBDIR/ekit"; mkdir -p "$ekit"
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
env_parse=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  kit_spec_env "$ekit/spec.yaml" 2>/dev/null
)
assert_contains "env: parses OPENCODE_CONFIG" "$env_parse" "OPENCODE_CONFIG"
assert_contains "env: parses GITLAB_HOST value" "$env_parse" "gitlab.example.gov"
env_warn=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  kit_spec_env "$ekit/spec.yaml" 2>&1 >/dev/null
)
assert_contains "env: unsafe env var NAME is dropped+warned" "$env_warn" "unsafe name: 1BAD"
assert_not_contains "env: unsafe env var NAME not emitted" "$env_parse" "1BAD"
# sbx-v2 synthesis emits environment.variables.
eout="$STUBDIR/eout"
( . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  kit_translate_to_sbx "$ekit" "$eout" >/dev/null ) 2>/dev/null
espec=$(cat "$eout/spec.yaml" 2>/dev/null || true)
assert_contains "env: sbx-v2 emits environment block" "$espec" "environment:"
assert_contains "env: sbx-v2 emits variables map" "$espec" "  variables:"
assert_contains "env: sbx-v2 emits OPENCODE_CONFIG var" "$espec" "OPENCODE_CONFIG: /home/agent/usai-config/opencode.jsonc"
assert_not_contains "env: sbx-v2 drops unsafe var name" "$espec" "1BAD"
cleanup_stubs

