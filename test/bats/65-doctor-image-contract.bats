#!/usr/bin/env bats
#
# 65-doctor-image-contract.bats — ADR-0030 image contract diagnostics.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "doctor(sbx): reports present ADR-0030 image capabilities" {
  printf 'box\n' > "$STUBDIR/.sandbox_list"

  run env ACQ_BACKEND=sbx "$ACQ" doctor box

  assert_success
  assert_output --partial 'ADR-0030 image contract diagnostics for box (backend: sbx)'
  assert_output --partial 'ok: HOME is /home/agent'
  assert_output --partial 'ok: running as agent user'
  assert_output --partial 'ok: /nix exists'
  assert_output --partial 'ok: devenv is on PATH'
  assert_output --partial 'summary: 0 warning(s); diagnostics only, create/run are not blocked'
  assert_regex "$(cat "$CALLS")" 'sbx exec box -- env HOME=/home/agent sh -c'
}

@test "doctor(sbx): missing image capabilities warn but stay non-fatal" {
  printf 'box\n' > "$STUBDIR/.sandbox_list"

  run env ACQ_BACKEND=sbx STUB_IMAGE_CONTRACT=missing "$ACQ" doctor box
  assert_success
  assert_output --partial 'warning: devenv is not on PATH'
  assert_output --partial 'fix: install devenv in the base image or a create-time kit'
  assert_output --partial 'warning: no shell startup hook for ~/.rc.d found'
  assert_output --partial 'summary: 2 warning(s); diagnostics only, create/run are not blocked'
}

@test "doctor(msb): runs sandbox diagnostics as agent without secrets" {
  printf 'box\n' > "$STUBDIR/.msb_sandbox_list"

  run env ACQ_BACKEND=msb USAI_API_KEY=SUPERSECRET GITHUB_TOKEN=GHSECRET "$ACQ" doctor box
  assert_success
  assert_output --partial 'ADR-0030 image contract diagnostics for box (backend: msb)'
  assert_output --partial 'ok: passwordless sudo probe works'
  assert_output --partial 'summary: 0 warning(s); diagnostics only, create/run are not blocked'
  refute_output --partial 'SUPERSECRET'
  refute_output --partial 'GHSECRET'
  assert_regex "$(cat "$CALLS")" 'msb exec -u agent -e HOME=/home/agent box -- sh -c'
}

@test "doctor: missing sandbox fails before guest diagnostics" {
  run env ACQ_BACKEND=sbx "$ACQ" doctor missing

  assert_failure
  assert_output --partial "acq: doctor: no such sandbox 'missing'."
  refute_output --partial 'ADR-0030 image contract diagnostics'
  refute_regex "$(cat "$CALLS")" 'sbx exec'
}

@test "doctor: extra sandbox operands are rejected" {
  printf 'box\n' > "$STUBDIR/.sandbox_list"

  run env ACQ_BACKEND=sbx "$ACQ" doctor box extra
  assert_failure
  assert_output --partial 'acq: doctor: expected at most one sandbox name'
  refute_regex "$(cat "$CALLS")" 'sbx exec'
}

@test "doctor script: warns when HOME is not the agent home" {
  local script="$STUBDIR/image-doctor.sh"
  bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_image_contract_doctor_script' > "$script"

  run env HOME=/root sh "$script"
  assert_success
  assert_output --partial 'warning: HOME is /root, not /home/agent'
  refute_output --partial 'direnv allow'
}

@test "doctor script: detects actual rc.d source statements, not comments" {
  local home="$STUBDIR/agent-home" script="$STUBDIR/image-doctor.sh"
  mkdir -p "$home/.rc.d"
  printf '# mentions .rc.d only\n' > "$home/.profile"
  bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_image_contract_doctor_script' > "$script"

  run env HOME="$home" sh "$script"
  assert_success
  assert_output --partial 'warning: no shell startup hook for ~/.rc.d found'

  printf '. "$HOME/.rc.d/10-team.sh"\n' > "$home/.profile"
  run env HOME="$home" sh "$script"
  assert_success
  assert_output --partial 'ok: shell startup references ~/.rc.d'
}

@test "doctor script: reports tool versions when available" {
  local home="$STUBDIR/agent-home-versions" script="$STUBDIR/image-doctor.sh" bin="$STUBDIR/bin"
  mkdir -p "$home/.rc.d" "$bin"
  printf '. "$HOME/.rc.d/10-team.sh"\n' > "$home/.profile"
  printf '#!/usr/bin/env sh\nprintf "nix 2.35.2\\n"\n' > "$bin/nix"
  printf '#!/usr/bin/env sh\nprintf "devenv 2.3.0\\n"\n' > "$bin/devenv"
  printf '#!/usr/bin/env sh\nprintf "direnv 2.36.0\\n"\n' > "$bin/direnv"
  chmod +x "$bin/nix" "$bin/devenv" "$bin/direnv"
  bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_image_contract_doctor_script' > "$script"

  run env HOME="$home" PATH="$bin:$PATH" sh "$script"

  assert_success
  assert_output --partial 'ok: nix is on PATH (nix 2.35.2)'
  assert_output --partial 'ok: devenv is on PATH (devenv 2.3.0)'
  assert_output --partial 'ok: direnv is on PATH (direnv 2.36.0)'
}

@test "doctor script: separately warns for missing rc.d directory and startup hook" {
  local home="$STUBDIR/agent-home-no-rc" script="$STUBDIR/image-doctor.sh"
  mkdir -p "$home"
  bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_image_contract_doctor_script' > "$script"

  run env HOME="$home" sh "$script"

  assert_success
  assert_output --partial 'warning: ~/.rc.d is missing'
  assert_output --partial 'fix: install the neutral shell hook directory at /home/agent/.rc.d'
  assert_output --partial 'warning: no shell startup hook for ~/.rc.d found'
}
