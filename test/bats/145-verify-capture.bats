#!/usr/bin/env bats
#
# 145-verify-capture.bats — regression guard for the live verifier's output
# capture (scripts/verify-backends run_acq).
#
# WHY THIS EXISTS: run_acq used to capture with `LAST_OUT=$(acq ... | tee
# /dev/stderr)`. Command substitution reads the capture pipe until EOF — until
# every writer closes it, NOT until acq exits. acq both dups its stderr to fd 9
# (the secret-store warning channel) and starts daemonized guest-side helpers
# (the msb ssh-agent socat bridge), so a descriptor on that pipe outlives the acq
# process. The verifier then blocked forever AFTER provisioning had already
# succeeded, printing no DONE line — a hang indistinguishable from a real
# backend failure, and the reason several live msb runs appeared to stall at
# "provision complete".
#
# These tests extract the real run_acq from scripts/verify-backends (so they
# cannot drift from it) and drive it against stand-ins that reproduce the two
# properties that matter: a daemonized child, and exit 0. Each case runs under a
# timeout, so a reintroduced pipe-EOF dependency fails here as a timeout instead
# of hanging a human's live verification run.
#
# FALSE-GREEN DEFENSES (this file is a guard, so it must fail loudly rather than
# vacuously pass):
#   - the extraction itself is asserted to produce a run_acq definition, so a
#     rename or a changed function shape fails instead of eval-ing nothing;
#   - `timeout` is resolved explicitly and tests SKIP WITH A REASON when no
#     timeout(1) exists, so "could not measure" never reads as "passed".
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# The awk program that lifts run_acq out of the verifier. Single definition so
# every test (and the extraction guard below) uses the identical range.
_RUN_ACQ_AWK='/^run_acq\(\) \{$/,/^\}$/'

# _timeout_bin — echo a timeout(1) implementation, or empty if none is present.
# macOS has none in the base system (GNU coreutils installs it as `gtimeout`).
_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then printf 'timeout'; return 0; fi
  if command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'; return 0; fi
  printf ''
}

# _require_timeout — skip with a reason when the hang guard cannot be enforced.
# Without timeout(1) a regression would HANG this suite rather than fail it, and
# silently dropping the assertion would turn "unmeasurable" into a false pass.
_require_timeout() {
  TIMEOUT_BIN=$(_timeout_bin)
  [ -n "$TIMEOUT_BIN" ] || skip "no timeout(1)/gtimeout(1) available to bound the hang guard"
}

# _harness_prelude — the shared `bash -c` preamble: set up a scratch VERIFY_STATE,
# stub out trace, and eval the REAL run_acq. Emits EXTRACTED_OK so each test
# proves the extraction actually defined the function it is about to exercise.
_harness_prelude() {
  cat <<'PRELUDE'
    set -u
    VERIFY_STATE="$1"
    AWK_PROG="$2"
    shift 2
    TRACE=""
    LAST_OUT=""
    trace() { :; }
    eval "$(awk "/^_run_captured\(\) \{$/,/^\}$/" "$REPO_ROOT/scripts/verify-backends")"
    _src=$(awk "$AWK_PROG" "$REPO_ROOT/scripts/verify-backends")
    eval "$_src"
    if command -v run_acq >/dev/null 2>&1 && command -v _run_captured >/dev/null 2>&1; then
      printf 'EXTRACTED_OK=yes\n'
    else
      printf 'EXTRACTED_OK=no\n'
      exit 90
    fi
PRELUDE
}

@test "verify-capture: the extraction actually lifts run_acq (guard cannot pass vacuously)" {
  run awk "$_RUN_ACQ_AWK" "$REPO_ROOT/scripts/verify-backends"
  assert_success
  # A rename or reshaped definition must break HERE, loudly, rather than making
  # every other test in this file eval an empty string and trivially pass.
  assert_output --partial 'run_acq() {'
  # run_acq delegates the capture to the shared helper; that delegation is the
  # contract the rest of this file exercises.
  assert_output --partial '_run_captured'
}

@test "verify-capture: the shared capture helper exists and uses no pipe capture" {
  run awk '/^_run_captured\(\) \{$/,/^\}$/' "$REPO_ROOT/scripts/verify-backends"
  assert_success
  assert_output --partial '_run_captured() {'
  assert_output --partial 'LAST_OUT='
  # The fix under guard: capture must go to a FILE, never a command-substitution
  # pipe. `| tee` in the capture position is exactly the regression.
  refute_output --partial '| tee /dev/stderr'
}

@test "verify-capture: NO capture in the verifier uses the pipe idiom that hung" {
  # Belt-and-braces: the grammar preflight had its OWN `$( ... | tee /dev/stderr )`
  # capture, a second instance of the same bug class that the run_acq-only guard
  # would not have caught. Assert the idiom is absent from the whole script
  # (the explanatory comment names it with a leading backtick, so match code).
  run grep -n '=\$(.*| tee /dev/stderr' "$REPO_ROOT/scripts/verify-backends"
  assert_failure
}

@test "verify-capture: a daemonizing acq does not hang the capture (quiet mode)" {
  _require_timeout
  run "$TIMEOUT_BIN" 20 bash -c "$(_harness_prelude)"'
    cat > "$VERIFY_STATE/fake-acq" <<EOS
#!/bin/bash
exec 9>&2
nohup sleep 30 >/dev/null 2>&1 &
echo "provision complete"
exit 0
EOS
    chmod +x "$VERIFY_STATE/fake-acq"
    ACQ="$VERIFY_STATE/fake-acq"
    VERBOSE=""
    run_acq selftest --backend msb secret has -g usai
    printf "RC=%s\n" "$?"
    printf "LAST_OUT=[%s]\n" "$LAST_OUT"
  ' _ "$STUBDIR" "$_RUN_ACQ_AWK"
  assert_success
  assert_line 'EXTRACTED_OK=yes'
  assert_line 'RC=0'
  assert_line 'LAST_OUT=[provision complete]'
}

@test "verify-capture: a daemonizing acq does not hang the capture (verbose mode)" {
  _require_timeout
  run "$TIMEOUT_BIN" 20 bash -c "$(_harness_prelude)"'
    cat > "$VERIFY_STATE/fake-acq" <<EOS
#!/bin/bash
exec 9>&2
nohup sleep 30 >/dev/null 2>&1 &
echo "provision complete"
exit 0
EOS
    chmod +x "$VERIFY_STATE/fake-acq"
    ACQ="$VERIFY_STATE/fake-acq"
    VERBOSE=1
    run_acq selftest --backend msb create shell /tmp
    printf "RC=%s\n" "$?"
    printf "LAST_OUT=[%s]\n" "$LAST_OUT"
  ' _ "$STUBDIR" "$_RUN_ACQ_AWK"
  assert_success
  assert_line 'EXTRACTED_OK=yes'
  assert_line 'RC=0'
  assert_line 'LAST_OUT=[provision complete]'
  # Verbose mode must still SHOW the output live (that is its whole purpose), so
  # the line appears twice: once from the tail -f view, once from the capture.
  assert_line 'provision complete'
}

@test "verify-capture: piped stdin still reaches acq (the secret-seeding path)" {
  _require_timeout
  # The seeding call sites are pipelines (`printf key | run_acq ... secret set`),
  # so run_acq runs in a subshell and its LAST_OUT cannot propagate to the
  # caller — the seed path discards output anyway. What MUST hold is that the
  # piped value reaches acq unchanged; assert that from inside the pipeline.
  run "$TIMEOUT_BIN" 20 bash -c "$(_harness_prelude)"'
    ACQ="/bin/cat"
    VERBOSE=1
    printf "acq-verify-dummy-usai-key\n" | {
      run_acq seed-usai
      printf "RC=%s\n" "$?"
      printf "SEEN=[%s]\n" "$LAST_OUT"
    }
  ' _ "$STUBDIR" "$_RUN_ACQ_AWK"
  assert_success
  assert_line 'EXTRACTED_OK=yes'
  assert_line 'RC=0'
  assert_line 'SEEN=[acq-verify-dummy-usai-key]'
}

@test "verify-capture: a non-zero acq status propagates to the caller" {
  _require_timeout
  run "$TIMEOUT_BIN" 20 bash -c "$(_harness_prelude)"'
    cat > "$VERIFY_STATE/failing-acq" <<EOS
#!/bin/bash
echo "boom" >&2
exit 7
EOS
    chmod +x "$VERIFY_STATE/failing-acq"
    ACQ="$VERIFY_STATE/failing-acq"
    VERBOSE=""
    run_acq selftest-fail
    printf "RC=%s\n" "$?"
    printf "LAST_OUT=[%s]\n" "$LAST_OUT"
  ' _ "$STUBDIR" "$_RUN_ACQ_AWK"
  assert_success
  assert_line 'EXTRACTED_OK=yes'
  assert_line 'RC=7'
  assert_line 'LAST_OUT=[boom]'
}

@test "verify-capture: the capture file is removed (no acq output left on disk)" {
  _require_timeout
  # acq output can carry sensitive detail, and the verifier's state dir is only
  # cleaned on a normal EXIT, so each step must not accumulate transcripts.
  run "$TIMEOUT_BIN" 20 bash -c "$(_harness_prelude)"'
    printf "#!/bin/bash\necho hello\n" > "$VERIFY_STATE/ok-acq"
    chmod +x "$VERIFY_STATE/ok-acq"
    ACQ="$VERIFY_STATE/ok-acq"
    VERBOSE=""
    run_acq selftest-cleanup
    printf "LEFTOVER=%s\n" "$(find "$VERIFY_STATE" -name "run-acq.*" -o -name "run-captured.*" | wc -l | tr -d " ")"
  ' _ "$STUBDIR" "$_RUN_ACQ_AWK"
  assert_success
  assert_line 'EXTRACTED_OK=yes'
  assert_line 'LEFTOVER=0'
}

@test "verify-capture: a step that cannot create its capture file fails, not hangs" {
  _require_timeout
  # An unwritable VERIFY_STATE must return non-zero AND clear LAST_OUT, so a
  # caller never dumps the PREVIOUS step's transcript as if it were this one's.
  run "$TIMEOUT_BIN" 20 bash -c "$(_harness_prelude)"'
    printf "#!/bin/bash\necho first-step\n" > "$VERIFY_STATE/ok-acq"
    chmod +x "$VERIFY_STATE/ok-acq"
    ACQ="$VERIFY_STATE/ok-acq"
    VERBOSE=""
    run_acq first-step
    printf "FIRST=[%s]\n" "$LAST_OUT"
    VERIFY_STATE="$VERIFY_STATE/definitely/missing"
    run_acq second-step
    printf "RC=%s\n" "$?"
    printf "SECOND=[%s]\n" "$LAST_OUT"
  ' _ "$STUBDIR" "$_RUN_ACQ_AWK"
  assert_success
  assert_line 'EXTRACTED_OK=yes'
  assert_line 'FIRST=[first-step]'
  assert_line 'RC=1'
  assert_line 'SECOND=[]'
}

@test "verify-capture: CRLF from the guest transport is normalized" {
  _require_timeout
  run "$TIMEOUT_BIN" 20 bash -c "$(_harness_prelude)"'
    printf "#!/bin/bash\nprintf \"a\\r\\nb\\r\\n\"\n" > "$VERIFY_STATE/crlf-acq"
    chmod +x "$VERIFY_STATE/crlf-acq"
    ACQ="$VERIFY_STATE/crlf-acq"
    VERBOSE=""
    run_acq selftest-crlf
    case "$LAST_OUT" in
      *$'"'"'\r'"'"'*) printf "CR_PRESENT=yes\n" ;;
      *) printf "CR_PRESENT=no\n" ;;
    esac
  ' _ "$STUBDIR" "$_RUN_ACQ_AWK"
  assert_success
  assert_line 'EXTRACTED_OK=yes'
  assert_line 'CR_PRESENT=no'
}

# ---------------------------------------------------------------------------
# verify_sbx_grammar_acceptance preflight (same file: both are verifier-harness
# correctness, both extracted from scripts/verify-backends).
#
# WHY: the preflight gated on `[ -x "$bats" ]`. The vendored bats is a bash
# script, so a lost exec bit does not stop it running — but it DID produce
#   FAIL  sbx: grammar acceptance guard cannot run (vendored bats not initialized)
# on a live run where the submodule was initialized and bats was perfectly
# usable. A worktree on a container/host shared mount can present mode 644 while
# git records 755 (the same artifact that makes `./scripts/verify-backends`
# itself need a chmod). Reporting a permission artifact as a kit-grammar failure
# is a false alarm about a much scarier thing.
#
# The inverse must still hold: a genuinely MISSING bats stays fail-closed, so
# the guard can never print "accepted" without having measured.
# ---------------------------------------------------------------------------

_GRAMMAR_AWK='/^verify_sbx_grammar_acceptance\(\) \{$/,/^\}$/'

# _grammar_harness — extract verify_sbx_grammar_acceptance and run it against a
# scratch REPO_ROOT whose bats/test-file presence and mode we control.
# Args: MODE ("exec"|"noexec"|"missing")
_grammar_harness() {
  _require_timeout
  run "$TIMEOUT_BIN" 20 bash -c '
    set -u
    scratch="$1"; mode="$2"; awk_prog="$3"; real_root="$4"

    REPO_ROOT="$scratch"
    mkdir -p "$REPO_ROOT/test/vendor/bats-core/bin" "$REPO_ROOT/test/bats"
    : > "$REPO_ROOT/test/bats/101-sbx-grammar-acceptance.bats"

    # Stand-in bats: prints a clean no-skip TAP run and exits 0, so a PASS here
    # means the preflight let it run, not that any real sbx was consulted.
    if [ "$mode" != "missing" ]; then
      printf "#!/bin/bash\nprintf \"1..1\\nok 1 grammar accepted\\n\"\nexit 0\n" \
        > "$REPO_ROOT/test/vendor/bats-core/bin/bats"
      case "$mode" in
        exec)   chmod 755 "$REPO_ROOT/test/vendor/bats-core/bin/bats" ;;
        noexec) chmod 644 "$REPO_ROOT/test/vendor/bats-core/bin/bats" ;;
      esac
    fi

    VERBOSE=""
    VERIFY_STATE="$scratch/state"; mkdir -p "$VERIFY_STATE"
    LAST_OUT=""
    PASS=0; FAIL=0
    pass() { PASS=$((PASS+1)); printf "PASS:%s\n" "$1"; }
    # Mirror the real fail(): it prints an optional $2 detail line, which is where
    # the actionable remedy lives. Dropping it here would let a test pass while a
    # human saw no guidance.
    fail() { FAIL=$((FAIL+1)); printf "FAIL:%s\n" "$1"; [ -n "${2:-}" ] && printf "FAILDETAIL:%s\n" "$2"; return 0; }
    dump() { :; }

    # _run_captured is the shared capture helper the function now uses.
    eval "$(awk "/^_run_captured\(\) \{\$/,/^\}\$/" "$real_root/scripts/verify-backends")"
    _src=$(awk "$awk_prog" "$real_root/scripts/verify-backends")
    eval "$_src"
    if ! command -v verify_sbx_grammar_acceptance >/dev/null 2>&1; then
      printf "EXTRACTED_OK=no\n"; exit 90
    fi
    printf "EXTRACTED_OK=yes\n"

    verify_sbx_grammar_acceptance
    printf "PASSES=%s FAILS=%s\n" "$PASS" "$FAIL"
  ' _ "$STUBDIR" "$1" "$_GRAMMAR_AWK" "$REPO_ROOT"
}

@test "grammar-preflight: a non-executable bats fails closed, naming the REAL remedy" {
  # An earlier attempt invoked bats as `bash bin/bats` on the theory that a bash
  # script does not need its exec bit. That does NOT work: bin/bats ends in
  # `exec env ... libexec/bats-core/bats`, which execs bats-exec-suite and a
  # formatter, so the failure just moves several execs deeper (measured). The
  # correct behavior is to fail closed and point at scripts/fix-exec-bits.
  _grammar_harness noexec
  assert_success
  assert_line 'EXTRACTED_OK=yes'
  assert_line 'PASSES=0 FAILS=1'
  assert_output --partial 'not executable'
  assert_output --partial 'fix-exec-bits'
  # It must NOT be misdiagnosed as either of the two alarming alternatives.
  refute_output --partial 'rejected'
  refute_output --partial 'not initialized'
  # Fail-closed means never claiming the grammar was accepted.
  refute_output --partial 'PASS:sbx: real sbx accepts'
}

@test "grammar-preflight: a normal executable bats runs (unchanged behavior)" {
  _grammar_harness exec
  assert_success
  assert_line 'EXTRACTED_OK=yes'
  assert_line 'PASSES=1 FAILS=0'
}

@test "grammar-preflight: a MISSING bats stays fail-closed (never reports accepted)" {
  _grammar_harness missing
  assert_success
  assert_line 'EXTRACTED_OK=yes'
  assert_line 'PASSES=0 FAILS=1'
  assert_output --partial 'not initialized'
  # The two fail-closed cases have DIFFERENT remedies (submodule init vs
  # fix-exec-bits), so they must not be conflated.
  refute_output --partial 'not executable'
  # Fail-closed means it must NOT claim the grammar was accepted.
  refute_output --partial 'PASS:sbx: real sbx accepts'
}
