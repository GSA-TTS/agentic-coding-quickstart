#!/usr/bin/env bash
#
# test-acq-lib.sh — shared stub library for the acq bats test suite.
#
# This file is SOURCED (never executed directly) by test/bats/helper.bash, which
# every test/bats/*.bats file loads. It provides:
#   - the stub scaffolding (make_stubs/cleanup_stubs) for sbx/msb/ssh/ssh-keygen,
#     driven through $CALLS
#   - load_acq (source acq + the sbx adapter with the ACQ_SOURCE_ONLY guard)
#   - REPO_ROOT / ACQ, the offline kit-dir, retry-backoff neutralization, and the
#     shared MSB_GITHUB_SECRET_BINDING constant the .bats files assert against
#
# It began as the shared harness for the bespoke scripts/test-acq runner (and its
# scripts/test-acq.d/NN-*.sh parts). That runner was retired once the suite was
# migrated to bats-core (ADR-0025); this library survives because it is the
# valuable, framework-agnostic STUB layer, now consumed by the bats helper. bats
# provides the assertions (bats-assert) and the pass/fail tally, so the old
# hand-rolled pass/fail/assert_* and PASS/FAIL counters are gone.

set -uo pipefail

# Detach stdin from any terminal for the whole suite. acq's interactive prompts
# (key-gate rotate, github-scope advisory, stale-bundle refresh, doctor
# default-write) gate on `[ -t 0 ]` and READ stdin when it is a TTY. A @test that
# reaches a prompt path incidentally would otherwise BLOCK when run from an
# interactive terminal (CI pipes stdin, so it never hung there). Reopening stdin
# from /dev/null once, here, makes every prompt take its non-interactive branch
# regardless of how the suite was launched. @tests that feed input still pipe it
# explicitly (that overrides this). bats runs each @test in its own process, so
# this redirect is inherited by every test that sources the helper.
exec </dev/null

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ACQ="$REPO_ROOT/acq"

seed_sbx_usai_proxy_fixture() {
  cat > "$STUBDIR/sbx_ls" <<'LS'
SCOPE      TYPE      NAME     SECRET

CUSTOM SECRETS
SCOPE      TARGETS            ENV            PLACEHOLDER               SECRET
(global)   api.gsa.usai.gov   USAI_API_KEY   sbx-cs-0lrfssn3YnvE8P2j   api-ke***tJ63
LS
  export SBX_LS_FIXTURE="$STUBDIR/sbx_ls"
}

# Neutralize retry backoff.
sleep() { :; }

# The full msb --secret binding for GitHub, asserted by parts that check the
# provision/live-rotate command shape (read across files after this lib is
# sourced, so shellcheck cannot see the use here).
# shellcheck disable=SC2034
MSB_GITHUB_SECRET_BINDING="GITHUB_TOKEN@github.com,api.github.com,codeload.github.com"

# Force the sbx adapter to pass kit refs through unchanged (no git fetch /
# translation) so the harness stays fully offline. The neutral→sbx-v2
# translation itself is exercised separately (see the kit-translate section).
export ACQ_SBX_KIT_PASSTHROUGH=1

# msb equivalent: resolve every REMOTE kit ref to a local empty spec dir instead
# of a real git fetch. This keeps the suite network-free for the msb
# heal/provision paths (acq_backend_provision / acq_backend_ensure_kits_applied),
# including when acq is invoked as a CHILD process, where a test cannot shadow
# _acq_msb_fetch_kit. Local kit paths still pass through unchanged, so tests that
# supply an explicit local kit dir (e.g. mid-life apply) are unaffected;
# in-process tests that override _acq_msb_fetch_kit still win for the refs they
# pass. On a CI host with git + network this prevents a real fetch that would
# otherwise hang.
#
# bats sources this helper once per @test (each in its own process), so a plain
# `mktemp -d` here would leak one dir per test with no single EXIT trap to clean
# them. Instead root a SINGLE shared offline-kit dir under bats' run-scoped
# temp dir (BATS_RUN_TMPDIR, which bats removes at the end of the run); fall back
# to a per-process mktemp only when run outside bats. The dir holds a stub spec
# with no secrets, so sharing it across tests is safe.
if [ -n "${BATS_RUN_TMPDIR:-}" ]; then
  _ACQ_MSB_OFFLINE_KIT_DIR="${BATS_RUN_TMPDIR}/acq-offline-kit"
  mkdir -p "$_ACQ_MSB_OFFLINE_KIT_DIR"
else
  _ACQ_MSB_OFFLINE_KIT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/acq-nokit.XXXXXX")
fi
printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "$_ACQ_MSB_OFFLINE_KIT_DIR/spec.yaml"
export ACQ_MSB_KIT_LOCAL_DIR="$_ACQ_MSB_OFFLINE_KIT_DIR"


# ---------------------------------------------------------------------------
# Stub scaffolding
# ---------------------------------------------------------------------------
# Each test runs in its own temp dir with a stub `sbx` on PATH.
# The stub logs every call to $CALLS. Each stub builds its whole argv line in
# one string and appends it with a SINGLE `printf … >>"$CALLS"` write: the
# ADR-0015 port path backgrounds `msb ssh serve` and `ssh -L` concurrently, and
# a multi-`printf` sequence into the same append fd can interleave into a
# corrupted line under that concurrency (a source of the concurrency flake this avoids).

make_stubs() {
  STUBDIR=$(mktemp -d "${TMPDIR:-/tmp}/acq-test.XXXXXX")
  CALLS="$STUBDIR/calls.log"
  : >"$CALLS"
  # Preserve the base PATH (with coreutils etc.) but prepend the stub dir.
  _STUB_BASE_PATH="${PATH}"

  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
# Build the whole call line in one string and append with a SINGLE write, so
# concurrently-backgrounded stubs (msb ssh serve + ssh -L) can't interleave
# their writes into a corrupted line on the shared $CALLS append fd.
_line="sbx"; for a in "$@"; do _line="$_line $a"; done
printf '%s\n' "$_line" >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v%s abc123\n' "${STUB_SBX_VERSION:-0.38.0}" ;;
  --help|-h) printf 'SBX-TOPLEVEL-HELP\n' ;;
  ls)
    [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"
    exit 0 ;;
  create) : >"$STUBDIR/.created"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    # `opencode --version` is the postinstall functionality probe (bare argv,
    # not an `sh -c`). By default model the BROKEN state (exit 1) so the
    # postinstall path runs; STUB_OPENCODE_OK=1 makes it "already runnable".
    # A test can also plant $STUBDIR/.opencode_fixed so the FIRST probe fails
    # but a later one (after postinstall ran) succeeds.
    case " $* " in
      *" opencode --version "*)
        if [ "${STUB_OPENCODE_OK:-0}" = "1" ] || [ -f "$STUBDIR/.opencode_fixed" ]; then
          printf 'opencode 1.18.12\n'; exit 0
        fi
        exit 1 ;;
    esac
    case "$snippet" in
      *"echo ok"*) printf 'ok\n' ;;
      *'%{http_code}'*)
        # check_key runs `curl … -w '%{http_code}'; printf '|%s' "$?"`, so the
        # real probe emits `<http_code>|<curl_exit>`. Model that shape.
        # STUB_KEY_UNREACHABLE=1 models curl failing to connect (TLS reset /
        # HTTP 000 / nonzero exit) — the network-unreachable case.
        # STUB_KEY_UNREACHABLE=35 models the Sig 2 "pinned public address"
        # variant (KFM §30): DNS was bypassed by pinning USAi's public IP, so the
        # name resolved but the TLS/connect handshake still failed (curl exit 35)
        # because the endpoint is reachable only via the corporate tunnel. Like
        # any other connect failure it must classify as "unreachable", NOT a bad
        # key and NOT a DNS-resolver hint.
        # STUB_KEY_UNRESOLVED=1 models DNS NXDOMAIN (curl exit 6) — the
        # split-horizon-DNS case.
        if [ "${STUB_KEY_UNRESOLVED:-0}" = "1" ]; then
          printf '000|6'
        elif [ "${STUB_KEY_UNREACHABLE:-0}" = "35" ]; then
          printf '000|35'
        elif [ "${STUB_KEY_UNREACHABLE:-0}" != "0" ]; then
          printf '000|56'
        else
          printf '%s|0' "${STUB_KEY_STATUS:-200}"
        fi ;;
      *"postinstall.mjs"*)
        # Model a successful postinstall: mark opencode fixed so the follow-up
        # `opencode --version` probe passes.
        touch "$STUBDIR/.opencode_fixed"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  run)  [ "${2:-}" = "--help" ] && printf 'SBX-RUN-HELP\n'; exit 0 ;;
  stop) exit 0 ;;
  start) exit 0 ;;
  rm)   exit 0 ;;
  cp)   exit 0 ;;
  ports) exit 0 ;;
  kit)  exit 0 ;;
  settings) exit 0 ;;
  secret)
    # `secret ls` returns the optional fixture (to simulate existing secrets);
    # everything else is logged (must NOT contain actual key values) and no-ops.
    if [ "${2:-}" = "ls" ]; then
      [ -n "${SBX_LS_FIXTURE:-}" ] && [ -f "$SBX_LS_FIXTURE" ] && cat "$SBX_LS_FIXTURE"
      exit 0
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"

  # Stub `msb` (microsandbox) the same way, logging every call to $CALLS.
  # IMPORTANT: this stub DRAINS STDIN (`cat >/dev/null`) like a real `msb exec`
  # / `msb ssh` does. That is what surfaced the loop-stdin-consumption bug (a
  # `while read … done <<heredoc` whose body calls msb would otherwise lose all
  # records after the first). Keeping the stub faithful guards against regressions.
  cat >"$STUBDIR/msb" <<'MSBSTUB'
#!/usr/bin/env bash
_line="msb"; for a in "$@"; do _line="$_line $a"; done
printf '%s\n' "$_line" >>"$CALLS"
_msb_sub="${1:-}"
case "$_msb_sub" in
  --version|-V) printf 'msb %s\n' "${STUB_MSB_VERSION:-0.6.9}" ;;
  --help|-h) printf 'MSB-TOPLEVEL-HELP for msb\n' ;;
  doctor)
    # Model host-readiness. Default: ready (exit 0), so the happy path is silent.
    # STUB_MSB_DOCTOR_UNFIT=1 models a not-ready host that STAYS unfit even after
    # --fix. STUB_MSB_DOCTOR_FIXABLE=1 models a host that is unfit until
    # `msb doctor --fix` runs, then ready (the --fix call plants a marker).
    # STUB_MSB_DOCTOR_READS_STDIN=1 makes the call READ stdin (like a prompting
    # `msb doctor --fix`); acq must redirect </dev/null or it would hang — the
    # `cat` drains and returns promptly only because acq closed stdin.
    [ "${STUB_MSB_DOCTOR_READS_STDIN:-0}" = "1" ] && cat >/dev/null 2>&1
    case " $* " in
      *" --fix "*) [ "${STUB_MSB_DOCTOR_FIXABLE:-0}" = "1" ] && : >"$STUBDIR/.msb_fixed"; exit 0 ;;
    esac
    if [ "${STUB_MSB_DOCTOR_FIXABLE:-0}" = "1" ] && [ -f "$STUBDIR/.msb_fixed" ]; then exit 0; fi
    if [ "${STUB_MSB_DOCTOR_UNFIT:-0}" = "1" ] || [ "${STUB_MSB_DOCTOR_FIXABLE:-0}" = "1" ]; then exit 1; fi
    exit 0 ;;
  create)
    _image="${@: -1}"
    if [ -n "${STUB_MSB_CREATE_FAIL_IMAGE:-}" ] && [ "$_image" = "$STUB_MSB_CREATE_FAIL_IMAGE" ]; then
      printf '%s\n' "${STUB_MSB_CREATE_FAIL_MESSAGE:-manifest unknown}" >&2
      exit "${STUB_MSB_CREATE_FAIL_RC:-1}"
    fi
    : >"$STUBDIR/.msb_created" ;;
  inspect)
    # `msb inspect <name> --format json` — emit a create-time published-ports
    # JSON fixture if the test planted one, else nothing (models an absent field
    # / no ports so _acq_msb_ports_from_inspect must degrade gracefully).
    [ -f "$STUBDIR/.msb_inspect_json" ] && cat "$STUBDIR/.msb_inspect_json" ;;
  list|ls)
    # `msb list --running -q` (running-state probe, ADR-0017 stopped detection):
    # emit the RUNNING fixture if the caller asked for --running, else the full
    # existence fixture. A test that wants a sandbox to appear STOPPED plants it
    # in .msb_sandbox_list (exists) but NOT in .msb_running_list (not running).
    _want_running=0
    for a in "$@"; do [ "$a" = "--running" ] && _want_running=1; done
    if [ "$_want_running" = "1" ]; then
      [ -f "$STUBDIR/.msb_running_list" ] && cat "$STUBDIR/.msb_running_list"
    else
      [ -f "$STUBDIR/.msb_sandbox_list" ] && cat "$STUBDIR/.msb_sandbox_list"
    fi ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    # `npm install -g …` is run as DIRECT argv (no `sh -c`), so it is matched on
    # the full arg list, not on $snippet. STUB_NPM_FAIL=1 models the install
    # failing so the #321 disambiguation path runs. Match it up front (before the
    # bare-argv opencode-version probe and the $snippet cases below).
    case " $* " in
      *" npm install "*)
        [ "${STUB_NPM_FAIL:-0}" = "1" ] && exit 1 || exit 0 ;;
    esac
    # `opencode --version` postinstall functionality probe (bare argv). Default
    # broken (exit 1) so the postinstall path runs; STUB_OPENCODE_OK=1 or a
    # planted .opencode_fixed marker (written by a successful postinstall.mjs
    # below) makes it succeed.
    case " $* " in
      *" opencode --version "*)
        if [ "${STUB_OPENCODE_OK:-0}" = "1" ] || [ -f "$STUBDIR/.opencode_fixed" ]; then
          printf 'opencode 1.18.12\n'; exit 0
        fi
        exit 1 ;;
    esac
    case "$snippet" in
      *"echo ok"*) printf 'ok\n' ;;
      # #321: the registry reachability probe curls `https://<host>/` and prints
      # the `<http_code>|<curl_exit>` shape _classify_key_status reads. Default
      # models a reachable registry (200). STUB_NPM_REGISTRY=unreachable models a
      # TLS/connection cut (000|56); =unresolved models NXDOMAIN (000|6);
      # =responded models the registry answering with an HTTP ERROR (500|0) —
      # the connection completed, so it is NOT a DNS/TLS problem and MUST fall
      # through to the neutral "registry rejected it / real npm error" branch.
      # Match BEFORE the generic `%{http_code}` arm below (that one is the USAi
      # key probe with an Authorization header; this one has neither header nor
      # USAi host). Must precede the generic arm because both contain `%{http_code}`.
      *"registry.npmjs.org"*'%{http_code}'*|*'%{http_code}'*"registry.npmjs.org"*)
        case "${STUB_NPM_REGISTRY:-reachable}" in
          unreachable) printf '000|56' ;;
          unresolved)  printf '000|6'  ;;
          responded)   printf '500|0'  ;;
          *)           printf '200|0'  ;;
        esac ;;
      *'%{http_code}'*)
        # Match check_key's `<http_code>|<curl_exit>` shape (see the sbx stub).
        if [ "${STUB_KEY_UNREACHABLE:-0}" = "1" ]; then
          printf '000|56'
        else
          printf '%s|0' "${STUB_KEY_STATUS:-200}"
        fi ;;
      *"postinstall.mjs"*) touch "$STUBDIR/.opencode_fixed"; exit 0 ;;
      # The ensure-agent-user block is one big `sh -c` (useradd/mkdir/chown + a
      # `su agent … test -w /home/agent` writability check). Match it FIRST (it
      # also contains `command -v useradd`, which the generic command-v case
      # below would otherwise swallow). STUB_HOME_NOT_WRITABLE=1 models an
      # unwritable home so the block exits 1 and provision must abort.
      *"test -w /home/agent"*)
        [ "${STUB_HOME_NOT_WRITABLE:-0}" = "1" ] && exit 1 || exit 0 ;;
      # The OCI-engine setup is TWO msb-exec `sh -c` blocks: (1) a root (`-u 0`)
      # install/config block carrying `/usr/local/bin/docker`, and (2) a rootless
      # verify block (`-u agent`) that runs a `podman build` layer-mount self-test
      # (tagged acq-oci-selftest). Match the root block by its docker-alias marker
      # and the verify block by the self-test image tag. STUB_OCI_SETUP_FAIL=1
      # models the ROOT block failing; STUB_OCI_VERIFY_FAIL=1 models the rootless
      # build self-test failing (engine/storage unusable). Either failure must make
      # provision FAIL SOFT (warn, rc 0, no marker). Match these FIRST (before the
      # generic command-v / test-f cases below would swallow them).
      *"/usr/local/bin/docker"*)
        [ "${STUB_OCI_SETUP_FAIL:-0}" = "1" ] && exit 1 || exit 0 ;;
      *"acq-oci-selftest"*)
        [ "${STUB_OCI_VERIFY_FAIL:-0}" = "1" ] && exit 1 || exit 0 ;;
      # The OCI-ready marker probe (`test -f '/var/lib/acq/oci-ready'`) gates the
      # setup block. Match it BEFORE the generic `test -f` (markers absent) case
      # below. Default ABSENT (exit 1) so the OCI step runs; STUB_OCI_READY=1
      # makes the marker present (exit 0) to exercise the marker-gated skip.
      *"test -f '/var/lib/acq/oci-ready'"*)
        [ "${STUB_OCI_READY:-0}" = "1" ] && exit 0 || exit 1 ;;
      # `command -v <agent>` (agent-presence probe): controllable so the install
      # path can be exercised. By default the agent is ABSENT (exit 1) so install
      # runs; STUB_AGENT_PRESENT=1 makes it "present" (skips install). The prereq
      # `command -v node/git/curl/...` checks stay "present" (exit 0).
      *"command -v 'opencode'"*|*"command -v 'claude'"*|*"command -v 'shell'"*)
        [ "${STUB_AGENT_PRESENT:-0}" = "1" ] && exit 0 || exit 1 ;;
      # ADR-0021 ssh-agent forwarding: the `_acq_msb_check_socat` probe runs
      # `command -v socat` in the guest. Model the DEFAULT image as having socat
      # (exit 0); STUB_SOCAT_PRESENT=0 forces a MISS (exit 1) so the missing-socat
      # branch (warn + skip the bridge) can be exercised. This arm MUST precede
      # the generic `command -v` arm below, which would otherwise report every
      # tool (socat included) as present and make STUB_SOCAT_PRESENT inert.
      *"command -v socat"*)
        [ "${STUB_SOCAT_PRESENT:-1}" = "0" ] && exit 1 || exit 0 ;;
      # #321 npm-install-failure disambiguation: on a failed `npm install`, acq
      # probes whether npm is present in-guest (`command -v npm`) and, if so,
      # curls the registry host. Model npm as present by default; STUB_NPM_MISSING=1
      # makes `command -v npm` miss (exit 1) so the genuinely-missing-npm branch is
      # exercised. This arm MUST precede the generic `command -v` catch-all.
      *"command -v npm"*)
        [ "${STUB_NPM_MISSING:-0}" = "1" ] && exit 1 || exit 0 ;;
      # ADR-0021: the in-guest socat bridge (`nohup socat UNIX-LISTEN:…
      # VSOCK-CONNECT:2:<port>`) started by _acq_msb_start_ssh_agent_bridge.
      # Model a successful bridge start (exit 0). Match BEFORE the generic cases.
      *"socat UNIX-LISTEN"*) exit 0 ;;
      # ADR-0021: the forwarded-agent liveness probe run by
      # _acq_msb_warn_if_agent_unreachable. The probe reads BOTH ssh-add's exit
      # code AND its message, because the reboot dead-bridge case and a healthy
      # empty keyring BOTH exit 1 — only the text disambiguates them (real
      # ssh-add: dead backend => exit 1 "...communication with agent failed";
      # empty keyring => exit 1 "The agent has no identities."; missing socket =>
      # exit 2 "Error connecting to agent..."). The guest command runs
      # `ssh-add -l 2>&1`, folding stderr into stdout, so the message is on the
      # msb-exec STDOUT that acq captures — model that by emitting EVERY message
      # to STDOUT here (the stub's stdout == the outer msb-exec stdout).
      #   default                       -> exit 0, "<key>"          (has keys; quiet)
      #   STUB_AGENT_NO_KEYS=1          -> exit 1, "no identities"  (empty; quiet)
      #   STUB_AGENT_UNREACHABLE=1      -> exit 1, "communication with agent failed"
      #                                     (the reboot dead-bridge case; WARN)
      #   STUB_AGENT_NO_SOCKET=1        -> exit 2, "Error connecting to agent"
      #                                     (socket path gone; WARN)
      # The probe retries up to 3x then does a final `ssh-add -l`; every attempt
      # hits this same arm, so a stable knob yields a stable classification. This
      # arm MUST precede the generic `command -v` catch-all so `command -v ssh-add`
      # (probed first, present by default) is unaffected while the -l probe is
      # controllable.
      *"ssh-add -l"*)
        if [ "${STUB_AGENT_UNREACHABLE:-0}" = "1" ]; then
          printf 'error fetching identities: communication with agent failed\n'; exit 1
        elif [ "${STUB_AGENT_NO_SOCKET:-0}" = "1" ]; then
          printf 'Error connecting to agent: No such file or directory\n'; exit 2
        elif [ "${STUB_AGENT_NO_KEYS:-0}" = "1" ]; then
          printf 'The agent has no identities.\n'; exit 1
        else
          printf '256 SHA256:stubkey stub@host (ED25519)\n'; exit 0
        fi ;;
      *"command -v"*) : ;;          # prereqs "present" (empty missing set)
      *"npm install"*)
        [ "${STUB_NPM_FAIL:-0}" = "1" ] && exit 1 || exit 0 ;;
      *"test -f "*) exit 1 ;;       # markers absent
      *"test -s "*) exit 0 ;;       # copied files present
      # The /var/lib/acq marker reads (agent, workspace, ssh-auth-sock,
      # kit-env). An UNSET STUB_RECORDED_* models an ABSENT marker faithfully:
      # a real `sh -c 'cat …'` exits 1 there, and acq runs under
      # `set -euo pipefail`, so every reader must survive that nonzero (a
      # sandbox from before a marker existed, or one whose feature was never
      # configured, still has to serve every session verb). A SET-but-empty
      # value models a present-but-empty marker (cat exits 0).
      *"cat /var/lib/acq/agent"*)
        [ -n "${STUB_RECORDED_AGENT+x}" ] || exit 1
        printf '%s' "$STUB_RECORDED_AGENT" ;;
      *"cat /var/lib/acq/workspace"*)
        [ -n "${STUB_RECORDED_WORKSPACE+x}" ] || exit 1
        printf '%s' "$STUB_RECORDED_WORKSPACE" ;;
      # ADR-0021: the persisted ssh-agent guest sock marker read by
      # _acq_msb_ssh_auth_sock_for (and, via it, run/attach/start).
      *"cat /var/lib/acq/ssh-auth-sock"*)
        [ -n "${STUB_RECORDED_SSH_AUTH_SOCK+x}" ] || exit 1
        printf '%s' "$STUB_RECORDED_SSH_AUTH_SOCK" ;;
      # The persisted kit environment[] marker (see ADR-0011). The write/reset
      # arms keep a STATEFUL model in $STUBDIR/.kit_env so the full
      # provision→heal→replay cycle is testable (stale-entry regression);
      # STUB_RECORDED_KIT_ENV, when set, overrides it with fixed content
      # (multi-line values model multiple entries). Absent/empty semantics per
      # the marker-reads comment above.
      *">> /var/lib/acq/kit-env"*)
        # Append the env tokens: argv shape is `… -- sh -c '<script>' sh
        # NAME=value…` — collect everything after the argv0 `sh` that follows
        # the script.
        _kes_c=0 _kes_script=0 _kes_argv0=0
        for a in "$@"; do
          if [ "$_kes_argv0" = 1 ]; then printf '%s\n' "$a" >>"$STUBDIR/.kit_env"
          elif [ "$_kes_script" = 1 ] && [ "$a" = "sh" ]; then _kes_argv0=1
          elif [ "$_kes_c" = 1 ]; then _kes_script=1; _kes_c=0
          elif [ "$a" = "-c" ]; then _kes_c=1
          fi
        done ;;
      *"rm -f /var/lib/acq/kit-env"*) rm -f "$STUBDIR/.kit_env" ;;
      *"cat /var/lib/acq/kit-env"*)
        if [ -n "${STUB_RECORDED_KIT_ENV+x}" ]; then
          printf '%s' "$STUB_RECORDED_KIT_ENV"
        elif [ -f "$STUBDIR/.kit_env" ]; then
          cat "$STUBDIR/.kit_env"
        else
          exit 1
        fi ;;
      *) : ;;
    esac ;;
  ssh)
    # `msb ssh authorize …` is logged (above) and is a no-op. `msb ssh serve …`
    # is BACKGROUNDED by acq, which then probes it with kill -0 after a settle
    # window to confirm the listener came up; stay alive past that window so the
    # publish path sees a healthy serve (STUB_MSB_SERVE_DIE=1 models a serve that
    # dies immediately, e.g. bind failure). A plain `msb ssh` is a no-op.
    case "${2:-}" in
      serve)
        [ "${STUB_MSB_SERVE_DIE:-0}" = "1" ] && exit 1
        # Stay alive just past acq's liveness settle window so the kill -0 probe
        # sees a healthy listener, then exit. Detach stdout/stderr FIRST so this
        # backgrounded child never holds the harness's capture pipe open (a
        # lingering fd here blocks the parent's output read → CI hangs).
        exec >/dev/null 2>&1
        sleep "${STUB_MSB_SERVE_ALIVE:-0.6}" ;;
      *) : ;;
    esac ;;
  stop)
    # STUB_MSB_STOP_FAIL=1 models a `msb stop` that errors (e.g. the sandbox was
    # already stopped) so the `acq restart` best-effort-bounce path (N1) can be
    # exercised: the dispatcher must NOT abort and must still proceed to `start`.
    [ "${STUB_MSB_STOP_FAIL:-0}" = "1" ] && exit 1 || : ;;
  start)
    # Model the real `msb start`, which re-reads the sandbox's persisted
    # `--secret ENV@HOST` bindings and REQUIRES the value to be present in the
    # host env. Record which of the bound secret env vars were present at start
    # time so a test can assert acq_backend_start exported them before starting.
    { [ -n "${USAI_API_KEY:-}" ] && printf 'USAI_API_KEY=present\n' >>"$CALLS"; } || true
    { [ -n "${GITHUB_TOKEN:-}" ] && printf 'GITHUB_TOKEN=present\n' >>"$CALLS"; } || true
    : ;;
  remove|rm)
    # STUB_MSB_RM_FAIL=1 models a failed `msb remove` (e.g. sandbox not found)
    # for the ADR-0022 terminate volume-cleanup matrix.
    [ "${STUB_MSB_RM_FAIL:-0}" = "1" ] && exit 1 || : ;;
  copy|cp) : ;;
  modify) : ;;
  volume)
    # ADR-0022 derived-volume cleanup: `msb volume ls -q` lists names from the
    # fixture a test plants; `msb volume rm NAME` is logged (above) and no-ops.
    if [ "${2:-}" = "ls" ]; then
      [ -f "$STUBDIR/.msb_volume_list" ] && cat "$STUBDIR/.msb_volume_list"
    fi
    : ;;
  *) : ;;
esac
# Drain piped stdin ONLY for subcommands a real `msb` actually reads it on
# (a remote exec / ssh forwards stdin), and ONLY when stdin is not a TTY.
# Real msb never blocks on an interactive terminal here; draining a TTY would
# hang forever waiting for EOF when a test invokes `msb exec` foreground
# without redirecting stdin. Restricting to non-TTY still models a real remote
# exec consuming a PIPE, which is what surfaces the loop-stdin-consumption bug
# this guard exists for (a `while read … done <<heredoc` whose body calls msb).
case "$_msb_sub" in
  exec|ssh) [ -t 0 ] || cat >/dev/null 2>&1 || true ;;
esac
exit 0
MSBSTUB
  chmod +x "$STUBDIR/msb"

  # Stub `ssh` and `ssh-keygen` for the ADR-0015 post-hoc port path. Both log
  # every call to $CALLS. `ssh -N -L …` would normally block foregrounded; the
  # stub logs, then stays alive briefly so acq's post-background liveness probe
  # (kill -0 after ACQ_MSB_*_SETTLE) sees a HEALTHY forward — modelling a
  # successful publish. A test that wants to model an immediately-dying forward
  # sets STUB_SSH_DIE=1 (exit at once, before the settle window). `ssh-keygen -f`
  # writes throwaway key + .pub files so the key-ensure/authorize path proceeds.
  cat >"$STUBDIR/ssh" <<'SSHSTUB'
#!/usr/bin/env bash
_line="ssh"; for a in "$@"; do _line="$_line $a"; done
printf '%s\n' "$_line" >>"$CALLS"
[ "${STUB_SSH_DIE:-0}" = "1" ] && exit 1
# Stay alive just past acq's liveness settle window so kill -0 sees the forward
# established, then exit. Detach stdout/stderr FIRST so this backgrounded child
# never holds the harness's capture pipe open (a lingering fd blocks the parent's
# output read → CI hangs).
exec >/dev/null 2>&1
sleep "${STUB_SSH_ALIVE:-0.6}"
exit 0
SSHSTUB
  chmod +x "$STUBDIR/ssh"

  cat >"$STUBDIR/ssh-keygen" <<'KEYGENSTUB'
#!/usr/bin/env bash
_line="ssh-keygen"; for a in "$@"; do _line="$_line $a"; done
printf '%s\n' "$_line" >>"$CALLS"
# Emit throwaway key material at -f <path> so downstream authorize/forward runs.
_f=""; _prev=""
for a in "$@"; do [ "$_prev" = "-f" ] && { _f="$a"; break; }; _prev="$a"; done
if [ -n "$_f" ]; then
  mkdir -p "$(dirname "$_f")" 2>/dev/null || true
  printf 'STUB-PRIVATE-KEY\n' >"$_f"
  printf 'ssh-ed25519 AAAASTUBPUBKEY acq-msb\n' >"${_f}.pub"
fi
exit 0
KEYGENSTUB
  chmod +x "$STUBDIR/ssh-keygen"

  PATH="$STUBDIR:$PATH"
  export PATH CALLS STUBDIR
  # Keep acq's post-background liveness probe fast in tests (real default is 1s):
  # the stubbed serve/ssh children stay alive ~3s (STUB_*_ALIVE), comfortably
  # past this settle window, so a healthy publish is observed without slow tests.
  export ACQ_MSB_SERVE_SETTLE="0.3" ACQ_MSB_FORWARD_SETTLE="0.3"
  # Export ACQ_SCRIPT_DIR so acq can locate its backends.
  export ACQ_SCRIPT_DIR="$REPO_ROOT"
  # Force the acq secret store to a throwaway file backend (never touch the real
  # OS keychain in tests).
  export ACQ_SECRET_STORE_DIR="$STUBDIR/secrets"
  # Force acq's state dir (ssh keys, port PIDs — ADR-0015) under the throwaway
  # STUBDIR so tests never write to the real ~/.local/state/acq.
  export ACQ_STATE_DIR="$STUBDIR/state"
  # Isolate the host-side kit-bundle provenance store to this
  # test's temp dir so provenance reads/writes never touch the real XDG state.
  export ACQ_PROVENANCE_DIR="$STUBDIR/provenance"
  # Neutralize the developer's real kit customizations: an inherited
  # ACQ_EXTRA_KITS changes _build_kit_list's output (and, pre-#381, triggered
  # the split_noglob errexit loss), making local test runs diverge from CI.
  # Tests that exercise extras set these themselves.
  unset ACQ_EXTRA_KITS ACQ_EXTRA_KIT_SOURCES
}

cleanup_stubs() { [ -n "${STUBDIR:-}" ] && rm -rf "$STUBDIR"; }

# Source acq for its functions (ACQ_SOURCE_ONLY guard).
# shellcheck disable=SC1090
load_acq() {
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  # Also load the sbx adapter since acq_resolve_backend would normally do it.
  # shellcheck source=acq.backends/sbx.sh
  . "${REPO_ROOT}/acq.backends/sbx.sh"
  # Build the kit list (normally called by acq_resolve_backend).
  _build_kit_list
  # Do NOT `set +e` here (the pre-ADR-0025 bespoke runner did): bats detects a
  # failing command via errexit inherited into the @test body, so disabling it
  # in setup() makes every assertion in the suite pass vacuously (#381 review).
}
