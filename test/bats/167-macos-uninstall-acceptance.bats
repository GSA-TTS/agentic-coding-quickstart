#!/usr/bin/env bats
#
# 167-macos-uninstall-acceptance.bats - offline guards for the macOS uninstall
# acceptance workflow and its harness (ADR-0048).
#
# WHY THIS EXISTS
#
# The harness is destructive by design and only ever runs on a GitHub-hosted macOS
# runner, so nothing here executes its stages (the macOS script itself is never run
# on Linux). These tests pin the properties that make it safe and honest, and that a
# refactor could silently lose: the hosted-CI refusal, a dispatch-only trigger,
# pinned actions, no expression interpolation inside shell, no privilege escalation,
# and a report that cannot call an unexercised stage a pass. Each workflow check is a
# function run once against the real file (must pass) and against a mutated copy
# (must fail), so a check that stopped detecting its violation turns red.
#
# shellcheck shell=bats

load 'helper'

SCRIPT_REL='scripts/test-uninstall-macos'
LIB_REL='scripts/uninstall-acceptance-lib.sh'
HELPER_REL='scripts/uninstall-acceptance-helper.py'
WORKFLOW_REL='.github/workflows/macos-uninstall-acceptance.yml'

setup() { SCRATCH=$(mktemp -d "${BATS_TMPDIR:-/tmp}/acq-167.XXXXXX"); }
teardown() { [ -z "${SCRATCH:-}" ] || rm -rf "$SCRATCH"; }

# ---- workflow checks: each prints a reason and fails when the property is lost

# Top-level keys other than the trigger must not add events.
check_trigger_only_dispatch() {
  awk '
    /^on:/ { on = 1; next }
    on && /^[^ #]/ { on = 0 }
    on && /^  [A-Za-z_]+:/ { sub(/^  /, ""); sub(/:.*/, ""); print }
  ' "$1" | grep -qx 'workflow_dispatch' || { echo 'workflow_dispatch trigger missing'; return 1; }
  local extra
  extra=$(awk '
    /^on:/ { on = 1; next }
    on && /^[^ #]/ { on = 0 }
    on && /^  [A-Za-z_]+:/ { sub(/^  /, ""); sub(/:.*/, ""); print }
  ' "$1" | grep -vx 'workflow_dispatch' || true)
  [ -z "$extra" ] || { echo "extra trigger(s): $extra"; return 1; }
  ! grep -Eq '^on: *(\[|[A-Za-z])' "$1" || { echo 'inline on: form'; return 1; }
}

check_empty_top_permissions() {
  grep -Eq '^permissions: \{\}[[:space:]]*$' "$1" || { echo 'top-level permissions: {} missing'; return 1; }
}

check_job_permissions_read_only() {
  local perms
  perms=$(awk '/^    permissions:/ { on = 1; next } on && /^      [a-z-]+:/ { print $1 $2; next } on { on = 0 }' "$1")
  [ "$perms" = 'contents:read' ] || { echo "job permissions must be exactly contents: read, got: $perms"; return 1; }
}

check_actions_pinned() {
  local bad
  bad=$(grep -E '^[[:space:]-]*uses:' "$1" | grep -Ev 'uses: *[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40} +# +v[0-9]' || true)
  [ -z "$bad" ] || { echo "action not pinned to a 40-hex SHA with a version comment: $bad"; return 1; }
  grep -Eq '^[[:space:]-]*uses:' "$1" || { echo 'no uses: lines found (parser would be vacuous)'; return 1; }
}

check_checkouts_drop_credentials() {
  awk '
    /uses: actions\/checkout@/ { n++; inco = 1; found = 0; next }
    inco && /persist-credentials: false/ { ok++; inco = 0 }
    inco && /^      - / { inco = 0 }
    END { if (n == 0 || ok != n) { printf "checkouts=%d with persist-credentials: false=%d\n", n, ok; exit 1 } }
  ' "$1"
}

# No ${{ }} of any kind inside a run: body. Values reach the shell through env:.
check_no_expressions_in_run() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    inrun && NF && indent($0) <= runind { inrun = 0 }
    inrun && /\$\{\{/ { printf "line %d: %s\n", NR, $0; bad = 1 }
    /^[[:space:]-]*run:/ && !inrun {
      runind = indent($0); if ($0 ~ /^[[:space:]]*- /) runind += 2
      if ($0 ~ /run: *[|>]/) { inrun = 1 }
      else if ($0 ~ /\$\{\{/) { printf "line %d: %s\n", NR, $0; bad = 1 }
      runs++
    }
    END { if (bad) exit 1; if (!runs) { print "no run: blocks found (parser would be vacuous)"; exit 1 } }
  ' "$1"
}

check_ref_input_only_via_env_or_with() {
  local hits
  hits=$(grep -n 'inputs\.' "$1" | grep -Ev '^[0-9]+:[[:space:]]+(SUBJECT_REF|RUN_HOMEBREW): \$\{\{ inputs\.(ref|homebrew) \}\}$|^[0-9]+:[[:space:]]+ref: \$\{\{ inputs\.ref \}\}$' || true)
  [ -z "$hits" ] || { echo "inputs.* used outside env:/with: ref: $hits"; return 1; }
}

check_no_privilege_words() {
  ! grep -Eiw 'sudo|doas' "$1" >/dev/null || { echo 'privilege escalation word present'; return 1; }
}

all_workflow_checks() {
  local f=$1 check
  for check in check_trigger_only_dispatch check_empty_top_permissions check_job_permissions_read_only \
    check_actions_pinned check_checkouts_drop_credentials check_no_expressions_in_run \
    check_ref_input_only_via_env_or_with check_no_privilege_words; do
    "$check" "$f" >"$SCRATCH/out" 2>&1 || { printf '%s: %s\n' "$check" "$(cat "$SCRATCH/out")"; return 1; }
  done
}

# Both mutators write $SCRATCH/mutant.yml and fail if the anchor drifted, so a
# mutation that silently changed nothing cannot make a "caught" test pass.
mutate() { # name sed-script (single-line substitutions only; BSD sed has no \n)
  sed -e "$2" "$REPO_ROOT/$WORKFLOW_REL" > "$SCRATCH/mutant.yml"
  ! cmp -s "$SCRATCH/mutant.yml" "$REPO_ROOT/$WORKFLOW_REL" || fail "mutation '$1' changed nothing: the anchor drifted"
}

mutate_after() { # name exact-line-to-find text-to-insert-after-its-first-occurrence
  awk -v anchor="$2" -v add="$3" '{ print } !done && $0 == anchor { print add; done = 1 }' \
    "$REPO_ROOT/$WORKFLOW_REL" > "$SCRATCH/mutant.yml"
  ! cmp -s "$SCRATCH/mutant.yml" "$REPO_ROOT/$WORKFLOW_REL" || fail "mutation '$1' changed nothing: the anchor drifted"
}

@test "workflow: passes every structural check" {
  run all_workflow_checks "$REPO_ROOT/$WORKFLOW_REL"
  assert_success
}

@test "workflow: is dispatch-only and its ref input is required" {
  run check_trigger_only_dispatch "$REPO_ROOT/$WORKFLOW_REL"
  assert_success
  grep -Eq '^      ref:$' "$REPO_ROOT/$WORKFLOW_REL"
  awk '/^      ref:$/ { on = 1; next } on && /required: true/ { ok = 1 } on && /^      [a-z]+:$/ { on = 0 } END { exit !ok }' "$REPO_ROOT/$WORKFLOW_REL"
}

@test "workflow: refuses a ref without scripts/build-uninstaller before running anything" {
  grep -q 'scripts/build-uninstaller' "$REPO_ROOT/$WORKFLOW_REL"
  awk '/-f subject\/scripts\/build-uninstaller/ { gate = NR } /test-uninstall-macos/ && !/^[[:space:]]*#/ { run = NR } END { exit !(gate && run && gate < run) }' "$REPO_ROOT/$WORKFLOW_REL"
}

@test "workflow: subject and harness are separate checkout paths" {
  grep -Eq '^          path: harness$' "$REPO_ROOT/$WORKFLOW_REL"
  grep -Eq '^          path: subject$' "$REPO_ROOT/$WORKFLOW_REL"
}

@test "workflow mutation: an added pull_request trigger is caught" {
  mutate_after trigger 'on:' '  pull_request:'
  run check_trigger_only_dispatch "$SCRATCH/mutant.yml"
  assert_failure
}

@test "workflow mutation: removing top-level permissions: {} is caught" {
  mutate perms 's/^permissions: {}$/permissions: read-all/'
  run check_empty_top_permissions "$SCRATCH/mutant.yml"
  assert_failure
}

@test "workflow mutation: an extra job permission is caught" {
  mutate_after jobperms '      contents: read' '      id-token: write'
  run check_job_permissions_read_only "$SCRATCH/mutant.yml"
  assert_failure
}

@test "workflow mutation: an unpinned action is caught" {
  mutate pin 's|actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2|actions/upload-artifact@v7|'
  run check_actions_pinned "$SCRATCH/mutant.yml"
  assert_failure
}

@test "workflow mutation: a pinned SHA without a version comment is caught" {
  mutate comment 's|\(actions/upload-artifact@[0-9a-f]\{40\}\) # v7.0.2|\1|'
  run check_actions_pinned "$SCRATCH/mutant.yml"
  assert_failure
}

@test "workflow mutation: persist-credentials left on is caught" {
  mutate creds '1,/persist-credentials: false/ s/persist-credentials: false/persist-credentials: true/'
  run check_checkouts_drop_credentials "$SCRATCH/mutant.yml"
  assert_failure
}

@test "workflow mutation: inline inputs.ref in a run block is caught" {
  mutate_after inline '          set -euo pipefail' '          echo "${{ inputs.ref }}"'
  run check_no_expressions_in_run "$SCRATCH/mutant.yml"
  assert_failure
  assert_output --partial 'inputs.ref'
}

@test "workflow mutation: an inline github.* expression in a run block is caught" {
  mutate gh 's|^          sha=\$(git -C subject rev-parse HEAD)$|          sha=${{ github.sha }}|'
  run check_no_expressions_in_run "$SCRATCH/mutant.yml"
  assert_failure
}

@test "workflow mutation: a new inputs.* use outside env/with is caught" {
  mutate_after stray '      RUN_HOMEBREW: ${{ inputs.homebrew }}' '      OTHER: ${{ inputs.ref }}'
  run check_ref_input_only_via_env_or_with "$SCRATCH/mutant.yml"
  assert_failure
}

@test "workflow mutation: a privilege-escalation word is caught" {
  mutate_after priv '          set -euo pipefail' '          sudo true'
  run check_no_privilege_words "$SCRATCH/mutant.yml"
  assert_failure
}

# ---- harness script

@test "harness: --help works without any CI environment" {
  run env -i PATH="$PATH" bash "$REPO_ROOT/$SCRIPT_REL" --help
  assert_success
  assert_output --partial 'Usage: scripts/test-uninstall-macos'
  assert_output --partial 'Refuses to run unless'
}

@test "harness: refuses to run outside CI, creating nothing" {
  run env -i PATH="$PATH" HOME="$SCRATCH/home" bash "$REPO_ROOT/$SCRIPT_REL" --subject "$SCRATCH/s" --out "$SCRATCH/out"
  assert_failure 3
  assert_output --partial 'refusing to run'
  [ ! -e "$SCRATCH/out" ] || fail 'refusal must not create the output directory'
  [ ! -e "$SCRATCH/home" ] || fail 'refusal must not touch HOME'
}

@test "harness: each hosted-CI variable is individually required" {
  local missing
  for missing in CI GITHUB_ACTIONS RUNNER_ENVIRONMENT; do
    run env -i PATH="$PATH" CI=true GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted \
      RUNNER_TEMP="$SCRATCH" GITHUB_WORKSPACE="$SCRATCH" "$missing=wrong" \
      bash "$REPO_ROOT/$SCRIPT_REL" --subject "$SCRATCH/s" --out "$SCRATCH/out"
    [ "$status" -eq 3 ] || fail "$missing=wrong: expected exit 3, got $status: $output"
    case "$output" in *"$missing"*) ;; *) fail "$missing=wrong: refusal does not name the variable: $output" ;; esac
  done
  [ ! -e "$SCRATCH/out" ] || fail 'a refusal created the output directory'
}

@test "harness: a missing run id or runner image marker is refused" {
  local missing
  for missing in GITHUB_RUN_ID ImageOS; do
    run env -i PATH="$PATH" CI=true GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted GITHUB_RUN_ID=1 ImageOS=macos15 \
      RUNNER_TEMP="$SCRATCH" GITHUB_WORKSPACE="$SCRATCH" "$missing=" \
      bash "$REPO_ROOT/$SCRIPT_REL" --subject "$SCRATCH/s" --out "$SCRATCH/out"
    [ "$status" -eq 3 ] || fail "$missing empty: expected exit 3, got $status: $output"
    case "$output" in *"$missing"*) ;; *) fail "$missing empty: refusal does not name it: $output" ;; esac
  done
  [ ! -e "$SCRATCH/out" ] || fail 'a refusal created the output directory'
}

@test "harness: a requested Homebrew stage becomes required in the report" {
  grep -Eq 'RUN_HOMEBREW" != 1 \] \|\| required="\$required,homebrew"' "$REPO_ROOT/$SCRIPT_REL"
}

@test "harness: Homebrew commands run non-interactively (ask mode off, no auto-update)" {
  grep -q 'HOMEBREW_NO_ASK=1 HOMEBREW_NO_AUTO_UPDATE=1' "$REPO_ROOT/$LIB_REL"
}

@test "harness: a self-hosted runner is refused even with CI variables set" {
  run env -i PATH="$PATH" CI=true GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=self-hosted \
    RUNNER_TEMP="$SCRATCH" GITHUB_WORKSPACE="$SCRATCH" \
    bash "$REPO_ROOT/$SCRIPT_REL" --subject "$SCRATCH/s" --out "$SCRATCH/out"
  assert_failure 3
  assert_output --partial 'github-hosted'
}

@test "harness: all gates are checked before any state is created" {
  # Inside main(), the hosted-CI gate must precede resolve_paths, mkdir and mktemp.
  local body gate create
  body=$(awk '/^main\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$REPO_ROOT/$SCRIPT_REL")
  [ -n "$body" ] || fail 'main() not found'
  gate=$(printf '%s\n' "$body" | grep -n '^  require_hosted_ci$' | head -n 1 | cut -d: -f1)
  create=$(printf '%s\n' "$body" | grep -nE '^  (mkdir|WORK=\$\(mktemp|resolve_paths|python3)' | head -n 1 | cut -d: -f1)
  [ -n "$gate" ] && [ -n "$create" ] && [ "$gate" -lt "$create" ] || fail "gate line ${gate:-none}, first state change line ${create:-none}"
}

@test "harness: rejects unknown arguments and missing paths with usage" {
  run env -i PATH="$PATH" bash "$REPO_ROOT/$SCRIPT_REL" --bogus
  assert_failure 2
  run env -i PATH="$PATH" bash "$REPO_ROOT/$SCRIPT_REL" --subject only-one
  assert_failure 2
}

@test "harness: scripts parse, and shellcheck is clean" {
  run bash -n "$REPO_ROOT/$SCRIPT_REL"
  assert_success
  run bash -n "$REPO_ROOT/$LIB_REL"
  assert_success
  run python3 -B -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$REPO_ROOT/$HELPER_REL"
  assert_success
  command -v shellcheck >/dev/null 2>&1 || skip 'shellcheck is not installed'
  run shellcheck --severity=warning "$REPO_ROOT/$SCRIPT_REL" "$REPO_ROOT/$LIB_REL"
  assert_success
}

@test "harness: never escalates privileges" {
  run grep -Eiw 'sudo|doas' "$REPO_ROOT/$SCRIPT_REL" "$REPO_ROOT/$LIB_REL"
  assert_failure
  # The helper may name them only in its detection list and trace pattern.
  run grep -Eiwn 'sudo|doas' "$REPO_ROOT/$HELPER_REL"
  assert_success
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ] || fail "unexpected mentions in the helper: $output"
  assert_output --partial 'PRIVILEGE_COMMANDS = ('
}

@test "harness: every required stage name is a stage that run_all actually runs" {
  local required name
  required=$(sed -n "s/^REQUIRED_STAGES='\(.*\)'$/\1/p" "$REPO_ROOT/$SCRIPT_REL")
  [ -n "$required" ] || fail 'REQUIRED_STAGES not found'
  for name in $(printf '%s' "$required" | tr ',' ' '); do
    grep -Eq "^  run_stage $name stage_" "$REPO_ROOT/$SCRIPT_REL" || fail "required stage '$name' is not run by run_all"
  done
}

@test "harness: the destructive stages assert removal, keychain exit 44, and project preservation" {
  grep -q 'kc_status)" = 44' "$REPO_ROOT/$SCRIPT_REL"
  grep -q 'protected_manifest)" = "\$BEFORE_PROTECTED"' "$REPO_ROOT/$SCRIPT_REL"
  grep -q "Cancelled. Nothing removed." "$REPO_ROOT/$SCRIPT_REL"
  grep -q 'ACQ and Microsandbox have been removed.' "$REPO_ROOT/$SCRIPT_REL"
}

@test "harness: every seeded path is under the throwaway HOME, never the real one" {
  local bad
  # Text inside single-quoted printf formats is written into the fake rc file, not expanded.
  bad=$(grep -nE '\$HOME|~/' "$REPO_ROOT/$LIB_REL" "$REPO_ROOT/$SCRIPT_REL" | grep -Ev ":[0-9]+:[[:space:]]*(#|printf ')" || true)
  [ -z "$bad" ] || fail "references the real HOME: $bad"
}

# ---- credential-output checks on every wizard route (runs on Linux)
#
# The stage functions are loaded from the real script (sourcing runs nothing) and run
# against a fake uninstaller that prints the seeded placeholder on one stream. Only the
# keychain and seeding helpers are replaced; the runners, the leak check and the stage
# bodies are the real ones. Each route must record a credential-output failure.

LEAK_MSG='synthetic credential text appeared in'

# route -> "stage-function stream-kind"; tty routes merge stderr into stdout.
route_stage() {
  case "$1" in
    preview) echo stage_preview ;;
    cancel) echo stage_cancel ;;
    sbx-refusal) echo stage_sbx_refusal ;;
    destructive) echo stage_destructive ;;
    repeat) echo stage_repeat ;;
    sbx-removal) echo stage_sbx_removal ;;
    homebrew) echo stage_homebrew ;;
  esac
}

# $1 route, $2 leak: none|out|err. Prints the STAGE_FAILS the stage recorded.
run_route() {
  local route=$1 leak=$2 fake=$SCRATCH/uninstaller.sh
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'printf "Dry run. Nothing removed.\nCancelled. Nothing removed.\n"'
    case "$route" in
      cancel) printf '%s\n' 'printf "Remove? [y/N]: "; read -r _ || true' ;;
      sbx-removal)
        printf '%s\n' 'printf "remaining SBX sandboxes? [y/N]: "; read -r _ || true'
        printf '%s\n' 'printf "Microsandbox? [y/N]: "; read -r _ || true' ;;
    esac
    printf '%s\n' 'printf "Press Return to exit.\n"; read -r _ || true'
    case "$leak" in
      out) printf '%s\n' 'printf "%s\n" SYNTHETIC-PLACEHOLDER-NOT-A-SECRET' ;;
      err) printf '%s\n' 'printf "%s\n" SYNTHETIC-PLACEHOLDER-NOT-A-SECRET >&2' ;;
    esac
    printf '%s\n' 'exit 0'
  } > "$fake"
  RT_STAGE=$(route_stage "$route") RT_FAKE=$fake RT_DIR=$SCRATCH RT_REPO=$REPO_ROOT RT_ROUTE=$route \
    bash -c '
      . "$RT_REPO/scripts/test-uninstall-macos"
      . "$LIB"
      OUT=$RT_DIR/out; WORK=$RT_DIR/work; FAKE_HOME=$WORK/home; UNINSTALLER=$RT_FAKE
      RUN_HOMEBREW=1; WZ_TIMEOUT=30
      mkdir -p "$OUT/logs" "$WORK/tmp" "$FAKE_HOME"
      set_wenv /usr/bin:/bin
      kc_status() { echo 0; }
      keychain_add_items() { return 0; }
      seed_files() { return 0; }
      reseed_with_sbx_record() { return 0; }
      brew_prepare() { return 0; }
      brew_listed() { return 1; }
      BEFORE_SEEDED=; BEFORE_PROTECTED=
      STAGE_FAILS=
      "$RT_STAGE" >/dev/null 2>&1
      printf "%s\n" "$STAGE_FAILS"
    '
}

@test "credential output: every route rejects a placeholder on stdout or stderr" {
  local route leak missed=''
  for route in preview cancel sbx-refusal destructive repeat sbx-removal homebrew; do
    for leak in out err; do
      run run_route "$route" "$leak"
      [ "$status" -eq 0 ] || fail "$route/$leak: driver failed: $output"
      case "$output" in *"$LEAK_MSG"*) ;; *) missed="$missed $route/$leak" ;; esac
    done
  done
  [ -z "$missed" ] || fail "placeholder in output was not rejected on:$missed"
}

@test "credential output: a clean run is not reported as a leak on any route" {
  local route
  for route in preview cancel sbx-refusal destructive repeat sbx-removal homebrew; do
    run run_route "$route" none
    [ "$status" -eq 0 ] || fail "$route: driver failed: $output"
    case "$output" in *"$LEAK_MSG"*) fail "$route: false leak report: $output" ;; esac
  done
}

@test "credential output: the leak check names the stream that leaked" {
  run run_route preview out
  assert_output --partial "$LEAK_MSG preview.out"
  run run_route preview err
  assert_output --partial "$LEAK_MSG preview.err"
}

# ---- cleanup failures reach the result (runs on Linux)
#
# The real finish, cleanup, keychain_* helpers and report run against a file-backed
# stand-in for /usr/bin/security that lives only in $SCRATCH (nothing is installed on
# the host). It keeps a search list, a default keychain and the temporary keychain's
# existence in files, so restoration is really read back and compared. Failures are
# injected per environment ("real" is the runner user's keychain state, "fake" is the
# throwaway HOME's):
#   fail-set-list / fail-set-default / fail-delete   the command exits 1 and changes nothing
#   noop-set-list / noop-delete                      the command exits 0 and changes nothing

make_fake_security() {
  cat > "$SCRATCH/fake-security" <<'SEC'
#!/bin/bash
S=$FAKESEC_STATE
printf '%s\n' "$*" >> "$S/calls"
cmd=$1; shift
flag() { [ -e "$S/inject-$1" ]; }
case "$cmd" in
  list-keychains)
    if [ "${1:-}" = -d ] && [ "${3:-}" = -s ]; then
      flag fail-set-list && exit 1
      flag noop-set-list && exit 0
      shift 3; : > "$S/list"; for k in "$@"; do printf '%s\n' "$k" >> "$S/list"; done
    else
      while IFS= read -r k; do printf '    "%s"\n' "$k"; done < "$S/list"
    fi ;;
  default-keychain)
    if [ "${3:-}" = -s ]; then
      flag fail-set-default && exit 1
      printf '%s\n' "$4" > "$S/default"
    else
      printf '    "%s"\n' "$(cat "$S/default")"
    fi ;;
  create-keychain) : > "${3:-$2}" ;;
  delete-keychain)
    flag fail-delete && exit 1
    flag noop-delete && exit 0
    rm -f "$1" ;;
  *) exit 0 ;;
esac
SEC
  chmod +x "$SCRATCH/fake-security"
}

# $1 label, then injections "env:flag" ... Runs a whole run through the real finish.
# Prints nothing; leaves the exit status in CL_RC and the files under $SCRATCH/cl-$1.
run_cleanup_case() {
  local label=$1; shift
  local dir=$SCRATCH/cl-$label
  CL_RC=0
  mkdir -p "$dir/rt" "$dir/state-real" "$dir/state-fake" "$dir/out"
  make_fake_security
  printf '%s\n' /orig/a.keychain-db /orig/b.keychain-db > "$dir/state-real/list"
  printf '%s\n' /orig/a.keychain-db > "$dir/state-real/default"
  printf '%s\n' /orig/home.keychain-db > "$dir/state-fake/list"
  printf '%s\n' /orig/home.keychain-db > "$dir/state-fake/default"
  CL_DIR=$dir CL_REPO=$REPO_ROOT CL_FAKE=$SCRATCH/fake-security CL_INJECT="$*" \
    bash -c '
      . "$CL_REPO/scripts/test-uninstall-macos"
      . "$LIB"
      OUT=$CL_DIR/out; RUNNER_TEMP_REAL=$CL_DIR/rt; RUN_HOMEBREW=0
      WORK=$(mktemp -d "$RUNNER_TEMP_REAL/acq-uninstall-accept.XXXXXX")
      FAKE_HOME=$WORK/home; mkdir -p "$FAKE_HOME" "$WORK/tmp" "$OUT/logs"
      printf "item\n" > "$OUT/not-exercised.txt"; : > "$OUT/results.tsv"
      set_wenv /usr/bin:/bin
      sec()      { FAKESEC_STATE=$CL_DIR/state-fake "$CL_FAKE" "$@"; }
      sec_real() { FAKESEC_STATE=$CL_DIR/state-real "$CL_FAKE" "$@"; }
      keychain_create || exit 9
      for item in $CL_INJECT; do
        case "$item" in
          rm:fail) rm() { return 1; } ;;
          cleanup:return1) cleanup() { return 1; } ;;
          real:drift) printf "%s\n" /changed/by/wizard.keychain-db > "$CL_DIR/state-real/list" ;;
          *) : > "$CL_DIR/state-${item%%:*}/inject-${item#*:}" ;;
        esac
      done
      for stage in ${REQUIRED_STAGES//,/ }; do record "$stage" PASS ""; done
      trap finish EXIT
      exit 0
    ' >"$dir/stdout" 2>"$dir/stderr" || CL_RC=$?
}

cl_verdict() { sed -n 's/.*"verdict": "\([A-Z]*\)".*/\1/p' "$SCRATCH/cl-$1/out/results.json"; }
TAB=$(printf '\t')
cl_row() { grep "^cleanup${TAB}" "$SCRATCH/cl-$1/out/results.tsv"; }

# ---- stock macOS tool portability
# portability-scan-begin  (this section spells the forbidden forms out, so the scan skips it)
#
# The hosted runners and a maintainer's Mac have BSD grep/sed/xargs, which lack several
# GNU options. The shims below stand in for them on PATH: they reject the GNU-only forms
# the way the BSD tools do, then hand a valid call to the real tool. Running the cleanup
# assertions under them catches a test or harness line that works on Linux only.

make_bsd_shims() {
  local dir=$SCRATCH/bsd tool real
  mkdir -p "$dir"
  for tool in grep sed xargs readlink date; do
    real=$(command -v "$tool") || continue
    cat > "$dir/$tool" <<SHIM
#!/bin/bash
tool=$tool
real=$real
SHIM
    cat >> "$dir/$tool" <<'SHIM'
reject() { printf '%s: %s\n' "$tool" "$1" >&2; exit 2; }
past_opts=0; prev=''
for a in "$@"; do
  if [ "$past_opts" = 0 ]; then
    case "$tool:$a" in
      *:--) past_opts=1 ;;
      grep:--perl-regexp|grep:-P*|grep:-[A-Za-z]*P*) reject 'invalid option -- P' ;;
      sed:-r|sed:--regexp-extended|sed:--in-place*|sed:--null-data) reject "illegal option $a" ;;
      xargs:-r|xargs:--no-run-if-empty) reject "illegal option $a" ;;
      readlink:-f|readlink:--canonicalize*) reject "illegal option $a" ;;
      date:-d|date:--date*) reject "illegal option $a" ;;
    esac
    if [ "$tool" = sed ] && [ "$a" = -i ] && [ "$prev" != -e ]; then reject 'sed -i needs a suffix argument on BSD'; fi
  fi
  case "$tool:$a" in
    grep:*'\t'*|grep:*'\d'*|grep:*'\s'*|sed:*'\t'*|sed:*'\d'*|sed:*'\s'*) reject "backslash escape in a pattern is not portable: $a" ;;
  esac
  prev=$a
done
exec "$real" "$@"
SHIM
    chmod +x "$dir/$tool"
  done
}

@test "portability: the BSD stand-ins reject the GNU-only forms they exist to catch" {
  make_bsd_shims
  printf 'a\tb\n' > "$SCRATCH/f"
  run env PATH="$SCRATCH/bsd:$PATH" grep -P '^a' "$SCRATCH/f"
  assert_failure 2
  run env PATH="$SCRATCH/bsd:$PATH" grep '^a\tb' "$SCRATCH/f"
  assert_failure 2
  run env PATH="$SCRATCH/bsd:$PATH" sed -r 's/a/b/' "$SCRATCH/f"
  assert_failure 2
  run env PATH="$SCRATCH/bsd:$PATH" grep -q "^a$(printf '\t')b" "$SCRATCH/f"
  assert_success
}

@test "portability: the cleanup assertions use only options stock macOS grep and sed accept" {
  make_bsd_shims
  PATH="$SCRATCH/bsd:$PATH"
  run_cleanup_case bsd
  [ "$CL_RC" -eq 0 ] || fail "exit $CL_RC: $(cat "$SCRATCH/cl-bsd/stderr")"
  [ "$(cl_verdict bsd)" = PASS ] || fail "verdict $(cl_verdict bsd)"
  [ "$(cl_row bsd)" = "$(printf 'cleanup\tPASS\t')" ] || fail "cleanup row: $(cl_row bsd)"
  assert_cleanup_fails bsdfail 'search list restore command failed' fake:fail-set-list
}

# Static scan of the harness and this file for forms that break on stock macOS (BSD
# userland, Bash 3.2).
PORTABILITY_PATTERNS='grep +(-[A-Za-z]+ +)*(-[A-Za-z]*P|--perl-regexp)|sed +(-[A-Za-z]+ +)*(-[A-Za-z]*r[A-Za-z]* |--regexp-extended|--in-place)|sed +-i +[^ ]|sed +-i$|readlink +-f|date +-d|xargs +-r|--no-run-if-empty|find [^|]*-printf|stat +-c|sort +-V|(grep|sed)[^|]*\\[tdsw]|declare +-A|mapfile|readarray|\|&|&>>|\$\{[A-Za-z_]+(,,|\^\^)'
portability_scan() { # file...
  local f
  for f in "$@"; do
    awk '/portability-scan-be[g]in/ { skip = 1 } !skip { print FILENAME ":" FNR ": " $0 } /portability-scan-e[n]d/ { skip = 0 }' "$f"
  done | grep -E -- "$PORTABILITY_PATTERNS" | grep -Ev '^[^:]+:[0-9]+: *#' || true
}

@test "portability: no GNU-only grep/sed/xargs/readlink/date forms or Bash 4 features in the harness or its tests" {
  local hits
  hits=$(portability_scan "$REPO_ROOT/$SCRIPT_REL" "$REPO_ROOT/$LIB_REL" "$REPO_ROOT/$HELPER_REL" "$REPO_ROOT/test/bats/167-macos-uninstall-acceptance.bats")
  [ -z "$hits" ] || fail "non-portable usage: $hits"
}

@test "portability: the static scan flags each GNU-only form it is meant to catch" {
  local line n=0
  for line in "grep -P 'x' f" "grep -oP x f" "grep -q -P x f" "sed -n -r p f" "sed -r 's/a/b/' f" "sed -i 's/a/b/' f" "readlink -f x" "date -d yesterday" \
    "xargs -r rm" "find . -printf x" "stat -c %s f" "grep '^a\\t' f" "declare -A m" "mapfile -t a" 'x=${v,,}' 'x=${v^^}' "cmd |& tee f"; do
    printf '%s\n' "$line" > "$SCRATCH/probe"
    [ -n "$(portability_scan "$SCRATCH/probe")" ] || fail "scan missed: $line"
    n=$((n + 1))
  done
  for line in "grep -Eq 'a|b' f" "sed -e 's/a/b/' f" "sed -i.bak 's/a/b/' f" "mktemp -d \"\$T/x.XXXXXX\"" "readlink x"; do
    printf '%s\n' "$line" > "$SCRATCH/probe"
    [ -z "$(portability_scan "$SCRATCH/probe")" ] || fail "scan flagged a portable form: $line"
  done
  [ "$n" -eq 17 ]
}

# portability-scan-end

@test "cleanup: a clean run restores everything, removes the work directory and reports PASS" {
  run_cleanup_case clean
  [ "$CL_RC" -eq 0 ] || fail "exit $CL_RC: $(cat "$SCRATCH/cl-clean/stderr")"
  [ "$(cl_verdict clean)" = PASS ] || fail "verdict $(cl_verdict clean)"
  [ "$(cl_row clean)" = "$(printf 'cleanup\tPASS\t')" ] || fail "cleanup row: $(cl_row clean)"
  [ "$(cat "$SCRATCH/cl-clean/state-fake/list")" = /orig/home.keychain-db ]
  [ -z "$(ls "$SCRATCH/cl-clean/rt")" ] || fail 'work directory left behind'
  grep -q '^## macOS uninstall acceptance: PASS' "$SCRATCH/cl-clean/out/summary.md"
}

# Each of these must exit nonzero, report a FAIL verdict and a FAIL cleanup row naming the step.
assert_cleanup_fails() { # label expected-text injections...
  local label=$1 want=$2; shift 2
  run_cleanup_case "$label" "$@"
  [ "$CL_RC" -ne 0 ] || fail "$label: exited 0 although cleanup failed"
  [ "$(cl_verdict "$label")" = FAIL ] || fail "$label: verdict $(cl_verdict "$label"), want FAIL"
  case "$(cl_row "$label")" in *$'\tFAIL\t'*"$want"*) ;; *) fail "$label: cleanup row does not name '$want': $(cl_row "$label")" ;; esac
  grep -q '^## macOS uninstall acceptance: FAIL' "$SCRATCH/cl-$label/out/summary.md" || fail "$label: summary is not FAIL"
  grep -q "$want" "$SCRATCH/cl-$label/stderr" || fail "$label: stderr does not name '$want'"
}

@test "cleanup failure: the search-list restore command failing is a FAIL" {
  assert_cleanup_fails restore 'search list restore command failed' fake:fail-set-list
}

@test "cleanup failure: the default-keychain restore command failing is a FAIL" {
  assert_cleanup_fails restore-default 'default keychain restore command failed' fake:fail-set-default
}

@test "cleanup failure: the temporary keychain delete command failing is a FAIL" {
  assert_cleanup_fails delete 'temporary keychain delete command failed' fake:fail-delete
}

@test "cleanup failure: a delete that exits 0 but leaves the keychain is a FAIL" {
  assert_cleanup_fails delete-noop 'temporary keychain still exists after delete' fake:noop-delete
}

@test "cleanup failure: failing to remove the work directory is a FAIL" {
  assert_cleanup_fails rmwork 'work directory still present' rm:fail
}

@test "cleanup failure: a restore that exits 0 but leaves a different search list is a FAIL" {
  assert_cleanup_fails differs 'search list was not restored' fake:noop-set-list
}

@test "cleanup failure: a cleanup that returns nonzero without a reason is still a FAIL" {
  assert_cleanup_fails bare 'cleanup returned nonzero' cleanup:return1
}

@test "cleanup failure: every step still runs after an earlier one fails" {
  assert_cleanup_fails all 'search list restore command failed' fake:fail-set-list fake:fail-delete rm:fail
  local row; row=$(cl_row all)
  case "$row" in *'temporary keychain delete command failed'*) ;; *) fail "delete failure not reported: $row" ;; esac
  case "$row" in *'work directory still present'*) ;; *) fail "work directory failure not reported: $row" ;; esac
}

@test "cleanup: the runner user's own keychain state is read, never rewritten, when it is unchanged" {
  run_cleanup_case untouched real:fail-set-list real:fail-set-default
  [ "$CL_RC" -eq 0 ] || fail "exit $CL_RC: $(cat "$SCRATCH/cl-untouched/stderr")"
  [ "$(cl_verdict untouched)" = PASS ]
  ! grep -Eq -- '-s' "$SCRATCH/cl-untouched/state-real/calls" || fail "the real keychain state was written: $(cat "$SCRATCH/cl-untouched/state-real/calls")"
}

@test "cleanup: an unreadable runner-user keychain state stops the run before anything is created" {
  CL_RC=0
  mkdir -p "$SCRATCH/u/rt" "$SCRATCH/u/state-real" "$SCRATCH/u/state-fake"
  make_fake_security
  CL_DIR=$SCRATCH/u CL_REPO=$REPO_ROOT CL_FAKE=$SCRATCH/fake-security bash -c '
    . "$CL_REPO/scripts/test-uninstall-macos"; . "$LIB"
    WORK=$CL_DIR/rt; FAKE_HOME=$WORK/home; mkdir -p "$FAKE_HOME"; set_wenv /usr/bin:/bin
    sec()      { return 1; }
    sec_real() { return 1; }
    keychain_create
  ' >"$SCRATCH/u/stdout" 2>"$SCRATCH/u/stderr" || CL_RC=$?
  [ "$CL_RC" -ne 0 ] || fail 'keychain_create succeeded without a readable runner keychain state'
  grep -q 'cannot read the runner user keychain state' "$SCRATCH/u/stderr"
  [ -z "$(ls "$SCRATCH/u/rt/keychains" 2>/dev/null)" ] || fail "a keychain was created"
}

@test "cleanup: a runner-user search list the run changed is restored and verified" {
  run_cleanup_case drift real:drift
  [ "$CL_RC" -eq 0 ] || fail "exit $CL_RC: $(cat "$SCRATCH/cl-drift/stderr")"
  [ "$(cl_verdict drift)" = PASS ]
  [ "$(cat "$SCRATCH/cl-drift/state-real/list")" = "$(printf '%s\n%s' /orig/a.keychain-db /orig/b.keychain-db)" ] || fail 'real search list not restored'
}

@test "cleanup failure: a runner-user search list the run changed and that cannot be restored is a FAIL" {
  assert_cleanup_fails driftfail 'real keychain search list restore command failed' real:drift real:fail-set-list
}

# ---- helper behavior (pure Python; runs on Linux)

helper() { python3 -B "$REPO_ROOT/$HELPER_REL" "$@"; }

@test "helper: trace-privilege flags commands in command position only" {
  printf '%s\n' '+TRACE echo not with sudo' "+TRACE uninstall_error 'Run as your normal user, not with sudo.'" \
    '+TRACE printf %s sudo' '+TRACE ls /tmp' > "$SCRATCH/clean.trace"
  run helper trace-privilege "$SCRATCH/clean.trace"
  assert_success
  local line
  for line in '+TRACE sudo rm -rf /x' '++TRACE /usr/bin/sudo -n true' '+TRACE env A=1 sudo ls' '+TRACE command sudo ls' '+TRACE A=1 doas ls'; do
    printf '%s\n' '+TRACE ls' "$line" > "$SCRATCH/bad.trace"
    run helper trace-privilege "$SCRATCH/bad.trace"
    [ "$status" -eq 1 ] || fail "not flagged: $line"
  done
}

@test "helper: run answers prompts on a real tty and reports a prompt that never appears" {
  run helper run "$SCRATCH/o" 20 --reply 'go? ' yes -- bash -c 'printf "go? "; read a; [ -t 0 ] && echo "tty:$a"'
  assert_success
  grep -q 'tty:yes' "$SCRATCH/o"
  run helper run "$SCRATCH/o" 20 --reply 'never-shown' x -- true
  assert_failure 125
}

@test "helper: run reports a timeout as 124 and keeps stdin off a terminal with --no-tty" {
  run helper run "$SCRATCH/o" 1 --no-tty -- sleep 30
  assert_failure 124
  run helper run "$SCRATCH/o" 20 --no-tty -- bash -c '[ ! -t 0 ] && echo notty'
  assert_success
  grep -q notty "$SCRATCH/o"
}

# The shared stub library defines sleep() as a no-op, so waits below use
# `command sleep`. The tty cases ignore SIGHUP in the descendant: a hangup when
# the terminal closes would otherwise end it by accident and hide the leak.
#
# A timed-out or finished command must leave nothing running that could touch the
# fixture while the harness cleans up. DESC starts a delayed marker writer that
# survives its parent unless the whole process group is stopped.
DESC='(sleep 0.8; echo late > "$MARK") & sleep 30'

@test "helper: a pipe-mode timeout also stops descendants of the command" {
  run env MARK="$SCRATCH/mark" python3 -B "$REPO_ROOT/$HELPER_REL" run "$SCRATCH/o" 0.15 --no-tty -- sh -c "$DESC"
  assert_failure 124
  command sleep 1.3
  [ ! -e "$SCRATCH/mark" ] || fail 'a descendant outlived the timeout and wrote its marker'
}

@test "helper: a pipe-mode timeout stops descendants that ignore SIGTERM" {
  run env MARK="$SCRATCH/mark" python3 -B "$REPO_ROOT/$HELPER_REL" run "$SCRATCH/o" 0.15 --no-tty -- \
    sh -c "trap '' TERM; $DESC"
  assert_failure 124
  command sleep 1.3
  [ ! -e "$SCRATCH/mark" ] || fail 'a TERM-ignoring descendant outlived the timeout'
}

@test "helper: a pipe-mode command that exits leaves no descendant behind" {
  run env MARK="$SCRATCH/mark" python3 -B "$REPO_ROOT/$HELPER_REL" run "$SCRATCH/o" 20 --no-tty -- \
    sh -c '(sleep 0.8; echo late > "$MARK") & exit 0'
  assert_success
  command sleep 1.3
  [ ! -e "$SCRATCH/mark" ] || fail 'a background descendant outlived a finished command'
}

@test "helper: a tty-mode timeout also stops descendants of the command" {
  run env MARK="$SCRATCH/mark" python3 -B "$REPO_ROOT/$HELPER_REL" run "$SCRATCH/o" 0.3 -- sh -c "trap '' HUP; $DESC"
  assert_failure 124
  command sleep 1.3
  [ ! -e "$SCRATCH/mark" ] || fail 'a descendant outlived the tty timeout'
}

@test "helper: a tty-mode command that exits leaves no descendant behind" {
  run env MARK="$SCRATCH/mark" python3 -B "$REPO_ROOT/$HELPER_REL" run "$SCRATCH/o" 20 -- \
    sh -c "trap '' HUP; (sleep 0.8; echo late > \"\$MARK\") >/dev/null 2>&1 </dev/null & exit 0"
  assert_success
  command sleep 1.3
  [ ! -e "$SCRATCH/mark" ] || fail 'a background descendant outlived a finished tty command'
}

# Interrupting the helper itself (as a cancelled job or a parent cleanup does) is not a
# command timeout: Python's default SIGTERM/SIGHUP action ends it without unwinding, so
# the separately sessioned command survives. The command here announces that it started,
# leaves a delayed marker writer behind, and the helper is signalled once it is running.
# The marker must never appear and the helper must exit 128+signal. The tty cases ignore
# SIGHUP in the command so the terminal closing cannot end it by accident.
INT_DESC='(sleep 1.0; echo late > "$MARK") & echo started > "$START"; sleep 30'

# $1 mode (pipe|tty) $2 signal name $3 optional shell prefix for the command.
interrupt_helper() {
  local mode=$1 sig=$2 prefix=${3:-} flag='' pid
  [ "$mode" = pipe ] && flag=--no-tty
  rm -f "$SCRATCH/mark" "$SCRATCH/started"
  MARK="$SCRATCH/mark" START="$SCRATCH/started" python3 -B "$REPO_ROOT/$HELPER_REL" run "$SCRATCH/o" 60 $flag -- \
    sh -c "trap '' HUP; $prefix $INT_DESC" 2>"$SCRATCH/err" 3>&- &
  pid=$!
  for _ in $(seq 1 200); do [ -e "$SCRATCH/started" ] && break; command sleep 0.05; done
  [ -e "$SCRATCH/started" ] || { kill -KILL "$pid" 2>/dev/null; fail 'the command never started'; }
  kill -"$sig" "$pid"
  INT_RC=0; wait "$pid" || INT_RC=$?
  command sleep 1.4
}

signal_number() { case "$1" in HUP) echo 1 ;; INT) echo 2 ;; TERM) echo 15 ;; esac; }

# $1 mode $2 signal: the helper exits 128+signal, says so, and the command never writes.
assert_interruption_stops_command() {
  local want=$((128 + $(signal_number "$2")))
  interrupt_helper "$1" "$2"
  [ "$INT_RC" -eq "$want" ] || fail "$1/$2: helper exited $INT_RC, want $want"
  [ ! -e "$SCRATCH/mark" ] || fail "$1/$2: the command outlived the interrupted helper and wrote its marker"
  grep -q "interrupted by SIG$2" "$SCRATCH/err" || fail "$1/$2: interruption not reported on stderr: $(cat "$SCRATCH/err")"
  grep -q "interrupted by SIG$2" "$SCRATCH/o" || fail "$1/$2: interruption not recorded in the output file"
}

@test "helper interruption: SIGTERM in pipe mode stops the command and its descendants" {
  assert_interruption_stops_command pipe TERM
}

@test "helper interruption: SIGTERM in tty mode stops the command and its descendants" {
  assert_interruption_stops_command tty TERM
}

@test "helper interruption: SIGHUP in pipe mode stops the command and its descendants" {
  assert_interruption_stops_command pipe HUP
}

@test "helper interruption: SIGHUP in tty mode stops the command and its descendants" {
  assert_interruption_stops_command tty HUP
}

@test "helper interruption: SIGINT in pipe mode stops the command and its descendants" {
  assert_interruption_stops_command pipe INT
}

@test "helper interruption: SIGINT in tty mode stops the command and its descendants" {
  assert_interruption_stops_command tty INT
}

@test "helper interruption: a command that ignores SIGTERM is still killed, in both modes" {
  local mode
  for mode in pipe tty; do
    interrupt_helper "$mode" TERM "trap '' TERM;"
    [ "$INT_RC" -eq 143 ] || fail "$mode: helper exited $INT_RC, want 143"
    [ ! -e "$SCRATCH/mark" ] || fail "$mode: a TERM-ignoring command outlived the interrupted helper"
  done
}

@test "helper interruption: a repeated signal during cleanup still ends with the command stopped" {
  rm -f "$SCRATCH/mark" "$SCRATCH/started"
  MARK="$SCRATCH/mark" START="$SCRATCH/started" python3 -B "$REPO_ROOT/$HELPER_REL" run "$SCRATCH/o" 60 --no-tty -- \
    sh -c "trap '' TERM; $INT_DESC" 2>/dev/null 3>&- &
  local pid=$!
  for _ in $(seq 1 200); do [ -e "$SCRATCH/started" ] && break; command sleep 0.05; done
  kill -TERM "$pid"; command sleep 0.1; kill -HUP "$pid"; kill -INT "$pid"
  local rc=0; wait "$pid" || rc=$?
  command sleep 1.4
  [ "$rc" -eq 143 ] || fail "helper exited $rc, want the first signal's 143"
  [ ! -e "$SCRATCH/mark" ] || fail 'a repeated signal cut cleanup short'
}

@test "helper: the deadline holds when the tty child closes its terminal early" {
  local start=$SECONDS
  run python3 -B "$REPO_ROOT/$HELPER_REL" run "$SCRATCH/o" 0.5 -- sh -c 'exec 0<&- 1>&- 2>&-; sleep 6'
  assert_failure 124
  [ $((SECONDS - start)) -le 3 ] || fail "returned after $((SECONDS - start))s, past the 0.5s deadline"
}

@test "helper: a tty run releases its pseudo-terminal descriptor on every outcome" {
  run python3 -B - "$REPO_ROOT/$HELPER_REL" "$SCRATCH/o" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("acc_helper", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
count = lambda: len(os.listdir("/dev/fd"))
base = count()
cases = [(5, [], ["true"]), (0.3, [], ["sleep", "5"]), (5, [(b"never", b"x")], ["true"])]
got = [mod.run_tty(sys.argv[2], t, r, c) for t, r, c in cases]
if got != [0, 124, 125]:
    sys.exit("unexpected statuses %r" % (got,))
if count() != base:
    sys.exit("descriptor leak: %d open before, %d after" % (base, count()))
PY
  assert_success
}

@test "helper: manifest detects content, mode and link-target changes and a missing path" {
  mkdir -p "$SCRATCH/d" && printf 'a\n' > "$SCRATCH/d/f" && ln -s /nonexistent "$SCRATCH/d/l"
  helper manifest "$SCRATCH/d" "$SCRATCH/absent" > "$SCRATCH/m1"
  grep -q 'absent MISSING' "$SCRATCH/m1"
  printf 'b\n' > "$SCRATCH/d/f"; helper manifest "$SCRATCH/d" "$SCRATCH/absent" > "$SCRATCH/m2"
  ! cmp -s "$SCRATCH/m1" "$SCRATCH/m2" || fail 'content change not detected'
  printf 'a\n' > "$SCRATCH/d/f"; chmod 600 "$SCRATCH/d/f"; helper manifest "$SCRATCH/d" "$SCRATCH/absent" > "$SCRATCH/m3"
  ! cmp -s "$SCRATCH/m1" "$SCRATCH/m3" || fail 'mode change not detected'
  chmod 644 "$SCRATCH/d/f"; ln -sfn /elsewhere "$SCRATCH/d/l"; helper manifest "$SCRATCH/d" "$SCRATCH/absent" > "$SCRATCH/m4"
  ! cmp -s "$SCRATCH/m1" "$SCRATCH/m4" || fail 'link target change not detected'
}

report() { # tsv-content require -> runs helper report; outputs go to $SCRATCH
  printf '%b' "$1" > "$SCRATCH/r.tsv"; printf 'item one\n' > "$SCRATCH/r.notex"
  helper report --require "$2" --tsv "$SCRATCH/r.tsv" --json "$SCRATCH/r.json" --md "$SCRATCH/r.md" \
    --not-exercised "$SCRATCH/r.notex" --meta 'tested commit=abc'
}

@test "helper: report passes only when every required stage is PASS" {
  run report 'a\tPASS\t\nb\tPASS\t\nc\tNOT-EXERCISED\toptional\n' a,b
  assert_success
  grep -q '"verdict": "PASS"' "$SCRATCH/r.json"
  grep -q 'NOT-EXERCISED' "$SCRATCH/r.md"
}

@test "helper: report fails on FAIL, ABORTED, a missing required stage, or a required stage that is not PASS" {
  run report 'a\tPASS\t\nb\tFAIL\tboom\n' a,b
  assert_failure
  run report 'a\tPASS\t\nb\tABORTED\tkilled\n' a
  assert_failure
  run report 'a\tPASS\t\n' a,b
  assert_failure
  grep -q 'Required stages not passed: b' "$SCRATCH/r.md"
  run report 'a\tPASS\t\nb\tNOT-EXERCISED\tskipped\n' a,b
  assert_failure
  run report 'a\tPASS\t\nb\tBLOCKED\tearlier\n' a,b
  assert_failure
  run report '' a
  assert_failure
}
