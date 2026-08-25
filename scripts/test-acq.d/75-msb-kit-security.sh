#!/usr/bin/env bash
#
# 75-msb-kit-security — hostile mode/user/mode-validate guards (8o2..8o5b)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# 8o2. SECURITY: a hostile kit `mode` must not reach a root shell. kit_spec_files
#      drops the record; the msb chmod uses argv (no sh -c interpolation); and
#      the injected command must never appear in the recorded msb calls.
make_stubs; load_acq
inj_out=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  ik="${STUBDIR}/injkit"; mkdir -p "$ik/files"
  printf 'x\n' > "$ik/files/evil"
  cat >"$ik/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: inj-kit
displayName: Inj
description: hostile mode
files:
  - path: /home/agent/evil
    mode: "0644; touch /tmp/PWNED"
    source: files/evil
SPEC
  kit_spec_files "$ik/spec.yaml" 2>&1
)
assert_contains "sec: hostile mode record is dropped+warned" "$inj_out" "invalid mode"
# The rejected value is echoed in the warning; assert no actual FILE RECORD (a
# tab-separated path<TAB>mode… line) was emitted for it.
inj_records=$(printf '%s\n' "$inj_out" | grep -v '^kit-translate:' || true)
assert_eq "sec: hostile mode emits no file record" "" "$inj_records"
cleanup_stubs

# 8o3. SECURITY: the msb copy/chmod path refuses a non-octal mode and an unsafe
#      path, and never interpolates them into an sh -c (chmod is argv).
make_stubs; load_acq
: > "$CALLS"
sec_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/sec-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Directly exercise the copy helper with a hostile mode + a metachar path.
  _acq_msb_copy_file_verified secbox /etc/hostname '/home/agent/ok' '0644; touch /tmp/PWNED' 2>&1
  _acq_msb_copy_file_verified secbox /etc/hostname '/home/agent/a;b' '0644' 2>&1
)
sec_log=$(cat "$CALLS")
assert_contains "sec: non-octal mode refused" "$sec_out" "non-octal mode"
assert_contains "sec: unsafe path refused" "$sec_out" "unsafe path"
assert_not_contains "sec: chmod never via sh -c string" "$sec_log" "chmod 0644;"
assert_not_contains "sec: injected command never reaches msb argv" "$sec_log" "PWNED"
cleanup_stubs

# 8o3b. HOME-DIR OWNERSHIP: when a kit drops a file under a nested
#       agent-home path (e.g. the openchamber wrapper at ~/.local/bin/opencode),
#       acq creates the parent chain as root then must chown the TOP-MOST
#       created subdir under /home/agent RECURSIVELY to the agent user — so
#       .local, .local/bin AND the file all become agent-owned. Chowning only
#       the leaf left .local/.local/bin root-owned; the agent-user startup's
#       `mkdir -p ~/.local/state/...` then hit EACCES and (set -eu, detached)
#       died silently. Assert the subtree chown, by NAME, never a numeric uid.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/home-own-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Nested drop (the reported openchamber wrapper shape) …
  _acq_msb_copy_file_verified hobox /etc/hostname '/home/agent/.local/bin/opencode' '0755' >/dev/null 2>&1
  # … and a file dropped directly in the home (no subdir).
  _acq_msb_copy_file_verified hobox /etc/hostname '/home/agent/direct-file' '0644' >/dev/null 2>&1
)
home_own_log=$(cat "$CALLS")
# Nested: the intermediate subtree (top-most component .local) is chowned, not
# merely the leaf file — this is the actual fix.
assert_contains "234: chowns top-most created subtree under home (recursive)" \
  "$home_own_log" "chown -R -P agent /home/agent/.local"
assert_not_contains "234: does NOT chown only the leaf file" \
  "$home_own_log" "chown -R -P agent /home/agent/.local/bin/opencode"
# Never recurse all of /home/agent (would stomp other kits' root-owned drops).
assert_not_contains "234: does NOT recursively chown all of /home/agent" \
  "$home_own_log" "chown -R -P agent /home/agent "
# Ownership is by NAME (agent), never a numeric uid (provisioned uid != 1000).
assert_not_contains "234: chown uses agent by name, not numeric uid" \
  "$home_own_log" "chown -R 1000"
# Direct-in-home drop: `top` is the filename, so the chown targets that file
# (recursive chown of a file == chowning the file; correct, no regression).
assert_contains "234: file dropped directly in ~ chowns that file" \
  "$home_own_log" "chown -R -P agent /home/agent/direct-file"
cleanup_stubs

# 8o4. SECURITY: a hostile command `user` is dropped by kit_spec_commands (it is
#      interpolated into `msb exec -u <user>`), so the command never runs.
make_stubs; load_acq
usr_out=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  uk="${STUBDIR}/userkit"; mkdir -p "$uk"
  cat >"$uk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: user-kit
displayName: User
description: hostile user
commands:
  - phase: startup
    user: "0 -- sh -c touch/tmp/PWNED"
    command:
      - true
SPEC
  kit_spec_commands "$uk/spec.yaml" 2>&1
)
assert_contains "sec: hostile command user is dropped+warned" "$usr_out" "unsafe user"
assert_not_contains "sec: hostile user not emitted as a command record" "$usr_out" "__CMD__"
cleanup_stubs

# 8o5. `acq kit validate` REPORTS (not silently drops) a hostile mode / bad phase.
make_stubs; load_acq
val_out=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  vk="${STUBDIR}/valkit"; mkdir -p "$vk/files"
  printf 'x\n' > "$vk/files/f"
  cat >"$vk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: val-kit
displayName: Val
description: bad mode + bad phase
files:
  - path: /home/agent/f
    mode: "0644; rm -rf /"
    source: files/f
commands:
  - phase: bogus-phase
    user: "0"
    command:
      - true
SPEC
  kit_validate "$vk" 2>&1
  echo "RC=$?"
)
assert_contains "kit validate: reports non-octal mode" "$val_out" "mode must be octal"
assert_contains "kit validate: reports unknown phase" "$val_out" "unknown command phase"
assert_contains "kit validate: fails (RC=1)" "$val_out" "RC=1"
cleanup_stubs

# 8o5b. `acq kit validate` REPORTS (not silently drops) a bad environment var
#       NAME (env values reach the guest env and possibly a shell).
make_stubs; load_acq
env_val_out=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  evk="${STUBDIR}/envvalkit"; mkdir -p "$evk"
  cat >"$evk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: env-val-kit
displayName: Env Val
description: bad env var name
environment:
  GOOD_VAR: ok
  "1BAD": nope
SPEC
  kit_validate "$evk" 2>&1
  echo "RC=$?"
)
assert_contains "kit validate: reports invalid env var name" "$env_val_out" "invalid env var name"
assert_contains "kit validate: env-name failure (RC=1)" "$env_val_out" "RC=1"
cleanup_stubs
