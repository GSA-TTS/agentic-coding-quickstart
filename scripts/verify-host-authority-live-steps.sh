#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2154,SC2034
# Step functions of scripts/verify-host-authority-live: sourced by it, never run alone. It shares
# that script's global variables (OUT, REVISION, TO, the counters), so it is split out only
# to keep each file within the repository size limit.
# --- MSB steps ------------------------------------------------------------------
# proof_lines NAME FILE : set PROOF_N to the line count of FILE in the guest (0 if the
# file is absent). Returns non-zero when the probe itself failed or timed out, so the
# caller can report BLOCKED instead of comparing garbage.
PROOF_N=""
proof_lines() {
  PROOF_N=""
  probe "$STEP_TIMEOUT" msb exec "$1" -u 0 -- sh -c "if [ -e $2 ]; then wc -l < $2; else echo 0; fi"
  [ "$PROBE_RC" -eq 0 ] || return 1
  PROOF_N=$(printf '%s\n' "$PROBE_OUT" | tail -n 1 | tr -d '[:space:]')
  case "$PROOF_N" in ''|*[!0-9]*) PROOF_N=""; return 1 ;; esac
}

step_msb_ro_kit_create() {
  local id=msb-ro-kit-create n ws why="" irc
  block_if_not_ready "$id" "$MSB_READY" "msb unavailable (missing msb, python3, or msb doctor not ready)" || return 0
  write_fixture || { record "$id" BLOCKED "cannot write the fixture kit under $OUT"; return 0; }
  n=$(sandbox_name a); MSB_A="$n"
  ws=$(mk_workspace a) || { record "$id" BLOCKED "cannot create a workspace under $WS_ROOT"; return 0; }
  create_sandbox msb "$n" "$ws" --kit "$FIXTURE"
  if last_has "cannot place read-only kit file"; then record "$id" FAIL "acq refused the readonly fixture file on create"; return 0; fi
  need_rc0 "$id" "acq create" || return 0
  MSB_A_OK=1
  run_cmd "$STEP_TIMEOUT" msb exec "$n" -u 0 -- cat /home/agent/.hal-ro-proof
  need_rc0 "$id" "reading the readonly proof file" || return 0
  last_has "/var/lib/acq/host/kit-files/" || why="startup did not run from the read-only mount path; "
  run_cmd "$STEP_TIMEOUT" msb exec "$n" -u 0 -- sh -c 'if [ -e /home/agent/hal/ro-proof.sh ]; then echo GUEST-COPY-PRESENT; else echo NO-GUEST-COPY; fi'
  need_rc0 "$id" "probing for a guest copy of the readonly file" || return 0
  if last_has GUEST-COPY-PRESENT; then why="${why}the readonly file was also copied into the guest; "
  elif ! last_has NO-GUEST-COPY; then record "$id" BLOCKED "the guest-copy probe printed neither verdict marker (tool missing in the guest?)"; return 0; fi
  run_cmd "$STEP_TIMEOUT" msb exec "$n" -u 0 -- sh -c 'if [ -x /home/agent/hal/install-proof.sh ]; then echo PLAIN-COPY-OK; else echo PLAIN-COPY-MISSING; fi'
  need_rc0 "$id" "probing for the plain (non-readonly) copy" || return 0
  if last_has PLAIN-COPY-MISSING; then why="${why}the plain (non-readonly) file was not copied; "
  elif ! last_has PLAIN-COPY-OK; then record "$id" BLOCKED "the plain-copy probe printed neither verdict marker (tool missing in the guest?)"; return 0; fi
  msb_inspect_check "$n"; irc=$?
  [ "$irc" -ne 2 ] || { record "$id" BLOCKED "msb inspect failed, timed out, or returned unusable output"; return 0; }
  [ "$irc" -eq 0 ] || why="${why}msb inspect does not show the read-only host-config Bind; "
  if [ -z "$why" ]; then record "$id" PASS "readonly fixture file ran from the :ro mount on create, no guest copy, plain file copied, inspect shows the read-only Bind"
  else record "$id" FAIL "$why"; fi
}

step_msb_inspect_shape() {
  local id=msb-inspect-shape js
  [ "$MSB_A_OK" -eq 1 ] || { record "$id" BLOCKED "needs the sandbox from msb-ro-kit-create"; return 0; }
  js="$OUT/inspect-$MSB_A.json"
  run_bounded "$STEP_TIMEOUT" "$js" "$OUT/.inspect-err" msb inspect "$MSB_A" --format json
  cat "$OUT/.inspect-err" >>"$TRANSCRIPT" 2>/dev/null
  [ "$LAST_RC" -eq 0 ] \
    || { record "$id" BLOCKED "msb inspect failed or timed out"; return 0; }
  python3 -c '
import json, sys
d = json.load(sys.stdin)
ac = d.get("active_config"); cf = d.get("config")
def host_ro(x):
    ms = (x or {}).get("mounts") if isinstance(x, dict) else None
    if not isinstance(ms, list): return "absent"
    h = [m for m in ms if isinstance(m, dict) and m.get("guest") == "/var/lib/acq/host"]
    if len(h) != 1: return "no-single-host-mount"
    return "readonly-bind" if (h[0].get("type") == "Bind" and (h[0].get("options") or {}).get("readonly") is True) else "not-readonly-bind"
print("TOPLEVEL-KEYS " + " ".join(sorted(d.keys())))
print("ACTIVE_CONFIG.MOUNTS " + ("null" if ac is None else host_ro(ac)))
print("CONFIG.MOUNTS " + host_ro(cf))
' <"$js" >"$js.keys" 2>>"$TRANSCRIPT" \
    || { record "$id" BLOCKED "msb inspect output was not parseable JSON"; return 0; }
  while IFS= read -r line; do say "  $line"; done <"$js.keys"
  if grep -q '^ACTIVE_CONFIG.MOUNTS null$' "$js.keys"; then
    record "$id" BLOCKED "msb reports a null active_config (sandbox not settled); retry later"
  elif grep -q '^ACTIVE_CONFIG.MOUNTS readonly-bind$' "$js.keys"; then
    record "$id" PASS "active_config.mounts shape matches the gate on msb $MSB_VER; $(grep '^CONFIG.MOUNTS' "$js.keys"); $(grep '^TOPLEVEL-KEYS' "$js.keys")"
  else
    record "$id" FAIL "active_config.mounts is not the expected read-only Bind on msb $MSB_VER; $(grep '^ACTIVE_CONFIG' "$js.keys")"
  fi
}

step_msb_exit_code() {
  local id=msb-exit-code r2 r7
  [ "$MSB_A_OK" -eq 1 ] || { record "$id" BLOCKED "needs the sandbox from msb-ro-kit-create"; return 0; }
  run_cmd "$STEP_TIMEOUT" msb exec "$MSB_A" -- sh -c 'exit 2'; r2=$LAST_RC
  run_cmd "$STEP_TIMEOUT" msb exec "$MSB_A" -- sh -c 'exit 7'; r7=$LAST_RC
  if [ "$r2" -eq 124 ] || [ "$r7" -eq 124 ]; then record "$id" BLOCKED "msb exec timed out; exit-code passthrough was not exercised"; return 0; fi
  case "$r2:$r7" in
    126:*|127:*|*:126|*:127) record "$id" BLOCKED "msb exec exited 126 or 127 (sh missing or not executable in the guest); passthrough was not exercised"; return 0 ;;
  esac
  if [ "$r2" -eq 2 ] && [ "$r7" -eq 7 ]; then record "$id" PASS "guest exit codes 2 and 7 passed through msb exec unchanged on msb $MSB_VER"
  else record "$id" FAIL "guest exit 2 became $r2 and exit 7 became $r7 on msb $MSB_VER (affects only the wording of a refusal)"; fi
}

INSTALL_RERAN_ON_HEAL=0
# need_rc0 ID WHAT : after run_cmd, record BLOCKED (never FAIL) and return 1 unless the
# command exited 0; a timeout (124) is named as such.
need_rc0() {
  [ "$LAST_RC" -eq 0 ] && return 0
  if [ "$LAST_RC" -eq 125 ]; then record "$1" BLOCKED "$2 was refused (sandbox name in use, or the backend listing failed)"
  elif [ "$LAST_RC" -eq 124 ]; then record "$1" BLOCKED "BLOCKED(timeout): $2 timed out or the step's wall-clock budget ran out; the step was not exercised to a conclusion"
  elif [ "$LAST_RC" -eq 126 ] || [ "$LAST_RC" -eq 127 ]; then record "$1" BLOCKED "$2 exited $LAST_RC: a command is missing or not executable in the guest, so the step was not exercised"
  else record "$1" BLOCKED "$2 exited $LAST_RC; the step was not exercised to a conclusion (see transcript)"; fi
  return 1
}

step_msb_ro_kit_heal() {
  local id=msb-ro-kit-heal r0 r1 i0 i1 why="" irc
  [ "$MSB_A_OK" -eq 1 ] || { record "$id" BLOCKED "needs the sandbox from msb-ro-kit-create"; return 0; }
  proof_lines "$MSB_A" /home/agent/.hal-ro-proof || { record "$id" BLOCKED "could not read the readonly proof file before restart"; return 0; }
  r0=$PROOF_N
  proof_lines "$MSB_A" /home/agent/.hal-install-proof || { record "$id" BLOCKED "could not read the install proof file before restart"; return 0; }
  i0=$PROOF_N
  run_cmd "$CREATE_TIMEOUT" "$ACQ" --backend msb restart "$MSB_A"
  if last_has "cannot place read-only kit file"; then record "$id" FAIL "acq refused the readonly fixture file on heal after restart"; return 0; fi
  need_rc0 "$id" "acq restart" || return 0
  proof_lines "$MSB_A" /home/agent/.hal-ro-proof || { record "$id" BLOCKED "could not read the readonly proof file after restart"; return 0; }
  r1=$PROOF_N
  proof_lines "$MSB_A" /home/agent/.hal-install-proof || { record "$id" BLOCKED "could not read the install proof file after restart"; return 0; }
  i1=$PROOF_N
  say "  readonly startup proof lines: $r0 -> $r1; install proof lines: $i0 -> $i1"
  [ "$r1" -gt "$r0" ] || why="the readonly startup command did not re-run on heal; "
  run_cmd "$STEP_TIMEOUT" msb exec "$MSB_A" -u 0 -- tail -n 1 /home/agent/.hal-ro-proof
  need_rc0 "$id" "reading the last readonly proof line" || return 0
  last_has "/var/lib/acq/host/kit-files/" || why="${why}the heal ran the file from somewhere other than the read-only mount; "
  msb_inspect_check "$MSB_A"; irc=$?
  [ "$irc" -ne 2 ] || { record "$id" BLOCKED "msb inspect failed, timed out, or returned unusable output after restart"; return 0; }
  [ "$irc" -eq 0 ] || why="${why}msb inspect no longer shows the read-only Bind after restart; "
  [ "$i1" -gt "$i0" ] && INSTALL_RERAN_ON_HEAL=1
  if [ -z "$why" ]; then record "$id" PASS "after stop/start the readonly startup file re-ran from the :ro mount and the mount record held (msb $MSB_VER)"
  else record "$id" FAIL "$why"; fi
}

step_msb_forged_markers() {
  local id=msb-forged-markers ws why="" cwd
  [ "$MSB_A_OK" -eq 1 ] || { record "$id" BLOCKED "needs the sandbox from msb-ro-kit-create"; return 0; }
  ws="$WS_ROOT/a"
  ws=$(cd "$ws" && pwd -P)
  guest_root "$MSB_A" sh -c 'mkdir -p /var/lib/acq; printf claude > /var/lib/acq/agent; printf /tmp/forged-ws > /var/lib/acq/workspace; printf /tmp/forged.sock > /var/lib/acq/ssh-auth-sock; printf "FORGED_KIT_VAR=pwned\n" > /var/lib/acq/kit-env && touch /var/lib/acq/agent-user-ready /var/lib/acq/agent-installed-claude /var/lib/acq/install-1 && cat /var/lib/acq/workspace'
  if [ "$LAST_RC" -ne 0 ] || ! last_has /tmp/forged-ws; then record "$id" BLOCKED "could not plant (and read back) the forged markers"; return 0; fi
  run_cmd "$STEP_TIMEOUT" "$ACQ" --backend msb exec "$MSB_A" -- pwd
  cwd=$(last_out | tail -n 1 | tr -d '[:space:]')
  if [ "$LAST_RC" -ne 0 ] || [ -z "$cwd" ]; then record "$id" BLOCKED "acq exec pwd failed or printed nothing (rc $LAST_RC)"; return 0; fi
  [ "$cwd" != "/tmp/forged-ws" ] || why="session started in the forged workspace; "
  [ "$cwd" = "$ws" ] || say "  note: session cwd '$cwd' differs from the host workspace '$ws' (recorded as evidence, not scored when not forged)"
  run_cmd "$STEP_TIMEOUT" "$ACQ" --backend msb exec "$MSB_A" -- sh -c 'echo "FKV=[$FORGED_KIT_VAR] SOCK=[$SSH_AUTH_SOCK]"'
  if [ "$LAST_RC" -ne 0 ] || ! last_has 'FKV=['; then record "$id" BLOCKED "acq exec env probe failed (rc $LAST_RC)"; return 0; fi
  last_has "FKV=[pwned]" && why="${why}the forged kit-env variable reached the session; "
  last_has "SOCK=[/tmp/forged.sock]" && why="${why}the forged ssh socket reached the session; "
  run_cmd "$STEP_TIMEOUT" "$ACQ" --backend msb exec "$MSB_A" -- sh -c 'command -v claude >/dev/null 2>&1 && echo CLAUDE-PRESENT || echo no-claude'
  run_cmd "$STEP_TIMEOUT" "$ACQ" --backend msb exec "$MSB_A" -- id -un
  need_rc0 "$id" "id -un via acq exec" || return 0
  last_out | grep -qx agent || why="${why}exec no longer runs as the agent user; "
  if [ -z "$why" ]; then record "$id" PASS "forged agent/workspace/ssh-socket/kit-env/ready markers changed no exec-session behavior (attach and agent-key cases: MANUAL 1)"
  else record "$id" FAIL "$why"; fi
}

step_msb_install_gate() {
  local id=msb-install-gate hc i0 i1 n
  [ "$MSB_A_OK" -eq 1 ] || { record "$id" BLOCKED "needs the sandbox from msb-ro-kit-create"; return 0; }
  if [ "$INSTALL_RERAN_ON_HEAL" -eq 1 ]; then
    record "$id" BLOCKED "the install command re-ran on a plain heal, so key deletion cannot be told apart (see msb-ro-kit-heal output)"; return 0
  fi
  hc=$(hc_dir msb "$MSB_A")
  [ -n "$hc" ] && [ -d "$hc" ] || { record "$id" BLOCKED "host config dir for $MSB_A not found"; return 0; }
  n=$(find "$hc" -maxdepth 1 -type f -name 'install-*' 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -gt 0 ] || { record "$id" BLOCKED "no install-* key exists in the host config dir $hc (nothing to delete)"; return 0; }
  proof_lines "$MSB_A" /home/agent/.hal-install-proof || { record "$id" BLOCKED "could not read the install proof file before restart"; return 0; }
  i0=$PROOF_N
  say "  deleting $n host install key(s) under $hc"
  find "$hc" -maxdepth 1 -type f -name 'install-*' -exec rm -f {} + 2>>"$TRANSCRIPT"
  run_cmd "$CREATE_TIMEOUT" "$ACQ" --backend msb restart "$MSB_A"
  need_rc0 "$id" "acq restart" || return 0
  proof_lines "$MSB_A" /home/agent/.hal-install-proof || { record "$id" BLOCKED "could not read the install proof file after restart"; return 0; }
  i1=$PROOF_N
  say "  install proof lines: $i0 -> $i1"
  if [ "$i1" -gt "$i0" ]; then record "$id" PASS "install command re-ran after the host install key was deleted (restart exited 0)"
  else record "$id" FAIL "install command did not re-run after the host install key was deleted"; fi
}

step_msb_ro_oci() {
  local id=msb-ro-oci n ws ref irc
  block_if_not_ready "$id" "$MSB_READY" "msb unavailable" || return 0
  ref=$(
    # shellcheck disable=SC1090
    ACQ_SOURCE_ONLY=1 ACQ_SCRIPT_DIR="$REPO" . "$ACQ_LIB" >/dev/null 2>&1
    _acq_optin_kit_ref oci-engine 2>/dev/null
  )
  [ -n "$ref" ] || { record "$id" BLOCKED "could not resolve the oci-engine kit ref"; return 0; }
  n=$(sandbox_name oci)
  ws=$(mk_workspace oci) || { record "$id" BLOCKED "cannot create a workspace under $WS_ROOT"; return 0; }
  say "  oci-engine ref: $ref"
  create_sandbox msb "$n" "$ws" --kit "$ref"
  if last_has "cannot place read-only kit file"; then record "$id" FAIL "acq refused a readonly oci-engine file on create"; return 0; fi
  if [ "$LAST_RC" -ne 0 ]; then record "$id" BLOCKED "acq create with oci-engine exited $LAST_RC (see transcript)"; return 0; fi
  run_cmd "$STEP_TIMEOUT" msb exec "$n" -u 0 -- sh -c 'ls /var/lib/acq/host/kit-files 2>&1; echo LS-RC=$?; if [ -e /home/agent/oci-engine-grant-devs.sh ]; then echo GUEST-COPY-OF-GRANT-SCRIPT-PRESENT; else echo NO-GUEST-COPY-OF-GRANT-SCRIPT; fi'
  need_rc0 "$id" "listing the staged oci-engine files" || return 0
  last_has 'LS-RC=0' || { record "$id" BLOCKED "ls of the staged oci-engine files failed in the guest (tool missing or mount absent); see transcript"; return 0; }
  if last_has 'home-agent-oci-engine-grant-devs-sh.' && last_has 'home-agent-oci-engine-config-oci-engine-storage-driver-sh.' \
      && last_has NO-GUEST-COPY-OF-GRANT-SCRIPT; then
    msb_inspect_check "$n"; irc=$?
    if [ "$irc" -eq 2 ]; then record "$id" BLOCKED "msb inspect failed, timed out, or returned unusable output"; return 0; fi
    if [ "$irc" -ne 0 ]; then record "$id" FAIL "inspect does not show the read-only Bind"; return 0; fi
    record "$id" PASS "oci-engine readonly files were staged on the read-only mount, not copied to the guest, and inspect shows the read-only Bind"
  else
    record "$id" FAIL "oci-engine readonly files were not staged as expected, or inspect lacks the read-only Bind"
  fi
}

# --- SBX steps ------------------------------------------------------------------
SBX_READY=0; SBX_A=""; SBX_A_OK=0
sbx_preflight() {
  if ! command -v sbx >/dev/null 2>&1; then say "sbx: not on PATH"; return 0; fi
  probe "$STEP_TIMEOUT" sbx version
  if [ "$PROBE_RC" -ne 0 ]; then say "sbx: 'sbx version' failed or timed out (rc $PROBE_RC)"; return 0; fi
  SBX_VER=$(printf '%s\n' "$PROBE_OUT" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [ -n "$SBX_VER" ] || SBX_VER="unparsed"
  SBX_READY=1
}

sbx_record_path() { printf '%s/builtin-kits\n' "$(hc_dir sbx "$1")"; }

step_sbx_baseline() {
  local id=sbx-baseline n ws rec
  block_if_not_ready "$id" "$SBX_READY" "sbx not on PATH" || return 0
  n=$(sandbox_name s); SBX_A="$n"
  ws=$(mk_workspace s) || { record "$id" BLOCKED "cannot create a workspace under $WS_ROOT"; return 0; }
  create_sandbox sbx "$n" "$ws"
  need_rc0 "$id" "acq create on sbx (login, Docker, or provider setup?)" || return 0
  rec=$(sbx_record_path "$n")
  if [ -s "$rec" ]; then
    SBX_A_OK=1
    say "  builtin-kits record has $(grep -c . "$rec") line(s): $(cut -d' ' -f1 "$rec" | tr '\n' ' ')"
    record "$id" PASS "fresh create seeded a host builtin-kits record ($rec)"
  else
    record "$id" FAIL "fresh create left no host builtin-kits record at $rec"
  fi
}

step_sbx_forged_heal() {
  local id=sbx-forged-heal before after
  [ "$SBX_A_OK" -eq 1 ] || { record "$id" BLOCKED "needs the sandbox from sbx-baseline"; return 0; }
  run_cmd "$STEP_TIMEOUT" sbx exec "$SBX_A" -- sh -c 'test -e /home/agent/usai-config/opencode.jsonc && echo PRESENT'
  need_rc0 "$id" "probing that the provider config exists" || return 0
  last_has PRESENT || { record "$id" BLOCKED "the provider config did not exist before removal, so its absence afterwards proves nothing"; return 0; }
  run_cmd "$STEP_TIMEOUT" sbx exec "$SBX_A" -- sudo sh -c 'rm -f /usr/local/share/ca-certificates/zscaler-ca.crt /home/agent/usai-config/opencode.jsonc && rm -f /home/agent/.agentic-coding-playbook/AGENTS.md && echo REMOVED'
  need_rc0 "$id" "removing the guest files as root" || return 0
  last_has REMOVED || { record "$id" BLOCKED "could not remove the guest files as root (sudo unavailable?)"; return 0; }
  [ -s "$(sbx_record_path "$SBX_A")" ] || { record "$id" BLOCKED "host builtin-kits record is missing before the re-attach"; return 0; }
  before=$(cksum <"$(sbx_record_path "$SBX_A")")
  run_cmd "$CREATE_TIMEOUT" "$ACQ" --backend sbx run "$SBX_A" -- --version
  after=$(cksum <"$(sbx_record_path "$SBX_A")")
  need_rc0 "$id" "re-attach" || return 0
  [ -s "$(sbx_record_path "$SBX_A")" ] || { record "$id" FAIL "the host builtin-kits record disappeared after re-attach"; return 0; }
  if last_has "injecting with 'sbx kit add'" || last_has "injected into"; then
    record "$id" FAIL "re-attach re-applied a kit although the host record was current"; return 0
  fi
  run_cmd "$STEP_TIMEOUT" sbx exec "$SBX_A" -- sh -c 'if [ -e /home/agent/usai-config/opencode.jsonc ]; then echo REAPPEARED; else echo STILL-ABSENT; fi'
  need_rc0 "$id" "post-heal absence probe" || return 0
  if ! last_has STILL-ABSENT && ! last_has REAPPEARED; then record "$id" BLOCKED "the post-heal absence probe printed neither verdict marker (tool missing in the guest?)"; return 0; fi
  if [ "$before" = "$after" ] && last_has STILL-ABSENT; then record "$id" PASS "re-attach did not re-apply removed guest files while the host builtin-kits record was current"
  else record "$id" FAIL "host record changed or the removed guest file reappeared after re-attach"; fi
}

step_sbx_record_change() {
  local id=sbx-record-change rec missing="" k
  [ "$SBX_A_OK" -eq 1 ] || { record "$id" BLOCKED "needs the sandbox from sbx-baseline"; return 0; }
  rec=$(sbx_record_path "$SBX_A")
  [ -s "$rec" ] || { record "$id" BLOCKED "host builtin-kits record is missing before the change"; return 0; }
  cp "$rec" "$OUT/builtin-kits.saved" || { record "$id" BLOCKED "cannot save the original record"; return 0; }
  sed 's/#ref=[0-9a-f]\{40\}/#ref=0000000000000000000000000000000000000000/' "$OUT/builtin-kits.saved" >"$rec.new" && mv -f "$rec.new" "$rec" \
    || { record "$id" BLOCKED "cannot alter the host record"; return 0; }
  cmp -s "$rec" "$OUT/builtin-kits.saved" && { record "$id" BLOCKED "the record had no 40-hex refs to alter (format changed?)"; return 0; }
  say "  altered the host builtin-kits record (refs replaced with zeros); original saved in $OUT"
  run_cmd "$CREATE_TIMEOUT" "$ACQ" --backend sbx run "$SBX_A" -- --version
  need_rc0 "$id" "acq run (re-attach)" || return 0
  for k in "Zscaler CA kit" "provider kit" "playbook kit"; do
    last_has "is missing the $k; injecting with 'sbx kit add'" || missing="${missing}${k}, "
  done
  if [ -z "$missing" ]; then
    record "$id" PASS "altering the host record made the heal attempt kit add for all three record-tracked kits (Zscaler CA, provider, playbook)"
  else
    record "$id" FAIL "no kit add attempt for: ${missing%, }"
  fi
}

step_sbx_stale_refresh() {
  local id=sbx-stale-refresh pf missing="" k
  [ "$SBX_A_OK" -eq 1 ] || { record "$id" BLOCKED "needs the sandbox from sbx-baseline"; return 0; }
  pf=$(prov_file sbx "$SBX_A")
  [ -n "$pf" ] && [ -s "$pf" ] || { record "$id" BLOCKED "no provenance record for $SBX_A, so staleness cannot be forced"; return 0; }
  cp "$pf" "$OUT/provenance.saved" || { record "$id" BLOCKED "cannot save the provenance record"; return 0; }
  awk '/^applied_ref=/ { print "applied_ref=0000000000000000000000000000000000000000"; next } { print }' "$OUT/provenance.saved" >"$pf.new" \
    && mv -f "$pf.new" "$pf" || { record "$id" BLOCKED "cannot make the provenance record stale"; return 0; }
  say "  made ONLY the provenance record of $SBX_A stale ($pf); no other sandbox is touched"
  run_cmd "$STEP_TIMEOUT" "$ACQ" --backend sbx kit check "$SBX_A"
  need_rc0 "$id" "acq kit check" || return 0
  last_has "stale" || { record "$id" BLOCKED "acq kit check did not report stale after the edit; refresh would be a no-op"; return 0; }
  run_cmd "$CREATE_TIMEOUT" "$ACQ" --backend sbx kit update "$SBX_A" --yes
  if last_has "sbx >= 0.38"; then
    record "$id" BLOCKED "sbx $SBX_VER cannot extend a live sandbox with startup-bearing kits: refresh prints the recreate notice instead of re-applying (documented limit, not a refresh result)"; return 0
  fi
  need_rc0 "$id" "acq kit update" || return 0
  for k in "Zscaler CA kit injected" "provider kit injected" "playbook kit injected" "git-ssh-sign kit refreshed"; do
    last_has "$k" || missing="${missing}${k}, "
  done
  if last_has "warning:"; then record "$id" FAIL "kit update reported a warning although it exited 0 (see transcript)"; return 0; fi
  if [ -n "$missing" ]; then record "$id" FAIL "kit update exited 0 but did not report: ${missing%, }"; return 0; fi
  run_cmd "$STEP_TIMEOUT" "$ACQ" --backend sbx kit check "$SBX_A"
  need_rc0 "$id" "acq kit check after refresh" || return 0
  if last_has "current"; then record "$id" PASS "forced stale refresh exited 0, reported all four named kits applied, and provenance is current again"
  else record "$id" FAIL "kit update reported success but provenance is not current afterwards"; fi
}

step_sbx_legacy_reseed() {
  local id=sbx-legacy-reseed rec ws
  [ "$SBX_A_OK" -eq 1 ] || { record "$id" BLOCKED "needs the sandbox from sbx-baseline"; return 0; }
  rec=$(sbx_record_path "$SBX_A")
  rm -f "$rec"
  run_cmd "$CREATE_TIMEOUT" "$ACQ" --backend sbx run "$SBX_A" -- --version
  need_rc0 "$id" "acq run (re-attach of the legacy sandbox)" || return 0
  [ "$SBX_VER" != unparsed ] || { record "$id" BLOCKED "sbx version could not be parsed, so the 0.38+ notice expectation cannot be applied"; return 0; }
  if ver_ge "${SBX_VER#v}" 0.38.0; then
    if [ "$(last_count 'sbx >= 0.38')" -ne 1 ]; then record "$id" FAIL "expected exactly one consolidated recreate notice on sbx $SBX_VER, saw $(last_count 'sbx >= 0.38')"; return 0; fi
  fi
  run_cmd "$CREATE_TIMEOUT" "$ACQ" --backend sbx rm "$SBX_A"
  need_rc0 "$id" "acq rm" || return 0
  SBX_A_OK=0
  ws=$(mk_workspace s2) || { record "$id" BLOCKED "cannot create a workspace"; return 0; }
  create_sandbox sbx "$SBX_A" "$ws"
  need_rc0 "$id" "acq create after rm" || return 0
  if [ -s "$rec" ]; then record "$id" PASS "legacy notice shown once; acq rm plus a fresh create re-seeded the builtin-kits record"
  else record "$id" FAIL "fresh create after rm did not re-seed the host builtin-kits record"; fi
}
