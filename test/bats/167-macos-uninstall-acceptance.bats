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
