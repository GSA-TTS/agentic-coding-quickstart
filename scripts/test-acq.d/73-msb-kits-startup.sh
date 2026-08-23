#!/usr/bin/env bash
#
# 73-msb-kits-startup — kit files/commands + ADR-0017 startup staging (8o1..8o1K)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# 8o. Regression: msb applies ALL kit files and ALL kit commands, not just the
#     first. The apply loops call `msb copy`/`msb exec`, which drain stdin (the
#     stub mimics this) — a naive `while read … done <<heredoc` would lose every
#     record after the first. Assert a two-file, two-command kit is fully applied.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/multi-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  mk="${STUBDIR}/multikit"
  mkdir -p "$mk/files/home"
  printf 'A\n' > "$mk/files/home/file_one"
  printf 'B\n' > "$mk/files/home/file_two"
  cat >"$mk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: multi-kit
displayName: Multi Kit
description: two files and two startup commands
files:
  - path: /home/agent/file_one
    mode: "0644"
    source: files/home/file_one
  - path: /home/agent/file_two
    mode: "0644"
    source: files/home/file_two
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo CMD_ALPHA
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo CMD_BETA
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$mk"; }
  # Apply just this kit directly (avoid the built-in kit fetches).
  _acq_msb_apply_kit_dir multibox "$mk"
)
multi_log=$(cat "$CALLS")
assert_contains "msb: applies first kit file" "$multi_log" "msb copy ${STUBDIR}/multikit/files/home/file_one multibox:/home/agent/file_one"
assert_contains "msb: applies SECOND kit file (not dropped)" "$multi_log" "msb copy ${STUBDIR}/multikit/files/home/file_two multibox:/home/agent/file_two"
assert_contains "msb: runs first kit command" "$multi_log" "echo CMD_ALPHA"
assert_contains "msb: runs SECOND kit command (not dropped)" "$multi_log" "echo CMD_BETA"
cleanup_stubs

# 8o1. environment vocabulary on msb: the kit's environment[] entries are
#      threaded onto every command as `msb exec -e NAME=value` (msb's native
#      per-exec env flag), and an unsafe env var NAME is dropped (never reaches
#      the exec).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/env-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  ek="${STUBDIR}/envkit"; mkdir -p "$ek"
  cat >"$ek/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: env-kit
displayName: Env Kit
description: environment vars threaded to msb exec
environment:
  GITLAB_HOST: gitlab.example.gov
  "1BAD": should-be-dropped
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo CMD_WITH_ENV
SPEC
  _acq_msb_apply_kit_dir envbox "$ek"
)
env_log=$(cat "$CALLS")
assert_contains "msb env: threads -e GITLAB_HOST onto exec" "$env_log" "-e GITLAB_HOST=gitlab.example.gov"
assert_contains "msb env: command still runs with env" "$env_log" "echo CMD_WITH_ENV"
assert_not_contains "msb env: unsafe env var name dropped" "$env_log" "1BAD"
cleanup_stubs

# 8o1b. DECISION GUARD: kit commands are staged via `msb exec …
#        -- <argv>` (kit content as SEPARATE ARGV ELEMENTS), NOT registered via
#        msb 0.6.7's create-time `--script`/`--script-path` flags and NOT
#        interpolated into an `sh -c` string built from kit content. This is the
#        reason the exec-based path is kept (see the DESIGN NOTE in msb.sh): the
#        argv never enters an interpolated shell string, so the safety win
#        --script offers is already present. If someone later switches the kit-
#        command path to --script (or to an interpolated sh -c), these assertions
#        fail and force a re-read of the design rationale. Uses a kit whose command
#        body carries shell metacharacters that WOULD be dangerous if interpolated.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/noscript-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  nsk="${STUBDIR}/noscriptkit"; mkdir -p "$nsk"
  cat >"$nsk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: noscript-kit
displayName: NoScript Kit
description: command body with metachars stays argv, never --script, never interpolated
commands:
  - phase: startup
    user: "0"
    command:
      - printf
      - "%s\n"
      - "hello; rm -rf /tmp/NS_PWNED"
SPEC
  _acq_msb_apply_kit_dir noscriptbox "$nsk"
)
noscript_log=$(cat "$CALLS")
# The command is dispatched through `msb exec … -- printf …` (argv), not registered.
assert_contains "239: kit command staged via msb exec (argv path)" "$noscript_log" "msb exec noscriptbox"
assert_contains "239: kit command argv reaches exec verbatim" "$noscript_log" "-- printf"
# The metachar-bearing body travels as a single argv token AFTER the `--`, so it
# is data, not a command — the injected `rm -rf` is never its own argv word.
assert_contains "239: metachar body carried as one argv token" "$noscript_log" "hello; rm -rf /tmp/NS_PWNED"
# NEVER via msb's create-time script-registration flags (the refactor we declined).
assert_not_contains "239: kit command NOT registered via --script" "$noscript_log" "--script"
assert_not_contains "239: kit command NOT registered via --script-path" "$noscript_log" "--script-path"
# NEVER by interpolating the kit command into an `sh -c "<kit content>"` wrapper.
# This startup (non-background) kit emits a plain `msb exec … -- <argv>` with NO
# `sh -c` at all (unlike the fixed marker/mkdir helpers, whose sh -c strings are
# adapter-owned, not kit content). A regression that assembled this kit's argv
# into a shell string would surface as `sh -c … printf …` (the command name
# interpolated after `sh -c`); assert that never happens for this kit's command.
assert_not_contains "239: kit command not wrapped in sh -c interpolation" "$noscript_log" "sh -c printf"
cleanup_stubs

# 8o1c. DECISION GUARD (idempotency): an install-phase kit command
#        stays run-once via the root-owned marker in _acq_msb_exec_command — that
#        gate lives in the EXEC path (test+write /var/lib/acq/install-<cksum> as
#        uid 0), which is exactly why registering the command as a create-time
#        --script (fire-and-forget, no marker) would be a behavior change. Assert
#        the marker gate is exercised for an install command.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/instmarker-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  imk="${STUBDIR}/instmarkerkit"; mkdir -p "$imk"
  cat >"$imk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: instmarker-kit
displayName: InstMarker Kit
description: install command is marker-gated in the exec path (not fire-and-forget --script)
commands:
  - phase: install
    user: "0"
    command:
      - true
SPEC
  _acq_msb_apply_kit_dir instmarkerbox "$imk"
)
instmarker_log=$(cat "$CALLS")
# Marker gate is tested (test -f) and, on a miss, written (touch) under
# /var/lib/acq — both as `-u 0`. This machinery is the run-once semantics that a
# create-time --script registration would NOT reproduce.
assert_contains "239: install cmd is marker-gated (test -f /var/lib/acq/install-)" "$instmarker_log" "test -f '/var/lib/acq/install-"
assert_contains "239: install cmd marker is written after run (touch)" "$instmarker_log" "touch '/var/lib/acq/install-"
assert_contains "239: install marker tested/written as root" "$instmarker_log" "msb exec instmarkerbox -u 0"
cleanup_stubs

# 8o1d. ADR-0017 (increment 1): provisioning a kit that HAS a startup command
#        stages a create-time `--script-path acq-startup:<path>` flag on
#        `msb create`, AND the generated host script file exists and reproduces
#        the startup command's argv + the correct run-as-user construct. This is
#        the create-time staging plumbing; it does NOT change how startup is
#        applied via exec after create (asserted below) — it is runtime-neutral.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/su-secrets"
  # Preserve the staged host file so this test can read the generated body.
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/startup-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  suk="$STUBDIR/startupkit"; mkdir -p "$suk"
  cat >"$suk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: startup-kit
displayName: Startup Kit
description: one agent-user startup command staged as a create-time script
commands:
  - phase: startup
    user: "1000"
    command:
      - sh
      - -c
      - echo STARTUP_MARKER_ALPHA
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$suk"; }
  acq_backend_provision startupbox shell /tmp >/dev/null 2>&1
)
su_log=$(cat "$CALLS")
# (a) the create line carries a --script-path acq-startup:<path> flag.
assert_contains "0017: msb create stages --script-path acq-startup" "$su_log" "--script-path acq-startup:"
# (b) the generated host script file exists and carries the startup argv +
#     run-as-user (agent) construct.
su_file=$(find "$STUBDIR/startup-stage" -type f 2>/dev/null | head -n1)
su_body=$(cat "$su_file" 2>/dev/null)
assert_contains "0017: generated script has shebang" "$su_body" "#!/bin/sh"
assert_contains "0017: generated script includes startup command body" "$su_body" "echo STARTUP_MARKER_ALPHA"
assert_contains "0017: generated script runs uid-1000 as agent (su/runuser)" "$su_body" "runuser -u agent"
assert_contains "0017: generated script sets HOME for agent user" "$su_body" "HOME=/home/agent"
# The staged path in the create flag is the same host file that exists.
assert_contains "0017: staged path in create flag points at the generated file" "$su_log" "--script-path acq-startup:${su_file}"
cleanup_stubs

# 8o1e. ADR-0017: a background:true startup command is staged into the generated
#        script in the nohup-detach form (same detach semantics the exec path
#        uses), so a never-exiting supervisor doesn't block on restart replay.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/bgsu-secrets"
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/bgstartup-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  bsk="$STUBDIR/bgstartupkit"; mkdir -p "$bsk"
  cat >"$bsk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: bgstartup-kit
displayName: BG Startup Kit
description: a background startup supervisor staged with nohup detach
commands:
  - phase: startup
    user: "0"
    background: true
    command:
      - supervisor-loop-0017
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$bsk"; }
  acq_backend_provision bgstartupbox shell /tmp >/dev/null 2>&1
)
bgsu_file=$(find "$STUBDIR/bgstartup-stage" -type f 2>/dev/null | head -n1)
bgsu_body=$(cat "$bgsu_file" 2>/dev/null)
assert_contains "0017: background startup staged with nohup detach" "$bgsu_body" "nohup"
assert_contains "0017: background startup command in generated script" "$bgsu_body" "supervisor-loop-0017"
cleanup_stubs

# 8o1f. ADR-0017: a kit with NO startup commands stages NO --script-path
#        acq-startup flag (no empty script is registered). Uses a kit whose only
#        command is install-phase (not startup).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/nostartup-secrets"
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/nostartup-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  nsk2="$STUBDIR/nostartupkit"; mkdir -p "$nsk2"
  cat >"$nsk2/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: nostartup-kit
displayName: NoStartup Kit
description: only an install command, no startup phase
commands:
  - phase: install
    user: "0"
    command:
      - true
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$nsk2"; }
  acq_backend_provision nostartupbox shell /tmp >/dev/null 2>&1
)
nostartup_log=$(cat "$CALLS")
assert_not_contains "0017: no startup cmd => no --script-path acq-startup flag" "$nostartup_log" "--script-path acq-startup"
cleanup_stubs

# 8o1g. ADR-0017 REGRESSION: install-phase commands still go through `msb exec`
#        (unchanged) and are NOT folded into the generated startup script. The
#        install command's run-once marker gate must still be exercised via exec,
#        and its argv must NOT appear in the staged startup script body.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mix-secrets"
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/mix-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  mxk="$STUBDIR/mixkit"; mkdir -p "$mxk"
  cat >"$mxk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: mix-kit
displayName: Mix Kit
description: install stays exec-based; startup is staged
commands:
  - phase: install
    user: "0"
    command:
      - sh
      - -c
      - echo INSTALL_ONLY_0017
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo STARTUP_ONLY_0017
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$mxk"; }
  acq_backend_provision mixbox shell /tmp >/dev/null 2>&1
)
mix_log=$(cat "$CALLS")
mix_file=$(find "$STUBDIR/mix-stage" -type f 2>/dev/null | head -n1)
mix_body=$(cat "$mix_file" 2>/dev/null)
# install still runs through the exec path: marker-gated as root.
assert_contains "0017: install still exec-based (marker gate via msb exec -u 0)" "$mix_log" "test -f '/var/lib/acq/install-"
assert_contains "0017: install command body still applied via msb exec" "$mix_log" "echo INSTALL_ONLY_0017"
# The startup command IS in the generated script; the install command is NOT.
assert_contains "0017: startup command is in the generated script" "$mix_body" "echo STARTUP_ONLY_0017"
assert_not_contains "0017: install command is NOT in the generated startup script" "$mix_body" "INSTALL_ONLY_0017"
cleanup_stubs

# 8o1h. ADR-0017 SECURITY (SI-10): a startup command body carrying shell
#        metacharacters is emitted into the generated script as SINGLE-QUOTED
#        DATA (never an interpolated program fragment), so the injected `rm -rf`
#        is inert text, not executable syntax. Also confirm no secret VALUE ever
#        reaches the generated script or the create line.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/inj-secrets"
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/inj-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Plant a USAi secret so provision binds it; its VALUE must never leak into the
  # generated script or the create line.
  printf 'SUPER_SECRET_VALUE_0017\n' | acq_secret_store "$(_acq_secret_key usai injbox)" >/dev/null 2>&1
  injk="$STUBDIR/injstartupkit"; mkdir -p "$injk"
  cat >"$injk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: injstartup-kit
displayName: InjStartup Kit
description: metachar startup body stays quoted data (SI-10)
commands:
  - phase: startup
    user: "0"
    command:
      - printf
      - "%s\n"
      - "hello; rm -rf /tmp/STARTUP_PWNED"
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$injk"; }
  acq_backend_provision injbox shell /tmp >/dev/null 2>&1
)
inj_log=$(cat "$CALLS")
inj_file=$(find "$STUBDIR/inj-stage" -type f 2>/dev/null | head -n1)
inj_body=$(cat "$inj_file" 2>/dev/null)
# The metachar body is present but single-quoted (inert data): the quoted form
# `'hello; rm -rf /tmp/STARTUP_PWNED'` appears verbatim in the generated script.
assert_contains "0017: metachar startup body carried as single-quoted data" "$inj_body" "'hello; rm -rf /tmp/STARTUP_PWNED'"
# No secret VALUE anywhere in the generated script or the create line.
assert_not_contains "0017: secret value never in generated startup script" "$inj_body" "SUPER_SECRET_VALUE_0017"
assert_not_contains "0017: secret value never on the create line" "$inj_log" "SUPER_SECRET_VALUE_0017"
# Hermetic escaping lock-in: the generated body must be syntactically valid sh —
# a broken single-quote escape (breakout) would make `sh -n` fail. This catches
# deep-nesting/backtick/$() escaping regressions without executing the body.
if [ -n "$inj_file" ] && sh -n "$inj_file" 2>/dev/null; then
  pass "0017: generated startup body is valid sh (no quote breakout)"
else
  fail "0017: generated startup body is valid sh (no quote breakout)" "sh -n failed on $inj_file"
fi
cleanup_stubs

# 8o1i. ADR-0017 BODY FIDELITY: the generated startup body reproduces the SAME
#        semantics the exec path threads onto a startup command — the git
#        non-interactive guards (GIT_TERMINAL_PROMPT=0 + GIT_ASKPASS/SSH_ASKPASS)
#        AND any kit environment[] var — as a portable `env NAME=value …` prefix
#        (busybox-safe: no `--` terminator). Uses a kit with a declared env var so
#        both the guard and the kit var must appear in the generated file.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/fidel-secrets"
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/fidel-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  fdk="$STUBDIR/fidelkit"; mkdir -p "$fdk"
  cat >"$fdk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: fidel-kit
displayName: Fidelity Kit
description: startup body carries git guards + a kit environment var
environment:
  GITLAB_HOST: gitlab.example.gov
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo FIDELITY_MARKER
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$fdk"; }
  acq_backend_provision fidelbox shell /tmp >/dev/null 2>&1
)
fidel_file=$(find "$STUBDIR/fidel-stage" -type f 2>/dev/null | head -n1)
fidel_body=$(cat "$fidel_file" 2>/dev/null)
# (a) git non-interactive guards are threaded onto the startup command body.
assert_contains "0017: startup body carries GIT_TERMINAL_PROMPT=0 guard" "$fidel_body" "GIT_TERMINAL_PROMPT=0"
assert_contains "0017: startup body carries GIT_ASKPASS guard" "$fidel_body" "GIT_ASKPASS=/bin/false"
assert_contains "0017: startup body carries SSH_ASKPASS guard" "$fidel_body" "SSH_ASKPASS=/bin/false"
# (b) the kit-declared environment[] var is emitted into the body.
assert_contains "0017: kit environment var emitted into startup body" "$fidel_body" "GITLAB_HOST=gitlab.example.gov"
# Portability: the env prefix uses NO `--` terminator (unsupported by busybox env).
assert_contains "0017: env prefix present in body (env NAME=value …)" "$fidel_body" "env "
assert_not_contains "0017: env prefix uses NO -- terminator (busybox-safe)" "$fidel_body" "env --"
cleanup_stubs

# 8o1j. ADR-0017 MULTI-KIT SINGLE-STAKE + NO-DROP: when TWO kits each carry a
#        startup command, only ONE `--script-path acq-startup` is staged at
#        create (increment-1 single-stake guard) — but the exec-based apply path
#        (unchanged, runtime-neutral) must STILL run BOTH kits' startup commands
#        after create, so nothing is dropped at runtime. Drives the REAL provision
#        with two kit dirs returned by a fetch stub keyed on the kit ref, so both
#        real kits flow through create-staging AND _acq_msb_apply_kit_dir.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/multi-secrets"
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/multi-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  mk1="$STUBDIR/multikit1"; mkdir -p "$mk1"
  cat >"$mk1/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: multi-kit-one
displayName: Multi Kit One
description: first kit with a startup command
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo MULTI_STARTUP_ONE
SPEC
  mk2="$STUBDIR/multikit2"; mkdir -p "$mk2"
  cat >"$mk2/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: multi-kit-two
displayName: Multi Kit Two
description: second kit with a startup command
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo MULTI_STARTUP_TWO
SPEC
  # Point the four built-in kit refs at our two fixtures (the 3rd/4th reuse the
  # empty nokit) so the REAL provision loop fetches and applies both. These are
  # consumed by acq_backend_provision's built-in kit list, then routed through the
  # _acq_msb_fetch_kit override below (indirection shellcheck cannot see).
  mkdir -p "$STUBDIR/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "$STUBDIR/nokit/spec.yaml"
  # shellcheck disable=SC2034  # all four assigned here, read by the provision loop
  USAI_KIT="k1"
  # shellcheck disable=SC2034
  PLAYBOOK_KIT="k2"
  # shellcheck disable=SC2034
  ZSCALER_KIT="k3"
  # shellcheck disable=SC2034
  GITSSHSIGN_KIT="k4"
  _acq_msb_fetch_kit() {
    case "$1" in
      k1) printf '%s\n' "$mk1" ;;
      k2) printf '%s\n' "$mk2" ;;
      *)  printf '%s\n' "$STUBDIR/nokit" ;;
    esac
  }
  acq_backend_provision multibox shell /tmp >/dev/null 2>&1
)
multi_log=$(cat "$CALLS")
# Exactly ONE --script-path acq-startup staged at create (single-stake guard).
multi_stakes=$(printf '%s\n' "$multi_log" | grep -c -- "--script-path acq-startup:")
assert_eq "0017: multi-kit stakes exactly ONE acq-startup script" "1" "$multi_stakes"
# NO-DROP: the exec-based apply path still ran BOTH kits' startup commands after
# create (nothing silently dropped at runtime). Both appear via `msb exec`.
assert_contains "0017: multi-kit runs kit-one startup via msb exec post-create" "$multi_log" "echo MULTI_STARTUP_ONE"
assert_contains "0017: multi-kit runs kit-two startup via msb exec post-create" "$multi_log" "echo MULTI_STARTUP_TWO"
cleanup_stubs

# 8o1k. ADR-0017 NAMED-USER PATH: a startup command whose `user` is a named
#        non-agent, non-root user emits the `su <user> -c` construct in the
#        generated body (the run-as-user translation for arbitrary named users).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/named-secrets"
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/named-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  nmk="$STUBDIR/namedkit"; mkdir -p "$nmk"
  cat >"$nmk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: named-kit
displayName: Named Kit
description: startup command as a named non-agent user
commands:
  - phase: startup
    user: "postgres"
    command:
      - sh
      - -c
      - echo NAMED_USER_MARKER
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$nmk"; }
  acq_backend_provision namedbox shell /tmp >/dev/null 2>&1
)
named_file=$(find "$STUBDIR/named-stage" -type f 2>/dev/null | head -n1)
named_body=$(cat "$named_file" 2>/dev/null)
# The username is single-quote-escaped defensively (SI-10), so the construct is
# `su 'postgres' -c …` — assert the su-as-that-user shape.
assert_contains "0017: named-user startup emits su <user> -c" "$named_body" "su 'postgres' -c"
assert_contains "0017: named-user startup command body present" "$named_body" "echo NAMED_USER_MARKER"
# Not routed through the agent runuser path (that is only for the uid-1000 case).
assert_not_contains "0017: named-user startup not run as agent" "$named_body" "runuser -u agent"
cleanup_stubs

# ---------------------------------------------------------------------------
